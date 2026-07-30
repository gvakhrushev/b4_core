// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {B4VaultStorage} from "src/core/B4VaultStorage.sol";

/// @notice Regression for the last permanent-wedge residual of HAZARDS A7.
///
/// A `ReturnDir`/`ReturnUsdc` whose Core source has already decreased can never resend — A7
/// forbids it, because the first send may still be in flight and a resend would send twice. If
/// the EVM credit is then permanently lost, the leg can never complete either
/// (`received < evmNeeded` forever), so `_verifyReturn` returns false on every crank. Before this
/// escape existed, `emergencyClearRecovery` refused the kind (A6 admits `Recover*` only) and every
/// idle-gated entrypoint — settle, exit finalize, all three recovery paths — died on
/// `_requireIdle()`. The vault was frozen for good, with no admin anywhere able to unstick it.
///
/// The README used to claim the worst reachable state was "delayed liveness, never frozen funds".
/// It was not: this state is reachable, and the fix does not make it unreachable. What the fix
/// changes is the SECOND loss. The first — capital that left Core and never arrived — has already
/// happened and nothing can undo it; refusing to record it is what added the rest of the vault to
/// the casualty list.
contract AuditA6_StuckReturnEscapeTest is VaultTestBase {
    B4Vault v;

    function setUp() public {
        setUpProtocol();
        v = createVault(address(pro));
    }

    /// Deliveries OFF: the venue debits Core spot and owes the EVM side forever (A7).
    function _wedge() internal {
        hub.setAuto(true, true, false);
        fundAndDeposit(v, 1e8, 50_000e6);
        crankUntilIdle(v, 20);
        assertTrue(
            intentKindOf(v) == B4VaultStorage.IntentKind.ReturnUsdc,
            "a Core->EVM return is in flight"
        );
    }

    /// The wedge is real and permanent: cranking does not clear it, and the vault's whole
    /// idle-gated surface is dead behind it.
    function test_a_lost_credit_wedges_the_vault_permanently() public {
        _wedge();

        for (uint256 k = 0; k < 50; k++) {
            vm.warp(block.timestamp + 2 hours); // past RESEND_TIMEOUT, repeatedly
            v.crank();
        }
        assertTrue(
            intentKindOf(v) == B4VaultStorage.IntentKind.ReturnUsdc,
            "no amount of cranking clears it: A7 forbids the resend, the credit never lands"
        );

        // Every idle-gated entrypoint is dead behind the pending intent.
        vm.prank(user);
        vm.expectRevert(B4VaultStorage.IntentPending.selector);
        v.recoverEvm(address(usdc));

        // ...and A6's escape refuses this kind by design: those funds are NOT still on Core.
        vm.prank(user);
        vm.expectRevert(B4VaultStorage.NotRecoveryIntent.selector);
        v.emergencyClearRecovery();
    }

    /// THE ESCAPE. After the timeout the owner realizes the loss, the books are written down to
    /// what Core actually holds, and the vault is usable again.
    function test_owner_can_abandon_the_stuck_return_and_free_the_vault() public {
        _wedge();

        uint256 bookedBefore = v.coreUsdcRotatedWei() + v.coreUsdcMarginWei();
        assertGt(bookedBefore, 0, "books still count the capital that left Core");

        vm.warp(block.timestamp + 31 days);
        vm.prank(user);
        v.abandonStuckReturn();

        assertTrue(intentKindOf(v) == B4VaultStorage.IntentKind.None, "the intent is cleared");
        uint256 bookedAfter = v.coreUsdcRotatedWei() + v.coreUsdcMarginWei();
        assertLt(bookedAfter, bookedBefore, "the loss is recorded, not carried as phantom books");

        // The vault works again: the surviving capital can leave.
        vm.prank(user);
        v.initiateExit(1e18);
        assertEq(v.exitShareWad(), 1e18, "an exit can now be initiated");
    }

    /// Gate 1 — the timeout. Thirty days is ~720x any honest delay, so an impatient caller can
    /// never abandon a leg that is merely slow.
    function test_escape_refuses_before_the_timeout() public {
        _wedge();
        vm.warp(block.timestamp + 29 days);
        vm.prank(user);
        vm.expectRevert(B4VaultStorage.TooEarly.selector);
        v.abandonStuckReturn();
    }

    /// Gate 2 — owner only. It realizes a loss on the owner's own vault, so it is their call.
    function test_escape_is_owner_only() public {
        _wedge();
        vm.warp(block.timestamp + 31 days);
        vm.prank(address(0xBEEF));
        vm.expectRevert(B4VaultStorage.OnlyOwner.selector);
        v.abandonStuckReturn();
    }

    /// Gate 3 — the source must actually have decreased. While Core still holds the amount the
    /// leg is slow, not wedged, and `_verifyReturn`'s resend branch is still live; abandoning
    /// there would discard a claim on funds that still exist, which is what A6 forbids.
    function test_escape_refuses_a_leg_whose_source_still_holds_the_funds() public {
        // Actions QUEUED: the intent exists but the venue has not debited Core at all.
        hub.setAuto(false, true, false);
        fundAndDeposit(v, 1e8, 50_000e6);
        for (uint256 k = 0; k < 20 && intentKindOf(v) == B4VaultStorage.IntentKind.None; k++) {
            v.crank();
        }
        if (intentKindOf(v) != B4VaultStorage.IntentKind.ReturnUsdc) return; // shape not reached

        vm.warp(block.timestamp + 31 days);
        vm.prank(user);
        vm.expectRevert(B4VaultStorage.ReturnNotStuck.selector);
        v.abandonStuckReturn();
    }

    /// A late delivery is not stranded by the abandon: it lands as unaccounted EVM balance, which
    /// is exactly the path any unattributed arrival already takes, and the owner recovers it.
    /// So nothing is destroyed that was not already gone.
    function test_a_late_delivery_is_still_recoverable_after_abandoning() public {
        _wedge();
        vm.warp(block.timestamp + 31 days);
        vm.prank(user);
        v.abandonStuckReturn();

        uint256 ownerBefore = usdc.balanceOf(user);
        hub.deliverEvm(); // the venue finally makes good, long after the write-down
        // Let the freed vault resume planning and come back to rest; recovery needs an idle
        // engine, and the point here is that the arrival survives that, not that it is instant.
        hub.setAuto(true, true, true);
        crankUntilIdle(v, 40);

        vm.prank(user);
        v.recoverEvm(address(usdc));
        assertGt(usdc.balanceOf(user), ownerBefore, "the late arrival reaches the owner");
    }
}
