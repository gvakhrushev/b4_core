// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {StructuralLeverage} from "src/libraries/StructuralLeverage.sol";
import {Phi} from "src/libraries/Phi.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";

/// @notice V8 Scope A, item 2: freeze-lifecycle re-attack (C1/C4 class).
///         (a) held SHORT + permissionless peak-ratchet mid-hold: size/stop must not move;
///         (b) venue force-close (ADL), no-loss and with-loss: re-open must be FRESH;
///         (c) multi-crank async funding gap with a price move inside: the open must use
///             the post-gap price, not the price at the funding crank;
///         (d) partial exit on a held short: kept capital re-opens against a fresh stop.
contract V8A_FreezeTest is VaultTestBase {
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

    /// Sample the anchor ratchet `n` times, one day apart, starting at the ABSOLUTE time
    /// `t0abs`, at a constant price. 11 daily samples satisfy the V9 density gate
    /// (count ≥ 10 AND span ≥ W/2), so the window's peak confirms and feeds the engine.
    function _sampleDaily(uint256 t0abs, uint256 n, uint256 px) internal {
        for (uint256 k = 0; k < n; k++) {
            vm.warp(t0abs + k * 1 days);
            _setPx(px);
            pool.sampleAnchor(DIR);
        }
    }

    function _liqShortWad(B4Vault v) internal view returns (uint256) {
        CoreTypes.Position memory p = readPos(address(v));
        if (p.szi >= 0) return 0;
        return Phi.mulDiv(
            (uint256(p.entryNtl) + v.perpMargin6()) * 1e4, Phi.WAD, uint256(uint64(-p.szi)) * 1e6
        );
    }

    function _liqLongWad(B4Vault v) internal view returns (uint256) {
        CoreTypes.Position memory p = readPos(address(v));
        if (p.szi <= 0) return 0;
        uint256 margin6 = v.perpMargin6();
        if (uint256(p.entryNtl) <= margin6) return 0;
        return
            Phi.mulDiv((uint256(p.entryNtl) - margin6) * 1e4, Phi.WAD, uint256(uint64(p.szi)) * 1e6);
    }

    // ---------------- (a) held short + peak ratchet mid-hold: nothing may re-lever

    function test_V8A_held_short_ignores_peak_ratchet_mid_hold() public {
        // Deposit in ClosingGrowth (deposits open), then open the short inside OpeningFall
        // (S-win, C = 0 -> frozen stop at the LIVE price).
        warpTo(Calendar.P - Calendar.W + 1 days);
        _setPx(45_000);
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 0, 120_000e6);
        crankUntilIdle(v, 40);
        // Seed the peak window densely at 45k BEFORE the short opens (V9 density gate:
        // only a confirmed running peak is exposed/fed in Fall later).
        _sampleDaily(GENESIS_TS + Calendar.P - Calendar.W + 1 days, 11, 45_000);

        warpTo(Calendar.P - Calendar.H + 2 days);
        _setPx(44_000);
        crankUntilIdle(v, 90);
        assertLt(readPos(address(v)).szi, 0, "short open in the S-win");
        assertFalse(v.perpStopLong());
        uint256 frozen = v.perpStopWad();
        assertEq(
            frozen, StructuralLeverage.shortStructStop(44_000e18, 0, 0), "S-win stop at live p"
        );
        // ATTACK: permissionless peak samples ratchet the running peak UP mid-hold. Since
        // AUDIT-2026-07-29 the served level needs TWO distinct daily closes, so the attack takes
        // two — which is the remedy working, not an obstacle to the property under test: once
        // corroborated the peak HAS moved, and the held short must still ignore it.
        //
        // The first close is a candidate only. The second necessarily lands a day later, and in
        // `OpeningFall` the target ramps with time, so the crank legitimately adds volume in
        // between — the baseline is therefore taken AFTER that ramp has settled, which isolates
        // the ratchet's effect from the calendar's and keeps the assertion exact.
        _setPx(48_000);
        pool.sampleAnchor(DIR);
        (, uint256 candidateOnly,) = pool.peaks(DIR);
        assertEq(candidateOnly, 45_000e18, "one close is a candidate, the anchor has not moved");

        warpTo(Calendar.P - Calendar.H + 3 days);
        _setPx(44_500);
        crankUntilIdle(v, 40); // let the calendar ramp settle before measuring
        int64 szi0 = readPos(address(v)).szi;
        assertEq(v.perpStopWad(), frozen, "the ramp does not thaw the freeze either");

        _setPx(48_000);
        pool.sampleAnchor(DIR); // corroborating close: the peak really does move now
        (, uint256 peakC,) = pool.peaks(DIR);
        assertEq(peakC, 48_000e18, "running peak moved (and stays confirmed)");
        _setPx(44_500);
        crankUntilIdle(v, 10);
        assertEq(readPos(address(v)).szi, szi0, "peak ratchet must not re-size a held short");
        assertEq(v.perpStopWad(), frozen, "frozen stop immune to the ratchet");

        // Deepen the attack: enter Fall, where a FRESH derivation would now feed the
        // confirmed C = 48k (stop would become 48k + 48k/phi = 77_669). The held short
        // must keep its S-win freeze anyway, and the ramp-to-full add must land the
        // combined liquidation on the FROZEN stop.
        warpTo(Calendar.P + 5 days);
        _setPx(44_500);
        crankUntilIdle(v, 40);
        CoreTypes.Position memory p = readPos(address(v));
        assertLt(p.szi, szi0, "ramp added short volume");
        assertEq(v.perpStopWad(), frozen, "held short keeps the S-win freeze inside Fall");
        assertTrue(
            frozen != StructuralLeverage.shortStructStop(44_500e18, 0, 48_000e18),
            "test sanity: a fresh C-fed stop would differ"
        );
        assertApproxEqRel(_liqShortWad(v), frozen, 0.01e18, "combined short liq on frozen stop");
    }

    // ---------------- (b) venue force-close (ADL): re-open always fresh

    function test_V8A_adl_no_loss_close_reopens_fresh() public {
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 0, 120_000e6);
        crankUntilIdle(v, 60);
        assertGt(readPos(address(v)).szi, 0);

        // Venue force-closes the position at NO loss (wd still == recorded principal).
        hub.setPosition(address(v), PERP_MKT, 0, 0);
        // Price drifted while the vault was being closed out.
        _setPx(90_000);
        crankUntilIdle(v, 60);

        assertGt(readPos(address(v)).szi, 0, "re-opened after the ADL");
        assertEq(v.perpMargin6(), 120_000e6, "no-loss close keeps principal");
        assertEq(
            v.perpStopWad(),
            StructuralLeverage.longStop(90_000e18, 0, 0),
            "stop re-derived at the post-ADL price"
        );
        assertApproxEqRel(
            _liqLongWad(v), StructuralLeverage.longStop(90_000e18, 0, 0), 0.005e18, "fresh liq"
        );
    }

    function test_V8A_adl_lossy_close_writes_down_and_reopens_fresh() public {
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 0, 120_000e6);
        crankUntilIdle(v, 60);
        assertGt(readPos(address(v)).szi, 0);

        // Venue liquidation: position gone, only 80k of the 120k principal recoverable.
        hub.setPosition(address(v), PERP_MKT, 0, 0);
        hub.setWithdrawable(address(v), 80_000e6);
        _setPx(90_000);
        crankUntilIdle(v, 60);

        assertEq(v.perpMargin6(), 80_000e6, "B2 write-down to the real withdrawable");
        assertGt(readPos(address(v)).szi, 0, "re-opened on the written-down margin");
        assertEq(
            v.perpStopWad(),
            StructuralLeverage.longStop(90_000e18, 0, 0),
            "stop re-derived fresh after the loss"
        );
        assertApproxEqRel(
            _liqLongWad(v), StructuralLeverage.longStop(90_000e18, 0, 0), 0.005e18, "fresh liq"
        );
    }

    // ---------------- (c) multi-crank funding gap: the open uses the POST-gap price

    function test_V8A_multicrank_funding_gap_opens_at_fresh_stop() public {
        hub.setAuto(false, false, true); // every Core effect queued: the async gap
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 0, 120_000e6);

        assertTrue(v.crank(), "fund intent created; stop frozen at 100k");
        assertEq(v.perpStopWad(), StructuralLeverage.longStop(100_000e18, 0, 0), "frozen pre-gap");

        // The gap: price moves 20% while the margin leg is still in flight.
        _setPx(80_000);
        hub.applyCredits(); // EVM->Core credit lands
        v.crank(); // verifyFund completes
        v.crank(); // plan: ToPerp (stop re-derived HERE at 80k, still flat)
        assertEq(
            v.perpStopWad(),
            StructuralLeverage.longStop(80_000e18, 0, 0),
            "flat crank re-derives: gap kills the stale 100k stop"
        );
        hub.executeActions(); // ToPerp executes
        v.crank(); // verifyToPerp
        v.crank(); // plan: the opening order
        hub.executeActions(); // fill
        crankUntilIdle(v, 20);

        assertGt(readPos(address(v)).szi, 0, "opened after the gap");
        assertEq(v.perpStopWad(), StructuralLeverage.longStop(80_000e18, 0, 0), "opened FRESH");
        assertApproxEqRel(
            _liqLongWad(v),
            StructuralLeverage.longStop(80_000e18, 0, 0),
            0.005e18,
            "liq at the post-gap stop, not the pre-gap one"
        );
    }

    // ---------------- (d) partial exit on a held short: kept capital re-opens fresh

    function test_V8A_partial_exit_short_reopens_fresh() public {
        // Confirm C = 50k (dense sampling — the V9 density gate must confirm the peak
        // before the Fall freshness gate feeds it), then open the deep short in Fall at
        // 40k (sub-1x, pinned stop).
        _sampleDaily(GENESIS_TS + Calendar.P - Calendar.W + 1 days, 11, 50_000);
        warpTo(Calendar.P + 30 days);
        _setPx(40_000);
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 0, 120_000e6);
        crankUntilIdle(v, 60);
        assertLt(readPos(address(v)).szi, 0, "short open");
        uint256 stop0 = v.perpStopWad();
        assertEq(stop0, StructuralLeverage.shortStructStop(40_000e18, 0, 50_000e18), "maxStop");

        // Held through a price move; then a 50% exit (penalized in Fall — irrelevant here).
        int64 sziHeld = readPos(address(v)).szi;
        _setPx(44_000);
        crankUntilIdle(v, 10);
        assertEq(readPos(address(v)).szi, sziHeld, "short held through the price move");
        vm.prank(user);
        v.initiateExit(5e17);
        crankUntilIdle(v, 80);
        assertEq(v.exitShareWad(), 0, "exit finalized");
        // (The finalize clears the stop transiently; the same idle crank loop immediately
        // re-derives it flat — the clear is not externally observable, the fresh re-open is.)

        // Kept capital re-opens the short at the CURRENT price, stop re-derived (the
        // S-post maxStop is entry-independent, but the FREEZE must be re-armed, not stale).
        crankUntilIdle(v, 60);
        CoreTypes.Position memory p = readPos(address(v));
        assertLt(p.szi, 0, "kept capital re-shorted");
        assertEq(
            v.perpStopWad(),
            StructuralLeverage.shortStructStop(44_000e18, 0, 50_000e18),
            "fresh freeze at re-open"
        );
        assertApproxEqRel(_liqShortWad(v), v.perpStopWad(), 0.01e18, "liq on the fresh stop");
        // Whole kept NAV redeployed as margin (no stranded USDC after the re-open).
        assertApproxEqRel(
            uint256(v.perpMargin6()), v.navWad() / 1e12, 0.02e18, "whole kept NAV is margin"
        );
    }
}
