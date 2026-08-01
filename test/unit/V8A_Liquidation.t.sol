// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {StructuralLeverage} from "src/libraries/StructuralLeverage.sol";
import {Phi} from "src/libraries/Phi.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";

/// @notice V8 Scope A, item 1: the venue-computed liquidation of the COMBINED position
///         must equal the frozen structural stop — fresh open, ramp ADD at a different
///         mark than the avg entry, ramp REDUCE, and the venue-maxLeverage clamp (whose
///         direction must be FURTHER than the stop, never closer).
contract V8A_LiquidationTest is VaultTestBase {
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

    /// Realized venue liquidation (WAD), both sides: long (entryNtl − margin)/szi,
    /// short (entryNtl + margin)/|szi| — isolated, ignoring maintenance (spec §6).
    function _liqWad(B4Vault v) internal view returns (uint256) {
        CoreTypes.Position memory p = readPos(address(v));
        if (p.szi == 0) return 0;
        uint256 margin6 = v.perpMargin6();
        if (p.szi > 0) {
            if (uint256(p.entryNtl) <= margin6) return 0;
            return Phi.mulDiv(
                (uint256(p.entryNtl) - margin6) * 1e4, Phi.WAD, uint256(uint64(p.szi)) * 1e6
            );
        }
        return
            Phi.mulDiv(
                (uint256(p.entryNtl) + margin6) * 1e4, Phi.WAD, uint256(uint64(-p.szi)) * 1e6
            );
    }

    function _levWad(B4Vault v) internal view returns (uint256) {
        CoreTypes.Position memory p = readPos(address(v));
        if (v.perpMargin6() == 0) return 0;
        return Phi.mulDiv(uint256(p.entryNtl), Phi.WAD, v.perpMargin6());
    }

    /// Sample the anchor ratchet `n` times, one day apart, starting at the ABSOLUTE time
    /// `t0abs`, at a constant price. 11 daily samples satisfy the V9 density gate
    /// (count ≥ 10 AND span ≥ W/2), so the window's anchor confirms and feeds the engine.
    /// @dev Seed `floor` — the 62-min the halving flip promotes — at `px`. That is the
    ///      anchor the L-halving regime uses (STRUCTURAL-STATE-MACHINE §3, row PM5); the
    ///      old shortcut of seeding `cap` in the post-halving window was audit finding H-4.
    ///      Returns the absolute timestamp just inside the new epoch's `[0, W)`.
    function _seedFloorViaHalvingFlip(uint256 px) internal returns (uint256 hts) {
        _sampleDaily(GENESIS_TS + Calendar.T + 1 days, 11, px); // 62-window, densely
        hts = GENESIS_TS + Calendar.T + Calendar.W + 30 days;
        vm.warp(hts);
        acceptHalving(GENESIS_HEIGHT + 210_000, uint32(hts));
        vm.warp(hts + 1 days);
        _setPx(px);
        pool.sampleAnchor(DIR); // opens the post-halving window ⇒ flips the confirmed 62-low
        (uint256 floor_,) = pool.anchors(DIR);
        assertEq(floor_, px * 1e18, "62-min promoted into floor");
    }

    function _sampleDaily(uint256 t0abs, uint256 n, uint256 px) internal {
        for (uint256 k = 0; k < n; k++) {
            vm.warp(t0abs + k * 1 days);
            _setPx(px);
            pool.sampleAnchor(DIR);
        }
    }

    // ------------------------------------------------ fresh open: exact to lot truncation

    function test_V8A_fresh_open_liq_equals_stop_within_one_lot() public {
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 0, 120_000e6);
        crankUntilIdle(v, 60);

        uint256 stop = StructuralLeverage.longStop(100_000e18, 0, 0);
        uint256 liq = _liqWad(v);
        assertEq(v.perpStopWad(), stop, "frozen stop == L-rise stop");
        // Truncation of one lot ($10 notional on ~$194k) is the only allowed drift,
        // and it must be on the SAFE side (liq deeper than the stop for a long).
        assertLe(liq, stop, "truncation must never lift a long's liq above the stop");
        assertApproxEqRel(liq, stop, 0.001e18, "fresh open liq == stop (0.1%)");
    }

    // ------------------------- ADD at a mark far BELOW the avg entry (weighted average)

    /// A29 changed what this asserts. The stop scales with price even in the genesis flat-`φ`
    /// regime (`p/φ²`), so an add at a lower mark lands its own liquidation DEEPER than the
    /// open-time stop and the blend moves. "Pinned to the frozen stop" was only ever true because
    /// the add was mis-priced against that frozen stop. The property that survives is the blend's
    /// BOUNDS. (This fixture cannot discriminate the A29 regression on its own — the effect here
    /// is 0.5 % — `test_V8A_add_after_rally_...` is the one that does.)
    function test_V8A_add_at_lower_mark_blends_between_the_two_stops() public {
        warpTo(300 days); // Growth plateau, deposits open
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 0, 120_000e6);
        crankUntilIdle(v, 60);
        uint256 stop = StructuralLeverage.longStop(100_000e18, 0, 0); // frozen L-rise stop
        assertApproxEqRel(_liqWad(v), stop, 0.001e18, "open on the stop");
        int64 szi0 = readPos(address(v)).szi;

        // Price drops 40% (mark now far below the 100k avg entry, still above the stop);
        // the owner deposits again — the ADD must be sized at the LIVE MARK (60k), so the
        // increment's own liquidation is the frozen stop and the combined liq stays put.
        _setPx(60_000);
        fundAndDeposit(v, 0, 120_000e6);
        crankUntilIdle(v, 60);

        CoreTypes.Position memory p = readPos(address(v));
        assertGt(p.szi, szi0, "deposit added lots at the lower mark");
        uint256 liq = _liqWad(v);
        uint256 sliceStop = StructuralLeverage.longStop(60_000e18, 0, 0); // the rule AT the mark
        assertLt(sliceStop, stop, "the slice stop at the lower mark is deeper");
        assertGt(liq, sliceStop, "blend cannot be deeper than the deepest slice's own stop");
        assertLe(liq, stop, "blend cannot be shallower than the shallowest slice's own stop");
        assertEq(v.perpStopWad(), stop, "the frozen stop itself is untouched (C1/C4)");
    }

    /// A29 — the regression the adversarial fan-out reproduced. Since the post-pivot stop became
    /// entry-DEPENDENT (A26), sizing a top-up against the stop FROZEN at open is an over-lever:
    /// open deep, where the stop is pinned to the confirmed peak `C`, then rally, and the frozen
    /// stop sits far closer to the mark than the rule allows at the new price. Each add must be
    /// sized against the stop the rule gives at the price it actually fills at.
    function test_V8A_add_after_rally_sized_at_the_live_stop_not_the_frozen_one() public {
        // Confirm this cycle's peak at 50k, then enter the Fall deep at 25k: p*phi = 40.4k < C,
        // so the pin binds and the frozen stop is C itself.
        _sampleDaily(GENESIS_TS + Calendar.P - Calendar.W + 1 days, 11, 50_000);
        vm.warp(GENESIS_TS + Calendar.P + 30 days);
        _setPx(25_000);
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 0, 120_000e6);
        crankUntilIdle(v, 60);
        int64 szi0 = readPos(address(v)).szi;
        assertLt(szi0, int64(0), "short open in the Fall");
        assertEq(v.perpStopWad(), 50_000e18, "frozen stop is the C-pin");

        // Rally to 45k. The rule at 45k gives stop = 45k*phi = 72.8k (mid-band, base phi) - far
        // from the mark. The frozen stop is 50k, only 11% away, so an add priced against it buys
        // |45k-50k| = 5k per unit of margin instead of |45k-72.8k| = 27.8k: 5.6x too many lots.
        _setPx(45_000);
        uint256 fresh = StructuralLeverage.shortStructStop(45_000e18, 0, 50_000e18);
        assertGt(fresh, 70_000e18, "the live stop is mid-band, far above the frozen pin");
        fundAndDeposit(v, 0, 120_000e6);
        crankUntilIdle(v, 60);

        assertGt(Phi.abs(readPos(address(v)).szi), Phi.abs(szi0), "the deposit did add lots");
        // THE discriminator, and the reason this test exists rather than a size bound: priced
        // against the frozen stop every add lands its own liquidation on `C`, so the blend stays
        // EXACTLY on the pin no matter how far the price has run (measured: 50,000.000). Priced
        // against the live stop the increment's liquidation is further away, so the blend must
        // move UP off the pin (measured: 50,044). Revert `_sliceStopWad` to the frozen stop and
        // this fails on equality - checked, not assumed.
        assertGt(_liqWad(v), 50_000e18, "blend moved off the C-pin toward the live stop");
    }

    // ------------------------------------------------ REDUCE mid-hold (calendar ramp-down)

    function test_V8A_reduce_mid_hold_keeps_liq_at_or_below_stop() public {
        warpTo(300 days);
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 0, 120_000e6);
        crankUntilIdle(v, 60);
        uint256 stop = StructuralLeverage.longStop(100_000e18, 0, 0);
        int64 szi0 = readPos(address(v)).szi;

        // ClosingGrowth: target ramps phi -> 0; at P-W+1d it is 0.9*phi (> 1, still pure
        // perp) so marginNeed = 0.9 * nav -> proportional REDUCE at the frozen avg entry.
        warpTo(Calendar.P - Calendar.W + 1 days);
        crankUntilIdle(v, 40);

        CoreTypes.Position memory p = readPos(address(v));
        assertGt(p.szi, 0, "still long mid-ramp");
        assertLt(p.szi, szi0, "ramp-down reduced the position");
        uint256 liq = _liqWad(v);
        // Reduce is proportional at the avg entry: the intended margin/lot is unchanged,
        // so the realized liq stays AT the stop; the parked (not yet withdrawn) excess
        // margin only pushes it DEEPER — never closer (over-lever direction).
        assertLe(liq, stop, "reduce must never lift the long liq above the stop");
        assertGt(liq, stop / 2, "liq still in the stop's neighborhood (not a flatten)");
        assertEq(v.perpStopWad(), stop, "stop unchanged through the reduce");
    }

    // ------------------------------ venue maxLeverage clamp: long (L-halving near anchor)

    function test_V8A_maxlev_clamped_long_liq_further_than_stop() public {
        // L-halving window [0, W). The anchor is `floor` — the 62-min the halving flip
        // promotes — NOT the current window's running low (audit H-4: that one sits beside
        // the live price by construction, so it drove leverage to the venue clamp for any
        // price at all). Seeded here at 99k so the clamp is still exercised, but from the
        // correct anchor: stop = 100k - (100k-99k)/phi = 99_381.97 -> raw L = 161x > 40.
        _seedFloorViaHalvingFlip(99_000);

        _setPx(100_000);
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 0, 120_000e6);
        crankUntilIdle(v, 60);

        uint256 stop = StructuralLeverage.longStop(100_000e18, 99_000e18, 0);
        assertEq(v.perpStopWad(), stop, "frozen L-halving stop");
        assertGt(stop, 99_000e18, "stop within 1% of mark (raw L >> maxLev)");
        CoreTypes.Position memory p = readPos(address(v));
        assertGt(p.szi, 0, "clamped long opened");
        // Clamped at exactly the venue max leverage: notional == margin * 40.
        assertApproxEqRel(_levWad(v), 40e18, 0.001e18, "leverage clamped at venue max");
        uint256 liq = _liqWad(v);
        // liq = mark*(1 - 1/40) = 97_500 < stop = 99_381.97: FURTHER from entry = safe.
        assertLt(liq, stop, "clamped long liquidates FURTHER than the stop (safe side)");
        assertApproxEqRel(liq, 97_500e18, 0.001e18, "liq == mark*(1-1/maxLev)");
    }

    // ------------------------------ venue maxLeverage clamp: short (S-post near anchor)

    function test_V8A_maxlev_clamped_short_liq_further_than_stop() public {
        // Epoch 0 peak window, DENSE: confirm prevPeak-to-be at 99.4k (V9 density gate).
        _sampleDaily(GENESIS_TS + Calendar.P - Calendar.W + 1 days, 11, 99_400);
        // Halving -> epoch 1; its peak window flips peakC into prevPeak.
        uint256 hts = GENESIS_TS + Calendar.P + 1 days;
        vm.warp(hts);
        acceptHalving(GENESIS_HEIGHT + 210_000, uint32(hts));
        vm.warp(hts + Calendar.P - Calendar.W + 1 days);
        _setPx(100_000);
        pool.sampleAnchor(DIR); // epoch-1 opening: lazy promotion of the confirmed 99.4k
        (uint256 prevPeak,,) = pool.peaks(DIR);
        assertEq(prevPeak, 99_400e18, "prevPeak flipped");
        // Complete the dense window so this epoch's C confirms and feeds the engine.
        _sampleDaily(hts + Calendar.P - Calendar.W + 2 days, 10, 100_000);
        (uint256 prevPeak2, uint256 peakC, uint256 peakTag) = pool.peaks(DIR);
        assertEq(prevPeak2, 99_400e18, "prevPeak stable");
        assertEq(peakC, 100_000e18, "C confirmed");
        assertEq(peakTag, 2, "this epoch's peak");

        // Fall of epoch 1, entry at 99.9k: maxStop = 100k + 600/phi = 100_370.8,
        // raw L = 99_900/470.8 = 212x > 40 -> clamp.
        vm.warp(hts + Calendar.P + 10 days);
        _setPx(99_900);
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 0, 120_000e6);
        crankUntilIdle(v, 60);

        uint256 stop = StructuralLeverage.shortStructStop(99_900e18, 99_400e18, 100_000e18);
        assertEq(v.perpStopWad(), stop, "frozen at the clamp value for this entry");
        assertFalse(v.perpStopLong(), "short side");
        CoreTypes.Position memory p = readPos(address(v));
        assertLt(p.szi, 0, "clamped short opened");
        assertApproxEqRel(_levWad(v), 40e18, 0.001e18, "leverage clamped at venue max");
        uint256 liq = _liqWad(v);
        // liq = mark*(1 + 1/40) = 102_397.5 > stop = 100_370.8: FURTHER from entry = safe.
        assertGt(liq, stop, "clamped short liquidates FURTHER than the stop (safe side)");
        assertApproxEqRel(liq, 102_397_500e15, 0.001e18, "liq == mark*(1+1/maxLev)");
    }
}
