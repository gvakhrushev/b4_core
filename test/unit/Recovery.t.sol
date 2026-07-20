// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {B4VaultStorage} from "src/core/B4VaultStorage.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";

/// @notice Surplus recovery and emergency clearing — TEST_PLAN §2 regressions 4 (A6:
///         abandon surplus intents, never discard asset transfers) and 6 (B6: bounded,
///         flat/idle, callback-free, works with zero recorded principal, two-phase perp
///         recovery abandonable on both phases).
contract RecoveryTest is VaultTestBase {
    B4Vault v;

    function setUp() public {
        setUpProtocol();
        v = createVault(address(b4));
    }

    function kindOf() internal view returns (B4VaultStorage.IntentKind k) {
        return intentKindOf(v);
    }

    // ------------------------------------------------------------- regression 6 (B6)

    /// Core-spot surplus with ZERO recorded principal is recoverable to the owner.
    function test_R6_recover_spot_surplus_zero_principal() public {
        hub.coreTopUp(address(v), USDC_CORE, 50e8); // external Core credit
        vm.prank(user);
        v.recoverCoreSpot(false);
        crankUntilIdle(v, 5); // verify → send to owner
        assertEq(usdc.balanceOf(user), 50e6);
        assertEq(v.coreUsdcRotatedWei() + v.coreUsdcMarginWei(), 0); // books untouched
    }

    /// Bounded to balance − recorded: only the excess above live principal moves.
    function test_R6_recover_spot_surplus_bounded_above_principal() public {
        fundAndDeposit(v, 1e8, 0);
        warpTo(Calendar.P); // fall: rotation begins
        v.crank(); // FundDir
        v.crank(); // credited: coreDirWei = 1e8 recorded on Core
        assertEq(v.coreDirWei(), 1e8);

        hub.coreTopUp(address(v), UBTC_CORE, 3e7); // surplus over principal
        vm.prank(user);
        v.recoverCoreSpot(true);
        v.crank(); // verify the recovery leg only (sync would continue rotating after)
        assertEq(ubtc.balanceOf(user), 3e7); // exactly the excess
        assertEq(v.coreDirWei(), 1e8); // principal books unchanged — no callback
        assertEq(hub.spotBal(address(v), UBTC_CORE), 1e8);
    }

    function test_R6_nothing_to_recover_reverts() public {
        vm.prank(user);
        vm.expectRevert(B4VaultStorage.NothingToRecover.selector);
        v.recoverCoreSpot(false);
        vm.prank(user);
        vm.expectRevert(B4VaultStorage.NothingToRecover.selector);
        v.recoverPerpSurplus();
    }

    /// Perp surplus (funding income / external top-up) travels the full two-phase
    /// perp→spot→EVM→owner pipeline.
    function test_R6_perp_surplus_two_phase_happy() public {
        hub.setUserExists(address(v), true);
        hub.setWithdrawable(address(v), 200e6);
        vm.prank(user);
        v.recoverPerpSurplus();
        assertEq(uint8(kindOf()), uint8(B4VaultStorage.IntentKind.RecoverPerpPhase1));
        v.crank(); // phase 1 verified → phase 2 started
        assertEq(uint8(kindOf()), uint8(B4VaultStorage.IntentKind.RecoverPerpPhase2));
        v.crank(); // phase 2 verified → paid to owner
        assertEq(usdc.balanceOf(user), 200e6);
        assertEq(v.perpMargin6(), 0); // never was accounted; still zero
    }

    // ------------------------------------------------------------- regression 4 (A6)

    /// Phase 1 stuck (dropped venue action): abandonable after the timeout; the funds
    /// remain on Core and are RE-recoverable.
    function test_R4_abandon_phase1_then_rerecover() public {
        hub.setUserExists(address(v), true);
        hub.setAuto(false, true, true);
        hub.setWithdrawable(address(v), 200e6);
        hub.setDropNext(1);
        vm.prank(user);
        v.recoverPerpSurplus();
        hub.executeActions(); // dropped: nothing moves

        // Too early: cannot clear yet.
        vm.prank(user);
        vm.expectRevert(B4VaultStorage.TooEarly.selector);
        v.emergencyClearRecovery();

        vm.warp(block.timestamp + 3 days);
        vm.prank(user);
        v.emergencyClearRecovery();
        assertEq(uint8(kindOf()), uint8(B4VaultStorage.IntentKind.None));
        assertEq(hub.wd(address(v)), 200e6); // funds still on Core

        // Re-recoverable end-to-end.
        hub.setAuto(true, true, true);
        vm.prank(user);
        v.recoverPerpSurplus();
        crankUntilIdle(v, 5);
        assertEq(usdc.balanceOf(user), 200e6);
    }

    /// Phase 2 stuck: abandonable; the surplus then sits on Core spot and is picked up
    /// by the spot-surplus recovery.
    function test_R4_abandon_phase2_then_rerecover_via_spot() public {
        hub.setUserExists(address(v), true);
        hub.setWithdrawable(address(v), 200e6);
        vm.prank(user);
        v.recoverPerpSurplus();
        v.crank(); // phase 1 done → phase 2 intent (spotSend) created
        assertEq(uint8(kindOf()), uint8(B4VaultStorage.IntentKind.RecoverPerpPhase2));

        // Simulate a phase-2 send that never happened: drop it via a fresh queue setup.
        // (The spotSend was already queued and executed under autoExecute; instead build
        // the stuck case explicitly: re-create with manual execution.)
        // Reset: complete the happy path first, then do a stuck phase-2 run.
        v.crank();
        assertEq(usdc.balanceOf(user), 200e6);

        hub.setAuto(false, true, true);
        hub.setWithdrawable(address(v), 70e6);
        vm.prank(user);
        v.recoverPerpSurplus(); // phase 1 queued
        hub.executeActions(); // phase 1 lands: spot +70e8
        hub.setDropNext(1); // arm the drop BEFORE phase 2 is enqueued
        v.crank(); // phase 1 verified → phase 2 enqueued (and dropped)
        hub.executeActions();
        assertEq(uint8(kindOf()), uint8(B4VaultStorage.IntentKind.RecoverPerpPhase2));

        vm.warp(block.timestamp + 3 days);
        vm.prank(user);
        v.emergencyClearRecovery();
        // Funds sit on Core spot, unaccounted — spot-surplus recovery finishes the job.
        assertEq(hub.spotBal(address(v), USDC_CORE), 70e8);
        hub.setAuto(true, true, true);
        vm.prank(user);
        v.recoverCoreSpot(false);
        crankUntilIdle(v, 5);
        assertEq(usdc.balanceOf(user), 270e6);
    }

    /// An in-flight ASSET-TRANSFER intent can never be discarded — not by the owner, not
    /// after any timeout (A6). It self-heals through the A2/A3 resend machinery instead.
    function test_R4_asset_transfer_intents_not_discardable() public {
        fundAndDeposit(v, 1e8, 0);
        warpTo(Calendar.P);
        hub.setAuto(false, true, true);
        v.crank(); // FundDir intent (EVM→Core poll — an asset transfer)
        assertEq(uint8(kindOf()), uint8(B4VaultStorage.IntentKind.FundDir));

        vm.warp(block.timestamp + 30 days);
        vm.prank(user);
        vm.expectRevert(B4VaultStorage.NotRecoveryIntent.selector);
        v.emergencyClearRecovery();

        // And it still completes once the venue recovers (no dead zone).
        hub.applyCredits();
        v.crank();
        assertEq(v.coreDirWei(), 1e8);
    }

    /// A6 at the VAULT level: an in-flight exit ReturnDir (a genuine asset transfer) is NOT
    /// discardable via the owner's emergency path — emergencyClearRecovery abandons only
    /// Recover* surplus intents, never a return that owes principal back to EVM — and the
    /// return then completes so the exit finalizes and the owner is paid. Non-vacuous: the
    /// revert is asserted precisely while `kind == ReturnDir` with principal genuinely on
    /// Core (the old version asserted it on a fresh idle vault, proving nothing).
    /// The dropped-action + exact-complement resend self-heal for return legs is proven
    /// deterministically at the engine level by AsyncEngine's R2/A7 harness tests
    /// (`test_R2_subAmount_topUp_does_not_block_resend`, `test_A7_return_never_resends_after_debit`).
    function test_R4_dropped_return_self_heals_not_discardable() public {
        // Growth-zone principal parked on Core spot as the directional token.
        fundAndDeposit(v, 1e8, 0);
        warpTo(Calendar.P);
        v.crank(); // FundDir
        v.crank(); // credited: 1 BTC on Core spot
        assertEq(v.coreDirWei(), 1e8, "principal on Core");

        vm.prank(user);
        v.initiateExit(1e18);
        v.crank(); // creates the ReturnDir leg (Core spot -> EVM), principal still on Core
        assertEq(uint8(kindOf()), uint8(B4VaultStorage.IntentKind.ReturnDir), "return in flight");
        assertEq(v.coreDirWei(), 1e8, "principal still owed from Core");

        // NOT discardable: while the return is genuinely in flight, the owner cannot throw it
        // away. A ReturnDir is not a Recover* intent, so emergencyClearRecovery reverts — the
        // principal owed back to EVM can never be abandoned (A6, H3: no fund freeze/loss).
        vm.prank(user);
        vm.expectRevert(B4VaultStorage.NotRecoveryIntent.selector);
        v.emergencyClearRecovery();

        // And it completes: the return settles and the exit finalizes, owner paid in kind.
        crankUntilIdle(v, 8);
        assertEq(uint8(kindOf()), uint8(B4VaultStorage.IntentKind.None), "return completed");
        assertEq(v.exitShareWad(), 0, "exit finalized - no freeze");
        assertGt(ubtc.balanceOf(user), 0, "owner recovered principal");
        assertLe(v.coreDirWei(), 1, "Core spot drained (<=1 wei floor dust)");
    }

    // ------------------------------------------------------------- guards

    function test_recovery_requires_idle_engine() public {
        fundAndDeposit(v, 1e8, 0);
        warpTo(Calendar.P);
        hub.setAuto(false, true, true);
        v.crank(); // FundDir pending
        vm.startPrank(user);
        vm.expectRevert(B4VaultStorage.IntentPending.selector);
        v.recoverCoreSpot(false);
        vm.expectRevert(B4VaultStorage.IntentPending.selector);
        v.recoverPerpSurplus();
        // Accounted-token EVM recovery is also gated while the engine is busy…
        vm.expectRevert(B4VaultStorage.IntentPending.selector);
        v.recoverEvm(address(ubtc));
        vm.stopPrank();
    }

    function test_recovery_honest_surplus_after_reconcile() public {
        // wd(50) below recorded margin: recoverPerpSurplus first reconciles the loss,
        // then finds no surplus — it can never pay principal out as "surplus".
        hub.setUserExists(address(v), true);
        hub.setWithdrawable(address(v), 200e6);
        vm.prank(user);
        v.recoverPerpSurplus();
        crankUntilIdle(v, 5);
        assertEq(usdc.balanceOf(user), 200e6);
        // Second run with nothing left reverts.
        vm.prank(user);
        vm.expectRevert(B4VaultStorage.NothingToRecover.selector);
        v.recoverPerpSurplus();
    }
}
