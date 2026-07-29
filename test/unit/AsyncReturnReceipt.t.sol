// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {B4VaultStorage} from "src/core/B4VaultStorage.sol";

/// @notice Regression for the C-2 class left standing on the Core→EVM leg.
///
///         `_verifyReturn` (and `_verifyRecovery`'s spot phase) proved "the destination
///         received the full amount" — the second half of what HAZARDS A2 demands for a
///         `spot→EVM` leg — with a RAW EVM token-balance delta against a snapshot taken at
///         intent creation. An EVM ERC20 balance is not a reliable balance in the A2 sense:
///         anyone can raise it, and so can the vault's own owner, because `deposit` is
///         reachable while an intent is pending. Any such inflow satisfied the receipt and
///         cleared the intent while the venue was still inside its debit-then-deliver window
///         (A7) — leaving value that is on NEITHER side with no pending marker.
///
///         This was found by the strict-pool invariant campaign
///         (`test/invariant/StrictPool.invariant.t.sol`), which is the first campaign to run
///         the venue asynchronously; the shrunk counterexample is reproduced literally below.
///         The consequence is a break of invariants 3/4/5/6/17 at an IDLE engine — recorded
///         books above real assets — and, for as long as the window lasts, an overstated NAV:
///         settle's profit, the performance fee it charges and the pool weight it mints are
///         all measured against capital the vault does not hold.
contract AsyncReturnReceiptTest is VaultTestBase {
    B4Vault v;

    function setUp() public {
        setUpProtocol();
        v = createVault(address(pro));
    }

    function test_a_deposit_cannot_stand_in_for_the_core_to_evm_receipt() public {
        // Deliveries OFF: the venue debits Core spot and owes the EVM side (A7). Actions and
        // EVM→Core credits stay synchronous so the vault reaches the repatriation step.
        hub.setAuto(true, true, false);
        fundAndDeposit(v, 1e8, 50_000e6);
        crankUntilIdle(v, 20);

        // The planner repatriates the rotation residual: "steady-state custody is EVM".
        assertTrue(
            intentKindOf(v) == B4VaultStorage.IntentKind.ReturnUsdc,
            "a Core->EVM return is in flight"
        );
        assertEq(hub.pendingDeliveries(), 1, "the venue owes the EVM side");
        uint256 booked = v.usdcRotatedEvm() + v.usdcMarginEvm();
        assertGe(usdc.balanceOf(address(v)), booked, "books cover assets before the deposit");

        // The owner tops the vault up while the return is still in flight. `deposit` is not
        // gated on an idle engine, and it raises the EVM balance AND the matching bucket.
        fundAndDeposit(v, 0, 1_000e6);

        v.crank();

        // The leg must NOT have completed: nothing was delivered.
        assertTrue(
            intentKindOf(v) == B4VaultStorage.IntentKind.ReturnUsdc,
            "a deposit is not a delivery receipt"
        );
        // And the books must still be covered, at an idle-or-pending engine alike.
        assertGe(
            usdc.balanceOf(address(v)),
            v.usdcRotatedEvm() + v.usdcMarginEvm(),
            "recorded EVM books exceeded the real EVM balance"
        );

        // The real delivery lands: now, and only now, the leg completes — and the books are
        // still covered afterwards.
        hub.deliverEvm();
        v.crank();
        assertTrue(
            intentKindOf(v) == B4VaultStorage.IntentKind.None, "the delivered leg completes"
        );
        assertGe(
            usdc.balanceOf(address(v)),
            v.usdcRotatedEvm() + v.usdcMarginEvm(),
            "books cover assets after completion"
        );
    }

    /// The residual, stated rather than hidden: a third-party DONATION can still complete
    /// the leg early. No local read can distinguish a donated token from a delivered one, so
    /// this is the standing A11 "attacker-funded surplus" class the engine already documents
    /// on the ToPerp resend gate — and it is the SAFE side of the line, which is exactly what
    /// this test pins: the donor's tokens are physically in the vault, so `books <= assets`
    /// holds throughout, and the real delivery lands afterwards as unaccounted, owner-
    /// recoverable surplus (A11) rather than as a phantom. What the fix removes is the
    /// UNSAFE case above, where the spoofing inflow is itself already booked.
    function test_a_donation_completes_early_but_never_breaks_the_books() public {
        hub.setAuto(true, true, false);
        fundAndDeposit(v, 1e8, 50_000e6);
        crankUntilIdle(v, 20);
        assertTrue(
            intentKindOf(v) == B4VaultStorage.IntentKind.ReturnUsdc,
            "a Core->EVM return is in flight"
        );

        usdc.mint(address(v), 10_000e6); // anyone, at any time
        v.crank();
        assertTrue(
            intentKindOf(v) == B4VaultStorage.IntentKind.None, "documented A11 residual"
        );
        assertGe(
            usdc.balanceOf(address(v)),
            v.usdcRotatedEvm() + v.usdcMarginEvm(),
            "the donation is physically present: books never exceed assets"
        );

        // The genuine delivery lands later and is unaccounted surplus, not a phantom.
        uint256 bookedBefore = v.usdcRotatedEvm() + v.usdcMarginEvm();
        hub.deliverEvm();
        assertEq(v.usdcRotatedEvm() + v.usdcMarginEvm(), bookedBefore, "no double credit");
        assertGt(
            usdc.balanceOf(address(v)), bookedBefore, "the delivery is recoverable surplus"
        );
    }
}
