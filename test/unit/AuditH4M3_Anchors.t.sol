// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {Phi} from "src/libraries/Phi.sol";
import {StructuralLeverage} from "src/libraries/StructuralLeverage.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";

/// @notice Regressions for AUDIT-2026-07-25 H-4 and M-3 — the two structural-anchor defects.
contract AuditH4M3_AnchorsTest is VaultTestBase {
    uint256 constant DIR = 1;

    function setUp() public {
        setUpProtocol();
    }

    function _setPx(uint256 usd) internal {
        hub.setSpotPx(SPOT_MKT, uint64(usd * 1e4));
        hub.setMarkPx(PERP_MKT, uint64(usd * 1e2));
        hub.setOraclePx(PERP_MKT, uint64(usd * 1e2));
    }

    function _readPos(address who) internal view returns (CoreTypes.Position memory) {
        (bool ok, bytes memory ret) =
            CoreTypes.PRECOMPILE_POSITION.staticcall(abi.encode(who, uint16(PERP_MKT)));
        require(ok, "read pos");
        return abi.decode(ret, (CoreTypes.Position));
    }

    /// Realized venue liquidation price of a long: (entryNtl − margin)/szi.
    function _liqWad(B4Vault v) internal view returns (uint256) {
        CoreTypes.Position memory p = _readPos(address(v));
        if (p.szi <= 0) return 0;
        uint256 margin6 = v.perpMargin6();
        if (uint256(p.entryNtl) <= margin6) return 0;
        return
            Phi.mulDiv((uint256(p.entryNtl) - margin6) * 1e4, Phi.WAD, uint256(uint64(p.szi)) * 1e6);
    }

    function _sampleDaily(uint256 t0abs, uint256 n, uint256 px) internal {
        for (uint256 k = 0; k < n; k++) {
            vm.warp(t0abs + k * 1 days);
            _setPx(px);
            pool.sampleAnchor(DIR);
        }
    }

    // =============================================================== H-4

    /// The L-halving long anchors on `floor` — the 62-min the halving flip promotes — per
    /// STRUCTURAL-STATE-MACHINE §3 (`stop_day = p_day − (p_day − B)/φ`, row PM5
    /// `[p=3000, B=850 → 1671]`). It used to anchor on `cap`, the CURRENT post-halving
    /// window's running low, which by construction sits beside the live price: `p − cap` is
    /// small, so `L = p/(p − stop)` ran to the venue clamp for any price at all.
    ///
    /// Asserted on the realized LIQUIDATION PRICE, not the order size — this repo's rule for
    /// structural sizing, because size is a means and the liquidation level is the promise.
    function test_H4_l_halving_long_liquidates_at_the_62min_derived_stop() public {
        // Previous cycle's 62-min = 850, promoted into `floor` by the halving flip.
        _sampleDaily(GENESIS_TS + Calendar.T + 1 days, 11, 850);
        uint256 hts = GENESIS_TS + Calendar.T + Calendar.W + 30 days;
        vm.warp(hts);
        acceptHalving(GENESIS_HEIGHT + 210_000, uint32(hts));
        vm.warp(hts + 1 days);
        _setPx(850);
        pool.sampleAnchor(DIR); // opens [0, W) ⇒ flips the confirmed 62-low into floor
        (uint256 floor_, uint256 cap_) = pool.anchors(DIR);
        assertEq(floor_, 850e18, "62-min promoted into floor");

        // Now inside the post-halving window at the doc's price.
        vm.warp(hts + 2 days);
        _setPx(3_000);
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 0, 120_000e6);
        crankUntilIdle(v, 60);

        // The doc's worked number: 3000 − (3000−850)/φ = 1671.3
        uint256 expected = StructuralLeverage.longStop(3_000e18, 850e18, 0);
        assertApproxEqRel(expected, 1_671e18, 0.001e18, "matches STRUCTURAL-STATE-MACHINE PM5");
        assertEq(v.perpStopWad(), expected, "frozen stop is derived from the 62-min");

        // The promise: the venue liquidates AT that stop (never nearer than it).
        assertApproxEqRel(_liqWad(v), expected, 0.01e18, "liquidation lands on the stop");

        // And the anchor that used to be used would have produced a wildly tighter stop.
        uint256 wrong = StructuralLeverage.longStop(3_000e18, cap_ == 0 ? 2_900e18 : cap_, 0);
        assertGt(wrong, expected, "the near-price anchor gives a much tighter stop");
    }

    // =============================================================== M-3

    /// The window anchor is the MAX of DAILY observations. Ratcheting on every call let a
    /// caller wait for a wick and push `peakC` up for free — the density gate counts days,
    /// so an already-confirmed window accepted a poisoned VALUE at no cost. The harm lands a
    /// cycle later: `peakC` is promoted to `prevPeak`, the short's DELTA anchor, and an
    /// inflated `Pp` shrinks `(C − Pp)`, pulling the stop toward C and RAISING leverage.
    function test_M3_intraday_wick_cannot_move_the_confirmed_peak() public {
        uint256 start = GENESIS_TS + Calendar.P - Calendar.W + 1 days;
        _sampleDaily(start, 11, 5_000); // honest, dense, density-confirmed
        (, uint256 peakBefore,) = pool.peaks(DIR);
        assertEq(peakBefore, 5_000e18, "honest peak confirmed");

        // Same day as the last honest sample: a wick prints and is spammed in.
        _setPx(50_000);
        pool.sampleAnchor(DIR);
        pool.sampleAnchor(DIR);
        pool.sampleAnchor(DIR);

        (, uint256 peakAfter,) = pool.peaks(DIR);
        assertEq(peakAfter, 5_000e18, "a within-day wick cannot move the anchor");
    }

    /// NOT mirrored on the low side. The two anchors fail in opposite directions: a too-high
    /// peak RAISES the short's leverage (hence the daily value gate), while a too-low `cap`
    /// moves the long's stop FURTHER from price and LOWERS leverage. So an intraday crash MUST
    /// be recorded immediately — refusing it would keep structural longs levered against a low
    /// the market already broke. Only the density COUNT stays daily; it gates confirmation.
    function test_M3_intraday_crash_moves_the_low_immediately() public {
        _sampleDaily(GENESIS_TS + Calendar.T + 1 days, 11, 2_000);
        (, uint256 capBefore) = pool.anchors(DIR);
        assertEq(capBefore, 2_000e18, "honest low confirmed");

        _setPx(10);
        pool.sampleAnchor(DIR);

        (, uint256 capAfter) = pool.anchors(DIR);
        assertEq(capAfter, 10e18, "a real intraday crash lowers the anchor at once");
        // ...and it is the SAFE direction: a lower anchor means less leverage, so a caller
        // sampling more often can only ever de-risk the pool, never lever it up.
        assertLt(capAfter, capBefore);
    }

    /// The honest daily cadence still ratchets — the gate must not freeze a real move — but a
    /// new high is served only once a SECOND close reaches it (AUDIT-2026-07-25 M-3's dispersion
    /// remedy, built in AUDIT-2026-07-29). One close makes a candidate; two make an anchor.
    /// That is exactly what makes the single at-close wick above worthless, and the price is
    /// this one-day lag on a genuine move.
    function test_M3_next_day_observation_ratchets_once_corroborated() public {
        uint256 start = GENESIS_TS + Calendar.P - Calendar.W + 1 days;
        _sampleDaily(start, 11, 5_000);

        // One higher close: a candidate, not yet an anchor.
        vm.warp(start + 11 days);
        _setPx(6_000);
        pool.sampleAnchor(DIR);
        (, uint256 mid,) = pool.peaks(DIR);
        assertEq(mid, 5_000e18, "a single higher close is only a candidate");

        // A second close at the same level on a DIFFERENT day corroborates it.
        vm.warp(start + 12 days);
        _setPx(6_000);
        pool.sampleAnchor(DIR);
        (, uint256 peak,) = pool.peaks(DIR);
        assertEq(peak, 6_000e18, "two distinct closes at the level do ratchet");
    }

    /// The lag is one day, not one window: the level the market actually held is never lost, it
    /// is only served a close later. Pinning this stops the remedy from being tightened into
    /// "the peak must be revisited near the end of the window", which would discard real tops.
    function test_M3_corroboration_survives_a_later_lower_close() public {
        uint256 start = GENESIS_TS + Calendar.P - Calendar.W + 1 days;
        _sampleDaily(start, 11, 5_000);

        vm.warp(start + 11 days);
        _setPx(6_000);
        pool.sampleAnchor(DIR);
        vm.warp(start + 12 days);
        _setPx(6_000);
        pool.sampleAnchor(DIR);

        // The market falls back for the rest of the window; the corroborated high stands.
        vm.warp(start + 13 days);
        _setPx(3_000);
        pool.sampleAnchor(DIR);
        (, uint256 peak,) = pool.peaks(DIR);
        assertEq(peak, 6_000e18, "a corroborated high is never pulled back down");
    }
}
