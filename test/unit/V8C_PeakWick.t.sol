// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {StructuralLeverage} from "src/libraries/StructuralLeverage.sol";
import {Phi} from "src/libraries/Phi.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";

/// @notice V8 Scope C — REGRESSION for V8-M-2 (peak wick-poisoning), fixed by the V9
///         sampling-density gate. The attack sampled the peak window only twice — the
///         honest open plus ONE wicked-high print (order-book-derived price on a
///         permissionless pool's thin asset); pre-fix the up-only MAX could not be
///         repaired within the window and promoted into `prevPeak` at the next window
///         with no density/parity guard. Post-fix a 2-sample window never confirms, so
///         the wick is neither fed to the engine nor promoted. The three pre-fix harm
///         directions (quoted as the regression baseline):
///         F) this cycle: maxStop pushed out ⇒ de-levered (fail-safe);
///         G) next cycle, wick ≥ C′: `shortStructStop` refused ⇒ NO short for a full cycle.
///            SUPERSEDED by A31 — that refusal was itself the defect. The post-pivot short now
///            DEGRADES to the one-anchor rule `max(p·φ, C)` instead, so a poisoned delta anchor
///            costs the boost, not the position;
///         H) next cycle, wick < C′: shrunk delta ⇒ over-leverage. The original 3.58× / 1.96×
///            pair was computed under the superseded fixed-stop rule; against the clamped rule
///            (A26) the same poisoning reads 1.96× vs a 1.62× honest baseline, and only where
///            the cap binds — at a deep entry the C-pin dominates and it is invisible.
///         (A wick inside a genuinely DENSE window is out of the density gate's scope —
///         see AUDIT-V8's "median-of-samples / sanity band" follow-up recommendation.)
contract V8C_PeakWickTest is VaultTestBase {
    uint256 constant DIR = 1;

    function setUp() public {
        setUpProtocol();
    }

    function readPos(address who) internal view returns (CoreTypes.Position memory) {
        (bool ok, bytes memory ret) =
            CoreTypes.PRECOMPILE_POSITION.staticcall(abi.encode(who, uint16(PERP_MKT)));
        require(ok, "read pos");
        return abi.decode(ret, (CoreTypes.Position));
    }

    function _setPx(uint256 usd) internal {
        hub.setSpotPx(SPOT_MKT, uint64(usd * 1e4));
        hub.setMarkPx(PERP_MKT, uint64(usd * 1e2));
        hub.setOraclePx(PERP_MKT, uint64(usd * 1e2));
    }

    function _levWad(B4Vault v) internal view returns (uint256) {
        CoreTypes.Position memory p = readPos(address(v));
        if (v.perpMargin6() == 0) return 0;
        return Phi.mulDiv(uint256(p.entryNtl), Phi.WAD, v.perpMargin6());
    }

    function _halvingAt(uint256 hts, uint256 height) internal {
        vm.warp(hts);
        acceptHalving(height, uint32(hts));
    }

    /// Sample `n` times, one day apart, starting at the ABSOLUTE time `t0abs`, at price
    /// `px`. 11 daily samples satisfy the V9 density gate (count ≥ 10 AND span ≥ W/2).
    function _sampleDaily(uint256 t0abs, uint256 n, uint256 px) internal {
        for (uint256 k = 0; k < n; k++) {
            vm.warp(t0abs + k * 1 days);
            _setPx(px);
            pool.sampleAnchor(DIR);
        }
    }

    /// Sparse-wick fixture: the cycle-0 peak window sampled ONLY by the honest open (40k)
    /// and one wicked print (`wickPx`) — 2 samples, never density-confirmed.
    function _sparseWickedEpochZeroPeak(uint256 wickPx) internal {
        warpTo(Calendar.P - Calendar.W + 2 days);
        _setPx(40_000);
        pool.sampleAnchor(DIR); // honest open
        warpTo(Calendar.P - Calendar.W + 9 days);
        _setPx(wickPx); // the wick: one print, unrepairable
        pool.sampleAnchor(DIR);
    }

    /// F) THIS cycle, pre-fix: the wick was absorbed into peakC and fed — maxStop pushed
    ///    out to 129.4k, leverage 0.30× vs 0.86× honest (fail-safe, but the poison then
    ///    persisted into the next cycle — see G/H). Post-fix: the sparse window never
    ///    confirms — peakC is WITHHELD; the Fall short runs the honest genesis flat-φ
    ///    path (prevPeak 0, C 0), leverage ≈ φ. The wick never reaches the engine.
    function test_wick_up_sparse_window_withheld_this_cycle() public {
        _sparseWickedEpochZeroPeak(80_000);
        (, uint256 c,) = pool.peaks(DIR);
        assertEq(c, 0, "FIXED: wicked peakC withheld (pre-fix: 80k absorbed, unrepairable)");

        warpTo(Calendar.P + 30 days);
        _setPx(30_000);
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 0, 120_000e6);
        crankUntilIdle(v, 60);

        assertLt(readPos(address(v)).szi, 0, "short opened");
        assertEq(
            v.perpStopWad(),
            StructuralLeverage.shortStructStop(30_000e18, 0, 0),
            "genesis flat-phi stop -- the wick never reaches the engine"
        );
        assertApproxEqRel(_levWad(v), Phi.PHI, 0.03e18, "honest flat-phi degrade");
        assertTrue(
            v.perpStopWad() != StructuralLeverage.shortStructStop(30_000e18, 0, 80_000e18),
            "sanity: the pre-fix wicked stop would differ"
        );
    }

    /// G) NEXT cycle, wick ≥ C′, pre-fix: the wick PROMOTED to prevPeak (80k) while the
    ///    honest cycle-1 peak C′ = 50k ≤ prevPeak ⇒ `shortStructStop` refused ⇒ NO short
    ///    for the entire cycle-1 Fall (full-cycle product outage). Post-fix: the sparse
    ///    window never promotes — prevPeak stays 0 — and the honest dense C′ feeds
    ///    normally: the short OPENS and the outage is gone. Discarding the sparse window
    ///    whole also drops the honest 40k, so the position is DE-levered vs the honest
    ///    baseline (fail-safe direction, self-healing).
    function test_wick_sparse_window_never_promoted_no_outage() public {
        _sparseWickedEpochZeroPeak(80_000);

        uint256 hts = GENESIS_TS + Calendar.T + 30 days;
        _halvingAt(hts, GENESIS_HEIGHT + 210_000);
        _sampleDaily(hts + Calendar.P - Calendar.W + 1 days, 11, 50_000); // honest dense C'
        (uint256 pp, uint256 c, uint256 tag) = pool.peaks(DIR);
        assertEq(pp, 0, "FIXED: wick NEVER promoted (pre-fix: 80k poisoned prevPeak)");
        assertEq(c, 50_000e18, "honest C' confirmed dense");
        assertEq(tag, 2, "fresh");

        // 25k, not 45k: at 45k the clamp is inert (45k·φ sits between C and maxStop) and the
        // stop assertion below would hold with no peak fed at all.
        vm.warp(hts + Calendar.P + 30 days); // cycle-1 Fall
        _setPx(25_000);
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 0, 120_000e6);
        crankUntilIdle(v, 60);
        assertLt(readPos(address(v)).szi, 0, "FIXED: short opens -- the outage is gone");
        assertEq(
            v.perpStopWad(),
            StructuralLeverage.shortStructStop(25_000e18, 0, 50_000e18),
            "prevPeak 0 (sparse window discarded whole, wick and all)"
        );
        assertGt(
            v.perpStopWad(),
            StructuralLeverage.shortStructStop(25_000e18, 0, 0),
            "the honest dense C' CHANGED the stop -- it really did reach the engine"
        );
        assertLt(
            _levWad(v),
            StructuralLeverage.shortStructLev(45_000e18, 40_000e18, 50_000e18),
            "de-levered vs the honest-dense baseline: fail-safe"
        );
    }

    /// H) NEXT cycle, wick < C′: a poisoned prevPeak shrinks the delta `(C′ − Pp)`, which pulls
    ///    `maxStop` toward `C` and RAISES leverage for every short on the pool for the whole
    ///    cycle. Post-fix prevPeak is never poisoned and the engine sizes off the honest dense
    ///    anchors only. Figures recomputed against the clamped rule (A26), at the entry where the
    ///    cap actually binds: honest (Pp 0, C 90k) 1.62× vs poisoned (Pp 40k) 1.96×.
    function test_wick_below_next_peak_never_promoted_honest_leverage() public {
        _sparseWickedEpochZeroPeak(70_000);

        uint256 hts = GENESIS_TS + Calendar.T + 30 days;
        _halvingAt(hts, GENESIS_HEIGHT + 210_000);
        _sampleDaily(hts + Calendar.P - Calendar.W + 1 days, 11, 90_000); // honest dense C'
        (uint256 pp, uint256 c,) = pool.peaks(DIR);
        assertEq(pp, 0, "FIXED: wick NEVER promoted (pre-fix: 70k poisoned prevPeak)");
        assertEq(c, 90_000e18, "honest C' confirmed dense");

        // 50k, not 80k: at 80k the base-phi stop lands mid-band, the clamp is inert, and the
        // assertion below would pass identically with NO anchor fed. At 50k the pin binds, so it
        // actually proves the honest C' reached the engine.
        vm.warp(hts + Calendar.P + 30 days);
        _setPx(50_000);
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 0, 120_000e6);
        crankUntilIdle(v, 60);

        assertLt(readPos(address(v)).szi, 0, "short opened on the honest anchors");
        assertEq(
            v.perpStopWad(),
            StructuralLeverage.shortStructStop(50_000e18, 0, 90_000e18),
            "prevPeak 0 (sparse window discarded whole)"
        );
        assertEq(v.perpStopWad(), 90_000e18, "pinned to the honest C', not the wick");
        assertGt(
            v.perpStopWad(),
            StructuralLeverage.shortStructStop(50_000e18, 0, 0),
            "the honest anchor CHANGED the stop"
        );
        // Read the poisoning where it bites — the cap, not the pin (see V9AnchorDensity).
        assertLt(
            StructuralLeverage.shortStructLev(80_000e18, 0, 90_000e18),
            StructuralLeverage.shortStructLev(80_000e18, 40_000e18, 90_000e18),
            "a promoted 70k wick WOULD have over-levered -- it never got promoted"
        );
    }
}
