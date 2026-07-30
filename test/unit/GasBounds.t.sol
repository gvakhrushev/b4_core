// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {Calendar} from "src/libraries/Calendar.sol";

/// @notice The enforcing test for `Keeper`'s gas budgets.
///
/// `Keeper.sol` cited `test/unit/GasBounds.t.sol` as the source of every one of its MEASURED
/// figures — three times — and **the file did not exist**, in this tree or anywhere in history.
/// So four load-bearing constants rested on numbers nothing re-derived, and one of them had
/// already gone stale unnoticed: AUDIT-2026-07-29 F2 added two slots to `Anchor`, which moved the
/// worst `sampleAnchor` path from the post-halving reseed to the peak-window reseed and its cost
/// from 0.09M to 0.106M. A citation to a test that does not exist is worse than no citation: it
/// reads as evidence.
///
/// What each budget's failure actually costs, because it decides how tight the assertion should
/// be here:
///   * `ANCHOR_GAS` — the call is gas-capped AND its result is swallowed, so overrunning it fails
///     **silently**, and what stops working is the anchor ratchet's only honest competitor (L-2).
///     The density gate counts DAYS, so it surfaces as anchors that never confirm, a cycle later.
///     Asserted at HALF the budget: a sample that merely fits leaves no room for the next slot.
///   * `TAIL_RESERVE` / `STEP_GAS` — overrunning these costs a step that the NEXT crank retries
///     (partial progress by design, F2). Benign, so these are regression guards rather than
///     tight bounds.
///
/// Scope, stated rather than implied: these run on the representative single-directional pool the
/// test base builds. The docstring figures for the extreme configuration — the 0.7M tail at
/// MAX_DIRECTIONAL with both points pending and a full 16-deep sweep, and the 17.0/30.0/35.1M
/// sleeve-loop scaling on an 8-directional aggregate pool with all 32 escrow slots funded — are
/// not reproduced here; they are recorded in `Keeper.sol` as the sizing rationale. What this file
/// guarantees is that none of these paths silently grows an order of magnitude.
contract GasBoundsTest is VaultTestBase {
    uint256 constant DIR = 1;

    /// Mirrors of `Keeper`'s `internal` constants, which cannot be read from here. If any is ever
    /// lowered, this file must be revisited in the same change.
    uint256 constant ANCHOR_GAS = 400_000;
    uint256 constant TAIL_RESERVE = 1_500_000;

    function setUp() public {
        setUpProtocol();
    }

    function _close(uint256 k) internal pure returns (uint256) {
        return GENESIS_TS + Calendar.P - Calendar.W + k * 1 days;
    }

    function _sampleCost() internal returns (uint256) {
        uint256 g = gasleft();
        pool.sampleAnchor(DIR);
        return g - gasleft();
    }

    /// The safety-critical budget: every `sampleAnchor` path must fit in half of `ANCHOR_GAS`.
    function test_every_sampleAnchor_path_fits_half_the_keeper_budget() public {
        // (a) PEAK-window reseed on a cold Anchor — the dearest path since F2.
        vm.warp(_close(0));
        hub.setSpotPx(SPOT_MKT, uint64(50_000 * 1e4));
        uint256 peakReseed = _sampleCost();

        // (b) a close raising the candidate, then one corroborating it.
        vm.warp(_close(1));
        hub.setSpotPx(SPOT_MKT, uint64(60_000 * 1e4));
        uint256 newCandidate = _sampleCost();
        vm.warp(_close(2));
        hub.setSpotPx(SPOT_MKT, uint64(60_000 * 1e4));
        uint256 corroborate = _sampleCost();

        // (c) post-halving reseed on a cold LOW anchor — the path the constant's doc named
        //     before F2 moved the worst case.
        vm.warp(GENESIS_TS + 2 days);
        hub.setSpotPx(SPOT_MKT, uint64(40_000 * 1e4));
        uint256 postHalving = _sampleCost();

        uint256 worst = peakReseed;
        if (newCandidate > worst) worst = newCandidate;
        if (corroborate > worst) worst = corroborate;
        if (postHalving > worst) worst = postHalving;
        emit log_named_uint("worst sampleAnchor gas", worst);

        assertLt(worst, ANCHOR_GAS / 2, "a sampleAnchor path outgrew half the keeper's budget");
        assertGt(peakReseed, postHalving, "the peak reseed is the worst case, not post-halving");
    }

    /// The calendar tail — `advance`, `lockPrices`, the sweep window and `capture` — is what
    /// `TAIL_RESERVE` exists to keep runnable after the bounded loops stop. A regression guard:
    /// the failure mode is a retried step, not a silent loss.
    function test_calendar_tail_steps_stay_far_inside_the_reserve() public {
        B4Vault v = createVault(address(mini));
        fundAndDeposit(v, 1e8, 0);
        crankUntilIdle(v, 40);
        warpTo(Calendar.P - Calendar.H);

        uint256 g = gasleft();
        pool.advance();
        uint256 advanceGas = g - gasleft();

        uint256 count = pool.intervalCount();
        g = gasleft();
        try pool.lockPrices(count - 1) {} catch {}
        uint256 lockGas = g - gasleft();

        g = gasleft();
        for (uint256 back = 2; back <= 17; back++) {
            if (count < back) break;
            try pool.sweep(count - back) {} catch {}
        }
        uint256 sweepGas = g - gasleft();

        g = gasleft();
        pool.capture();
        uint256 captureGas = g - gasleft();

        uint256 tail = advanceGas + lockGas + sweepGas + captureGas;
        emit log_named_uint("calendar tail gas", tail);
        assertLt(tail, TAIL_RESERVE / 2, "the calendar tail outgrew half its reserve");
    }
}
