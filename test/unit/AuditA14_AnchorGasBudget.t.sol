// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {Calendar} from "src/libraries/Calendar.sol";

/// @notice `Keeper.crank` forwards each `sampleAnchor` with an explicit `ANCHOR_GAS` cap and
///         swallows the result. That is the right shape — sampling must never stop calendar or
///         vault liveness — but it means an over-budget sample fails **silently**, and the thing
///         that stops working is the anchor ratchet's only honest competitor (audit L-2). The
///         density gate counts DAYS, so the loss would show up as anchors that never confirm,
///         a cycle later, with nothing on chain saying why.
///
/// The budget is therefore load-bearing and its justification is a measurement — which is exactly
/// the kind of claim that goes stale silently. It did: the constant's docstring names the
/// post-halving reseed as the worst case at 0.09M, and AUDIT-2026-07-29 F2 added two slots
/// (`peakTop`, `peakTopDay`) to `Anchor`, making the PEAK-window reseed dearer than it. This pins
/// the real worst case so the next slot added to `Anchor` fails here instead of in production.
contract AuditA14_AnchorGasBudgetTest is VaultTestBase {
    uint256 constant DIR = 1;

    /// `Keeper.ANCHOR_GAS`, which is `internal` and cannot be read from here. Mirrored
    /// deliberately: if it is ever lowered, this test must be revisited alongside it.
    uint256 constant ANCHOR_GAS = 400_000;

    function setUp() public {
        setUpProtocol();
    }

    function _close(uint256 k) internal pure returns (uint256) {
        return GENESIS_TS + Calendar.P - Calendar.W + k * 1 days;
    }

    function _sampleCost() internal returns (uint256) {
        uint256 g0 = gasleft();
        pool.sampleAnchor(DIR);
        return g0 - gasleft();
    }

    function test_every_sampleAnchor_path_fits_the_keeper_budget_with_margin() public {
        // (a) PEAK-window reseed on a cold Anchor — the dearest path since F2.
        vm.warp(_close(0));
        hub.setSpotPx(SPOT_MKT, uint64(50_000 * 1e4));
        uint256 peakReseed = _sampleCost();

        // (b) a close that raises the candidate, then one that corroborates it.
        vm.warp(_close(1));
        hub.setSpotPx(SPOT_MKT, uint64(60_000 * 1e4));
        uint256 newCandidate = _sampleCost();
        vm.warp(_close(2));
        hub.setSpotPx(SPOT_MKT, uint64(60_000 * 1e4));
        uint256 corroborate = _sampleCost();

        // (c) post-halving reseed on a cold LOW anchor — the path the constant's doc names.
        vm.warp(GENESIS_TS + 2 days);
        hub.setSpotPx(SPOT_MKT, uint64(40_000 * 1e4));
        uint256 postHalving = _sampleCost();

        uint256 worst = peakReseed;
        if (newCandidate > worst) worst = newCandidate;
        if (corroborate > worst) worst = corroborate;
        if (postHalving > worst) worst = postHalving;
        emit log_named_uint("worst sampleAnchor gas", worst);

        // Half the budget, not the whole of it: a sample that merely *fits* leaves no room for a
        // future slot, and the failure mode is silent. Failing here at 2x is the warning.
        assertLt(worst, ANCHOR_GAS / 2, "a sampleAnchor path outgrew half the keeper's budget");

        // The peak path really is the dearest one now — pinned so the docstring cannot drift
        // back to naming the post-halving reseed.
        assertGt(peakReseed, postHalving, "the peak reseed is the worst case, not post-halving");
    }
}
