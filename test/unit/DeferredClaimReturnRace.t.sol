// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {B4VaultStorage} from "src/core/B4VaultStorage.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {Keeper} from "src/periphery/Keeper.sol";

/// @notice Regression for the deferred-payout leak in the A2 receipt measure.
///
///         `_unaccountedEvm` is the receipt proof for every Core→EVM leg: the leg completes
///         only once the EVM balance IN EXCESS of the vault's recorded buckets has grown by
///         the full delivered amount. `deferredPayoutTotal` was excluded from those buckets
///         on the stated grounds that it "changes only inside settle / exit-finalize, both
///         of which require an idle engine" — but `claimDeferred` is PERMISSIONLESS and has
///         no idle gate, so a claim lowered the EVM balance without lowering the measure.
///
///         Mid-flight, that is terminal: `received` can never reach `evmNeeded` again, and
///         because the Core source already decreased, A7 keeps the resend branch shut. The
///         intent can neither complete nor resend, `emergencyClearRecovery` refuses it (it
///         takes `Recover*` kinds only), and every idle-gated entrypoint — settle, exit
///         finalize, all three recovery paths — dies on `_requireIdle()` with no admin to
///         unstick it. `Keeper.crank` reaches `crankVault` and then `retryDeferred` on the
///         same vault in ONE transaction, so an honest keeper triggered it unaided.
contract DeferredClaimReturnRaceTest is VaultTestBase {
    B4Vault v;

    function setUp() public {
        setUpProtocol();
        v = createVault(address(pro));
    }

    function p1() internal pure returns (uint256) {
        return Calendar.P - Calendar.H;
    }

    /// Fixture: a non-zero deferred USDC payout, plus a live `ReturnUsdc` whose Core source
    /// has ALREADY been debited (`decreased == true`, so no resend is possible) and whose
    /// EVM delivery the venue still owes (A7's debit-then-deliver window).
    function _liveReturnWithDeferredUsdc() internal returns (uint256 deferred) {
        fundAndDeposit(v, 1e8, 50_000e6);
        crankUntilIdle(v, 40);

        // Interval profit, and a USDC-blacklisted operator: the USDC half of the in-kind cut
        // defers instead of freezing settle (H3).
        hub.setSpotPx(SPOT_MKT, 120_000e4);
        hub.setMarkPx(PERP_MKT, 120_000e2);
        hub.setOraclePx(PERP_MKT, 120_000e2);
        warpTo(p1());
        pool.advance();
        pool.lockPrices(0);
        usdc.setBlockedTo(operator, true);
        v.settle(0);
        deferred = v.deferredPayout(operator, address(usdc));
        assertGt(deferred, 0, "a deferred USDC payout exists");

        // Deliveries held: the venue debits Core spot and owes the EVM side.
        hub.setAuto(true, true, false);
        fundAndDeposit(v, 0, 50_000e6);
        for (uint256 i = 0; i < 30; i++) {
            v.crank();
            if (intentKindOf(v) == B4VaultStorage.IntentKind.ReturnUsdc) break;
        }
        assertTrue(
            intentKindOf(v) == B4VaultStorage.IntentKind.ReturnUsdc,
            "a Core->EVM USDC return is in flight"
        );
        assertGt(hub.pendingDeliveries(), 0, "the venue owes the EVM side");

        // The issuer un-blacklists: the deferred transfer now succeeds, so the claim lands.
        usdc.setBlockedTo(operator, false);
    }

    /// Any caller may claim mid-flight. It must pay the recorded recipient, must NOT stand
    /// in for the delivery receipt, and must NOT cost the leg its ability to complete.
    function test_permissionless_claim_cannot_wedge_a_live_return() public {
        uint256 deferred = _liveReturnWithDeferredUsdc();

        address anyone = address(0xBEEF);
        vm.prank(anyone);
        v.claimDeferred(operator, address(usdc));
        assertEq(usdc.balanceOf(operator), deferred, "only the recorded recipient is paid");
        assertEq(v.deferredPayout(operator, address(usdc)), 0, "the claim cleared");

        // A claim is an OUTFLOW: it must not satisfy the receipt either (A2 unweakened).
        v.crank();
        assertTrue(
            intentKindOf(v) == B4VaultStorage.IntentKind.ReturnUsdc,
            "a claim is not a delivery receipt"
        );

        // Fail-before: `received` was permanently `evmNeeded - deferred`, so this crank —
        // and every later one — left the intent standing forever.
        hub.deliverEvm();
        v.crank();
        assertTrue(
            intentKindOf(v) == B4VaultStorage.IntentKind.None,
            "the delivered leg completes after a mid-flight claim"
        );

        // Not frozen: the engine reaches idle again, so the idle-gated entrypoints live.
        hub.setAuto(true, true, true);
        crankUntilIdle(v, 40);
        assertTrue(intentKindOf(v) == B4VaultStorage.IntentKind.None, "vault still cranks");
        assertGe(
            usdc.balanceOf(address(v)),
            v.usdcRotatedEvm() + v.usdcMarginEvm() + v.deferredPayoutTotal(address(usdc)),
            "books plus what the vault owes never exceed the real EVM balance"
        );
    }

    /// The non-adversarial case: one honest `Keeper.crank` cranks the vault (the leg is not
    /// yet verifiable — the venue still owes the EVM side) and then retries the deferred
    /// payout, in a single transaction.
    function test_honest_keeper_bundled_crank_and_retry_never_wedges() public {
        _liveReturnWithDeferredUsdc();

        Keeper keeper = new Keeper();
        address[] memory vaults = new address[](1);
        vaults[0] = address(v);

        // One step per vault, so the assertion below is about THIS leg and not a successor
        // the keeper would otherwise open in the same burst (deliveries are still held).
        keeper.crank(pool, vaults, 1);
        assertEq(v.deferredPayout(operator, address(usdc)), 0, "the keeper retried the payout");
        assertTrue(intentKindOf(v) == B4VaultStorage.IntentKind.ReturnUsdc, "the leg is still owed");

        hub.deliverEvm();
        keeper.crank(pool, vaults, 1);
        assertTrue(
            intentKindOf(v) == B4VaultStorage.IntentKind.None,
            "the delivered leg completes for an honest keeper too"
        );
    }
}
