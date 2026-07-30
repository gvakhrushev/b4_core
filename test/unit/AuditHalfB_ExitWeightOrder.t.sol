// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {Phi} from "src/libraries/Phi.sol";

/// @notice Regression for AUDIT-2026-07-25 C-1 "half B" — the exit/settle ORDER DEPENDENCE.
///
/// The same economic event, realise profit and leave in full, produced opposite outcomes:
///   `settle` then exit  → the vault-side base was annihilated by `keep == 0`, but the POOL
///                         kept the full reported claim: it was never told about the exit;
///   exit without settle → nothing was ever reported, so there was no claim at all.
/// Both orders now converge on the SPEC §9 outcome: a vault that has fully exited holds no
/// standing base and no reported pool weight. The basket is funded by leavers for the benefit
/// of stayers, so a vault holding no capital must not hold a claim on it.
///
/// The convergence is achieved on the POOL side (`B4Pool.scaleWeight`), NOT by letting the
/// realised share survive the exit — the latter inverts the product's own redistribution model
/// and re-opens the clone-recycling shape of C-1.
///
/// AUDIT-2026-07-29 F1 generalised the pool side from the exact boundary `keep == 0` to a
/// proportional scaling on every exit: weight tracks the capital still standing behind it. The
/// full-exit case below is unchanged — it is now the endpoint of a ramp instead of a special
/// case — while a partial exit surrenders exactly the share it withdrew.
contract AuditHalfB_ExitWeightOrderTest is VaultTestBase {
    function setUp() public {
        setUpProtocol();
    }

    function _p1() internal pure returns (uint256) {
        return GENESIS_TS + Calendar.P - Calendar.H;
    }

    function _vaultWithProfit() internal returns (B4Vault v) {
        v = createVault(address(mini));
        fundAndDeposit(v, 1e8, 0); // 1 BTC at 100k
        crankUntilIdle(v, 20);
    }

    function test_halfB_settle_then_exit_and_exit_then_settle_agree() public {
        B4Vault a = _vaultWithProfit();
        B4Vault b = _vaultWithProfit();
        B4Vault stayer = _vaultWithProfit();

        hub.setSpotPx(SPOT_MKT, 110_000 * 1e4); // a real +10k each
        vm.warp(_p1());
        pool.advance();
        uint256 id = pool.intervalCount() - 1;
        pool.lockPrices(id);

        // A: settle first, then exit in full.
        a.settle(id);
        assertGt(pool.weightOf(id, address(a)), 0, "A reported before exiting");
        vm.prank(user);
        a.initiateExit(Phi.WAD);
        crankUntilIdle(a, 40);

        // B: exit in full first, then settle.
        vm.prank(user);
        b.initiateExit(Phi.WAD);
        crankUntilIdle(b, 40);
        b.settle(id);

        // The stayer keeps its capital and settles normally — the control.
        stayer.settle(id);

        // The property under test: a full exit leaves NO claim on the interval, whichever
        // order the two calls happen in.
        uint256 wStayer = pool.weightOf(id, address(stayer));
        assertGt(wStayer, 0, "the stayer earned a real share");
        assertEq(pool.weightOf(id, address(a)), 0, "settle-then-exit: weight forfeited");
        assertEq(a.rewardBaseWad(), 0, "A standing base zeroed");

        // B settles AFTER emptying itself, so its entry ledger is 0 and the dust the exit
        // waterfall floored back to the vault reads as profit. That residual is real but is
        // bounded by the flooring dust — documented, not zero. Assert the bound rather than
        // pretend it vanishes: it must be negligible against an actual participant's share.
        uint256 wB = pool.weightOf(id, address(b));
        assertLt(wB, wStayer / 1_000_000, "exit-then-settle: at most flooring dust");

        // The forfeited weight is genuinely out of the denominator, so it is the remaining
        // stayers who gain, not a dangling claim that dilutes them.
        (,,, uint256 totalWeight) = pool.intervalInfo(id);
        assertEq(totalWeight, wStayer + wB, "only the stayer (plus B's dust) is counted");
    }

    /// A full exit surrenders the pool-side claim. The exiting owner is still paid their
    /// capital and realised profit in kind by the exit itself — the forfeited item is the
    /// claim on OTHER users' exit penalties, which only stayers are entitled to.
    function test_halfB_full_exit_forfeits_reported_pool_weight() public {
        B4Vault v = _vaultWithProfit();

        hub.setSpotPx(SPOT_MKT, 110_000 * 1e4);
        vm.warp(_p1());
        pool.advance();
        uint256 id = pool.intervalCount() - 1;
        pool.lockPrices(id);

        v.settle(id);
        uint256 reported = pool.weightOf(id, address(v));
        assertGt(reported, 0, "weight was reported");
        (,,, uint256 beforeTotal) = pool.intervalInfo(id);
        assertEq(beforeTotal, reported);

        vm.prank(user);
        v.initiateExit(Phi.WAD);
        crankUntilIdle(v, 40);

        assertEq(pool.weightOf(id, address(v)), 0, "claim surrendered");
        (,,, uint256 afterTotal) = pool.intervalInfo(id);
        assertEq(afterTotal, 0, "and removed from the denominator");
        assertEq(v.entryLedgerWad(), 0, "capital is gone");
        assertEq(v.rewardBaseWad(), 0, "so is the claim");
    }

    /// A PARTIAL exit surrenders exactly the share it withdrew: the reported claim scales by
    /// `keep`, in lock step with the standing base, so weight always tracks the capital still
    /// standing behind it (AUDIT-2026-07-29 F1).
    ///
    /// This REVERSES the earlier rule that "a partial exit forfeits nothing" (recorded at
    /// `docs/audits/REVIEW-2026-07-25-agent-changes.md:418-431`). That rule made the pool side
    /// an exact-equality test on `keep == 0`, a number the owner chooses, so `initiateExit(WAD
    /// − 1)` paid out everything but flooring dust and kept the whole claim. There is no
    /// threshold that fixes an exact-boundary test — every threshold has its own "just above",
    /// and a measure taken from the post-exit BASE is re-inflatable by the exiting share's own
    /// unsettled profit. Proportional scaling removes the boundary instead of moving it.
    function test_halfB_partial_exit_scales_the_claim_by_keep() public {
        B4Vault v = _vaultWithProfit();

        hub.setSpotPx(SPOT_MKT, 110_000 * 1e4);
        vm.warp(_p1());
        pool.advance();
        uint256 id = pool.intervalCount() - 1;
        pool.lockPrices(id);

        v.settle(id);
        uint256 reported = pool.weightOf(id, address(v));
        (,,, uint256 totalBefore) = pool.intervalInfo(id);

        vm.prank(user);
        v.initiateExit(5e17); // 50%
        crankUntilIdle(v, 40);

        uint256 kept = Phi.wmul(reported, 5e17);
        assertEq(pool.weightOf(id, address(v)), kept, "a 50% exit keeps exactly 50% of the claim");
        (,,, uint256 totalAfter) = pool.intervalInfo(id);
        assertEq(totalAfter, totalBefore - (reported - kept), "denominator drops by the same");
        assertGt(v.rewardBaseWad(), 0, "and the standing base survives, scaled by keep");
    }

    /// The F1 exploit input, refused. `initiateExit(WAD − 1)` withdraws every unit of the
    /// position but flooring dust; under the old `keep == 0` boundary it kept 100% of the
    /// reported weight and collected a full pro-rata share of a basket funded by other
    /// participants' penalties. The claim must now be dust too.
    function test_halfB_near_total_exit_cannot_keep_its_reported_weight() public {
        B4Vault v = _vaultWithProfit();
        B4Vault stayer = _vaultWithProfit();

        hub.setSpotPx(SPOT_MKT, 110_000 * 1e4);
        vm.warp(_p1());
        pool.advance();
        uint256 id = pool.intervalCount() - 1;
        pool.lockPrices(id);

        v.settle(id);
        stayer.settle(id);
        uint256 reported = pool.weightOf(id, address(v));
        uint256 stayerWeight = pool.weightOf(id, address(stayer));
        assertGt(reported, 0, "reported before exiting");

        vm.prank(user);
        v.initiateExit(Phi.WAD - 1); // everything but one wei of share
        crankUntilIdle(v, 40);

        uint256 left = pool.weightOf(id, address(v));
        assertLt(left, reported / 1e6, "a near-total exit keeps under 1 ppm of its own claim");
        assertLt(left, stayerWeight / 1e6, "and under 1 ppm of a stayer's");
        (,,, uint256 total) = pool.intervalInfo(id);
        assertEq(total, stayerWeight + left, "totalWeight stays the exact sum of survivors");
    }

    /// Splitting the exit into steps cannot dodge the scaling: each call re-reads the live
    /// weight, so the effect compounds multiplicatively. Three 80% exits leave 0.8³ = 51.2% of
    /// the capital's share, not the 100% an unsplit-only rule would have left.
    function test_halfB_split_exit_compounds_and_cannot_dodge() public {
        B4Vault v = _vaultWithProfit();

        hub.setSpotPx(SPOT_MKT, 110_000 * 1e4);
        vm.warp(_p1());
        pool.advance();
        uint256 id = pool.intervalCount() - 1;
        pool.lockPrices(id);

        v.settle(id);
        uint256 reported = pool.weightOf(id, address(v));

        for (uint256 k = 0; k < 3; k++) {
            vm.prank(user);
            v.initiateExit(8e17); // 80% of what remains
            crankUntilIdle(v, 40);
        }

        // 0.2³ = 0.008 of the reported claim survives, up to flooring dust.
        assertLt(pool.weightOf(id, address(v)), reported / 100, "compounded well below 1%");
        assertGt(pool.weightOf(id, address(v)), 0, "but nothing is destroyed outright");
    }

    /// SPEC §9: repeated partial exits must not mint or duplicate weight. With the restored
    /// `(R + C·x)·keep` the accrual is a strict contraction, so no exit pattern can accrue
    /// more than a single settle's client share.
    function test_halfB_repeated_exits_stay_bounded_by_one_client_share() public {
        B4Vault v = _vaultWithProfit();
        hub.setSpotPx(SPOT_MKT, 110_000 * 1e4);
        uint256 fee = Phi.wmul(10_000e18, Phi.FEE_F);
        uint256 fullClientShare = fee - Phi.bps(fee, 3000);

        for (uint256 i = 0; i < 12; i++) {
            vm.prank(user);
            v.initiateExit(2e17); // 20% each
            crankUntilIdle(v, 20);
        }
        assertLe(v.rewardBaseWad(), fullClientShare, "never more than one settle's worth");
    }
}
