// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {B4VaultStorage} from "src/core/B4VaultStorage.sol";

/// @notice CHARACTERIZATION test for the A12 residual on `_verifySpotOrder`'s
///         `inDelta == 0` clear-on-timeout branch. It asserts what the engine does TODAY,
///         not what it should do — read the whole comment before touching it.
///
///         Both invariant campaigns drain the CoreWriter action queue before every warp
///         (`_venueDrainsBeforeTime`), on the venue-timing assumption stated at the top of
///         `B4VaultEngine` ("the venue drops unexecuted actions long before RESEND_TIMEOUT")
///         and gated on funded proof by `SECURITY_MODEL.md` §5 items 8 and 10. That drain is
///         a deliberate narrowing of the venue model — but it is also the ONLY reason the
///         campaigns are green here: without it, `invariant_books_never_exceed_assets` fails
///         in the majority of seeds with a five-figure USDC phantom. A silently-narrowed
///         model is exactly the blind spot the strict-pool campaign exists to remove, so the
///         narrowed-away state is pinned HERE instead, deterministically.
///
///         What it pins: if an emitted IOC sits unexecuted for longer than RESEND_TIMEOUT
///         (1h) and then executes, `_verifySpotOrder` has already CLEARED the intent on the
///         `inDelta == 0` timeout, so the later fill is never accounted. The in-code claim
///         at that branch — "Books can never exceed assets here" — holds only under the
///         venue-timing assumption; when it is violated the Core-spot INPUT bucket keeps a
///         ledger far above the real balance, and unlike perp margin (healed by `_reconcile`
///         at the next flat valuation, B2) there is NO write-down path for a Core-spot
///         bucket, so the overstatement is PERMANENT: the loop below cranks the engine to a
///         standstill and the phantom is unchanged. Worst case is an over-stated NAV plus
///         the performance fee and pool weight minted against it — not a loss of principal
///         (the received output lands as unaccounted, owner-recoverable surplus, A11).
///
///         THIS TEST IS EXPECTED TO FAIL if the engine ever gains a Core-spot write-down or
///         a receipt/nonce-based spot-order proof. That failure is the point: invert the
///         assertions then, do not delete them.
contract SpotOrderTimeoutResidualTest is VaultTestBase {
    B4Vault v;

    function setUp() public {
        setUpProtocol();
        v = createVault(address(pro));
    }

    function test_a_delayed_ioc_after_the_timeout_clear_is_never_accounted() public {
        // Execution OFF: an emitted CoreWriter action queues instead of taking effect.
        // Credits and deliveries stay on so the vault still reaches its first spot order.
        hub.setAuto(false, true, true);
        fundAndDeposit(v, 1e8, 50_000e6);

        for (uint256 i = 0; i < 12; i++) {
            v.crank();
            if (intentKindOf(v) == B4VaultStorage.IntentKind.SpotOrder) break;
            hub.applyCredits();
        }
        assertTrue(intentKindOf(v) == B4VaultStorage.IntentKind.SpotOrder, "a spot IOC was emitted");
        assertEq(hub.pendingActions(), 1, "and the venue has not executed it");
        uint64 bookedBefore = v.coreUsdcRotatedWei() + v.coreUsdcMarginWei();
        assertEq(hub.spotBal(address(v), USDC_CORE), bookedBefore, "books match assets so far");

        // The action is STILL queued when RESEND_TIMEOUT expires.
        vm.warp(block.timestamp + 2 hours);
        v.crank();
        assertTrue(
            intentKindOf(v) == B4VaultStorage.IntentKind.None,
            "A12: the timeout cleared the order on `inDelta == 0`, with no fill proof"
        );

        // The venue finally gets around to the IOC, which fills against the cleared intent.
        hub.executeActions();

        uint256 realCore = hub.spotBal(address(v), USDC_CORE);
        uint256 booked = uint256(v.coreUsdcRotatedWei()) + v.coreUsdcMarginWei();
        assertGt(booked, realCore, "the Core USDC ledger now exceeds the real Core balance");
        assertEq(v.coreDirWei(), 0, "and the bought directional output was never credited");
        assertGt(hub.spotBal(address(v), UBTC_CORE), 0, "it is unaccounted surplus (A11)");

        // No amount of permissionless liveness heals it: there is no Core-spot write-down.
        for (uint256 i = 0; i < 30; i++) {
            v.crank();
            hub.executeActions();
            hub.applyCredits();
            hub.deliverEvm();
        }
        assertEq(
            uint256(v.coreUsdcRotatedWei()) + v.coreUsdcMarginWei()
                - hub.spotBal(address(v), USDC_CORE),
            booked - realCore,
            "the phantom is permanent, not transient"
        );
    }
}
