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
/// The convergence is achieved on the POOL side (`B4Pool.forfeitWeight`), NOT by letting the
/// realised share survive the exit — the latter inverts the product's own redistribution model
/// and re-opens the clone-recycling shape of C-1.
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

    /// A PARTIAL exit is not a departure: the remaining capital keeps its reported claim, and
    /// the standing base scales by `keep` rather than vanishing.
    function test_halfB_partial_exit_keeps_proportional_claim() public {
        B4Vault v = _vaultWithProfit();

        hub.setSpotPx(SPOT_MKT, 110_000 * 1e4);
        vm.warp(_p1());
        pool.advance();
        uint256 id = pool.intervalCount() - 1;
        pool.lockPrices(id);

        v.settle(id);
        uint256 reported = pool.weightOf(id, address(v));

        vm.prank(user);
        v.initiateExit(5e17); // 50%
        crankUntilIdle(v, 40);

        assertEq(pool.weightOf(id, address(v)), reported, "partial exit forfeits nothing");
        assertGt(v.rewardBaseWad(), 0, "and the standing base survives, scaled by keep");
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
