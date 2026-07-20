// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {B4VaultStorage} from "src/core/B4VaultStorage.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {Phi} from "src/libraries/Phi.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";

/// @notice Exit machine (SPEC §9): live-position-driven flatten, single in-kind penalty
///         q with the operator cut carved from it, partial-exit ledger math, and
///         invariant 14 (Core principal returns before any proportional payment).
contract ExitTest is VaultTestBase {
    // Deep-growth instant: deposits open, exits NOT free.
    uint256 constant T_PAID = 100 days;

    function setUp() public {
        setUpProtocol();
    }

    function _vaultWithProfit() internal returns (B4Vault v) {
        warpTo(T_PAID);
        v = createVault(address(mini));
        fundAndDeposit(v, 1e8, 0); // E = 100,000
        hub.setSpotPx(SPOT_MKT, 110_000e4); // +10% ⇒ NAV 110,000
    }

    // ------------------------------------------------------------- penalty math

    /// Outside a free window: penalty = gross·q; operator = min(cut, penalty), carved
    /// from the single penalty — never added; owner = gross − penalty; pool = rest.
    function test_full_exit_outside_free_window() public {
        B4Vault v = _vaultWithProfit();
        vm.prank(user);
        v.initiateExit(1e18);
        crankUntilIdle(v, 10);
        assertEq(v.exitShareWad(), 0);

        uint256 gross = 110_000e18;
        uint256 vf = Phi.wmul(10_000e18, Phi.FEE_F);
        uint256 ocx = Phi.bps(vf, 3000);
        uint256 penalty = Phi.wmul(gross, Phi.EXIT_Q);
        uint256 ownerWad = gross - penalty;
        uint256 poolWad = penalty - ocx; // operator cut < penalty here

        // In-kind single-token split of the 1 BTC bucket.
        uint256 ownerBtc = Phi.mulDiv(1e8, ownerWad, gross);
        uint256 opBtc = Phi.mulDiv(1e8, ocx, gross);
        uint256 poolBtc = Phi.mulDiv(1e8, poolWad, gross);
        assertEq(ubtc.balanceOf(user), ownerBtc);
        assertEq(ubtc.balanceOf(operator) + ubtc.balanceOf(referrer), opBtc);
        assertEq(ubtc.balanceOf(referrer), Phi.bps(opBtc, 4000)); // carve from operator
        assertEq(ubtc.balanceOf(address(pool)), poolBtc);
        // The penalty entered the pool as measured inventory (D2).
        assertEq(pool.liability(address(ubtc)), poolBtc);
        assertEq(pool.accruing(1), poolBtc);
        // Ledgers zeroed on a full exit.
        assertEq(v.entryLedgerWad(), 0);
        assertEq(v.rewardBaseWad(), 0);
    }

    /// Inside a free window: owner = gross − proportional operator cut; pool gets 0.
    function test_full_exit_free_window_no_penalty() public {
        B4Vault v = _vaultWithProfit();
        warpTo(Calendar.P - Calendar.W + 1); // ClosingGrowth: free exit
        vm.prank(user);
        v.initiateExit(1e18);
        crankUntilIdle(v, 10);

        uint256 gross = 110_000e18;
        uint256 vf = Phi.wmul(10_000e18, Phi.FEE_F);
        uint256 ocx = Phi.bps(vf, 3000);
        uint256 ownerBtc = Phi.mulDiv(1e8, gross - ocx, gross);
        assertEq(ubtc.balanceOf(user), ownerBtc);
        assertEq(ubtc.balanceOf(address(pool)), 0); // no penalty at all
        assertEq(pool.liability(address(ubtc)), 0);
        // Operator cut still flows in a free window (unified fee logic, decision C2).
        assertEq(ubtc.balanceOf(operator) + ubtc.balanceOf(referrer), Phi.mulDiv(1e8, ocx, gross));
    }

    function test_post_halving_window_is_free() public {
        B4Vault v = _vaultWithProfit();
        // Next halving accepted ⇒ a fresh post-fact free window opens at t = 0.
        uint32 ts = uint32(GENESIS_TS + 110 days);
        vm.warp(uint256(ts) + 1 days);
        acceptHalving(GENESIS_HEIGHT + 210_000, ts);
        vm.prank(user);
        v.initiateExit(1e18);
        crankUntilIdle(v, 10);
        assertEq(ubtc.balanceOf(address(pool)), 0); // free: no penalty
    }

    /// The operator payment is carved FROM the single penalty (min(cut, penalty)), never
    /// added on top. Under the reference constants the min() can never bind: the cut is
    /// bounded by MAX_OPERATOR_BPS·f ≈ 1.72% of the exiting profit ≤ 1.72% of gross,
    /// far below the 11.80% penalty — the branch is defensive-only, asserted here both
    /// structurally and on actual paid amounts.
    function test_operator_carve_capped_by_penalty() public {
        warpTo(T_PAID);
        B4Vault v = createVault(address(mini));
        fundAndDeposit(v, 1e8, 0);
        hub.setSpotPx(SPOT_MKT, 10_000_000e4); // ×100: enormous profit
        vm.prank(user);
        v.initiateExit(1e18);
        crankUntilIdle(v, 10);

        uint256 gross = 10_000_000e18;
        uint256 penalty = Phi.wmul(gross, Phi.EXIT_Q);
        uint256 vf = Phi.wmul(gross - 100_000e18, Phi.FEE_F);
        uint256 ocx = Phi.bps(vf, 3000);
        assertLt(ocx, penalty); // even a ×100 profit keeps the cut under the penalty
        // Structural bound: cut ≤ gross·f·maxBps < gross·q for ANY profit ≤ gross.
        assertLt(Phi.bps(Phi.wmul(gross, Phi.FEE_F), uint16(Phi.MAX_OPERATOR_BPS)), penalty);

        uint256 penaltyBtc = Phi.mulDiv(1e8, penalty, gross);
        uint256 opGot = ubtc.balanceOf(operator) + ubtc.balanceOf(referrer);
        uint256 poolGot = ubtc.balanceOf(address(pool));
        // operator + pool together == exactly the single in-kind penalty; the operator
        // slice never exceeds it, and the user never pays cut + penalty.
        assertApproxEqAbs(opGot + poolGot, penaltyBtc, 2);
        assertLe(opGot, penaltyBtc);
        assertEq(ubtc.balanceOf(user), Phi.mulDiv(1e8, gross - penalty, gross));
    }

    // ------------------------------------------------------------- partial exits

    function test_partial_exit_ledger_math() public {
        B4Vault v = _vaultWithProfit();
        vm.prank(user);
        v.initiateExit(4e17); // exit 40%
        crankUntilIdle(v, 10);

        uint256 vf = Phi.wmul(10_000e18, Phi.FEE_F);
        uint256 clientShare = vf - Phi.bps(vf, 3000);
        // nextEntry = E·(1−x); nextRewardBase = (R + C·x)·(1−x) — C of the exiting share.
        assertEq(v.entryLedgerWad(), Phi.wmul(100_000e18, 6e17));
        assertEq(v.rewardBaseWad(), Phi.wmul(Phi.wmul(clientShare, 4e17), 6e17));
        // 60% of the position remains accounted.
        assertGt(v.dirEvm(), 5e7);
        assertEq(v.exitShareWad(), 0);
    }

    /// Repeated partial exits never create or duplicate reward weight (SPEC §9). The
    /// fail-before reading (full-vault C added on every exit) let repeated DUST exits
    /// mint unbounded weight; verified here as the adversarial attempt.
    function test_repeated_partial_exits_no_weight_duplication() public {
        B4Vault v = _vaultWithProfit();
        uint256 vf = Phi.wmul(10_000e18, Phi.FEE_F);
        uint256 fullClientShare = vf - Phi.bps(vf, 3000);

        // Attack: ten dust exits (0.1% each) trying to farm weight.
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(user);
            v.initiateExit(1e15);
            crankUntilIdle(v, 10);
        }
        // Weight stays bounded by ~Σ C·x ≈ 1% of one full client share — the fail-before
        // build accrued ≈ 10 × full C here.
        assertLt(v.rewardBaseWad(), fullClientShare / 50);

        // And an honest 50% exit retains exactly the proportional client share.
        uint256 rBefore = v.rewardBaseWad();
        uint256 navBefore = v.navWad();
        uint256 profitBefore = navBefore > v.entryLedgerWad() ? navBefore - v.entryLedgerWad() : 0;
        vm.prank(user);
        v.initiateExit(5e17);
        crankUntilIdle(v, 10);
        uint256 vf2 = Phi.wmul(profitBefore, Phi.FEE_F);
        uint256 c2 = Phi.wmul(vf2 - Phi.bps(vf2, 3000), 5e17);
        assertApproxEqAbs(v.rewardBaseWad(), Phi.wmul(rBefore + c2, 5e17), 1e9);
    }

    // ------------------------------------------------------------- invariant 14

    /// Any withdrawal with Core exposure first realizes a strictly-flat NAV and returns
    /// ALL Core principal before the proportional EVM payment.
    function test_exit_returns_core_principal_before_payment() public {
        B4Vault v = createVault(address(b4));
        fundAndDeposit(v, 1e8, 0);
        warpTo(Calendar.P); // fall: rotation begins
        v.crank(); // FundDir created
        v.crank(); // credited: coreDirWei = 1e8 — principal now ON CORE
        assertEq(v.coreDirWei(), 1e8);
        assertEq(v.dirEvm(), 0);

        vm.prank(user);
        v.initiateExit(1e18);
        // Mid-exit: nothing paid while principal sits on Core.
        v.crank(); // return-dir intent created
        assertEq(ubtc.balanceOf(user), 0);
        crankUntilIdle(v, 10);
        // Exit completed only after the Core principal came home.
        assertEq(v.exitShareWad(), 0);
        assertEq(v.coreDirWei(), 0);
        // Fall plateau is NOT free ⇒ owner receives gross − penalty in kind.
        uint256 ownerBtc = Phi.mulDiv(1e8, 1e18 - Phi.EXIT_Q, 1e18);
        assertEq(ubtc.balanceOf(user), ownerBtc);
    }

    // ------------------------------------------------------------- gates

    function test_exit_gates() public {
        B4Vault v = _vaultWithProfit();
        vm.startPrank(user);
        vm.expectRevert(B4VaultStorage.BadShare.selector);
        v.initiateExit(0);
        vm.expectRevert(B4VaultStorage.BadShare.selector);
        v.initiateExit(1e18 + 1);
        v.initiateExit(1e18);
        vm.expectRevert(B4VaultStorage.ExitPending.selector);
        v.initiateExit(1e18);
        vm.expectRevert(B4VaultStorage.ExitPending.selector);
        v.deposit(1, 0);
        vm.expectRevert(B4VaultStorage.ExitPending.selector);
        v.selectPolicy(address(proMax), 1e18);
        vm.stopPrank();
        vm.expectRevert(B4VaultStorage.ExitPending.selector);
        v.settle(0);
    }

    /// Exit valuation is the LIVE oracle (decision C2) — by design not snapshot-protected.
    function test_exit_uses_live_oracle() public {
        B4Vault v = _vaultWithProfit();
        hub.setSpotPx(SPOT_MKT, 200_000e4); // moves again before the exit
        vm.prank(user);
        v.initiateExit(1e18);
        crankUntilIdle(v, 10);
        uint256 gross = 200_000e18; // live, not the 110k of _vaultWithProfit
        uint256 penalty = Phi.wmul(gross, Phi.EXIT_Q);
        assertEq(ubtc.balanceOf(user), Phi.mulDiv(1e8, gross - penalty, gross));
    }
}
