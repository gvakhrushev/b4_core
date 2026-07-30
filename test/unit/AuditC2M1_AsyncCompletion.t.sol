// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {EngineHarness} from "../utils/EngineHarness.sol";
import {B4VaultStorage} from "src/core/B4VaultStorage.sol";
import {Calendar} from "src/libraries/Calendar.sol";

/// @notice Regressions for AUDIT-2026-07-25 C-2 and M-1 — two async-engine completion bugs
///         that HAZARDS A2/A3/A12 exist to prevent.
contract AuditC2M1_AsyncCompletionTest is VaultTestBase {
    EngineHarness h;

    function setUp() public {
        setUpProtocol();
        h = new EngineHarness();
        h.setup(ubtcDescriptor(), usdcDescriptor(), address(oracle));
        hub.setUserExists(address(h), true);
        hub.setAuto(false, true, true); // manual execution: the IOC stays live
    }

    function kind() internal view returns (B4VaultStorage.IntentKind) {
        return h.intentKind();
    }

    // ------------------------------------------------------------------------- C-2

    /// A2: completion must key on a self-caused DECREASE of the input. An INCREASE of the
    /// output proves nothing — anyone may transfer into a Core spot balance. Gating on it
    /// let a 1-wei donation clear a still-live IOC before its timeout, with zero
    /// accounting, so the order's later fill was never accounted at all.
    function test_C2_out_token_donation_cannot_clear_a_live_spot_order() public {
        h.setBuckets(0, 0, 0, 0, 100_000e8, 0, 0); // USDC on Core spot
        h.startSpotOrder(true, 60_000e8); // buy BTC; queued, NOT executed
        assertEq(uint8(kind()), uint8(B4VaultStorage.IntentKind.SpotOrder));

        // A stranger donates 1 wei of the OUT token while the order is still live.
        hub.coreTopUp(address(h), UBTC_CORE, 1);

        assertFalse(h.verify(), "a donation is not a completion");
        assertEq(
            uint8(kind()),
            uint8(B4VaultStorage.IntentKind.SpotOrder),
            "the live IOC must survive its own donation"
        );

        // Nothing was accounted from the donation either.
        assertEq(h.coreDirWei(), 0, "a donation is never credited");
        // (Accounting of a genuine fill from the measured input debit is covered by
        // `test_spotOrder_partialFill_measured` / `test_spotOrder_favorable_overfill_*`.)
    }

    /// The no-fill path must still clear after the timeout, or an unfilled IOC would wedge
    /// the vault. Clearing is safe here precisely because `inDelta == 0` implies
    /// `curIn >= snapSrcWei`: books are never above assets.
    function test_C2_unfilled_order_still_clears_on_timeout() public {
        h.setBuckets(0, 0, 0, 0, 100_000e8, 0, 0);
        h.startSpotOrder(true, 60_000e8);
        hub.coreTopUp(address(h), UBTC_CORE, 1); // donation present, still no fill

        assertFalse(h.verify());
        vm.warp(block.timestamp + 1 hours + 1);
        assertTrue(h.verify(), "timeout clears");
        assertEq(uint8(kind()), uint8(B4VaultStorage.IntentKind.None));
        assertEq(h.coreDirWei(), 0, "the donation was never accounted");
    }

    // ------------------------------------------------------------------------- M-1

    /// A12: a timeout may schedule a resend, never wedge. The `Return` leg's post-timeout
    /// "defensive" re-clamp could set `intent.amount = 0`, and a zero-amount `spotSend` can
    /// never decrease the source — so completion stayed false forever while the resend
    /// branch stayed true forever. The intent never cleared and every idle-gated
    /// entrypoint died with it, permanently, with no admin to unstick it.
    function test_M1_zero_reclamp_clears_instead_of_wedging_forever() public {
        // Ledger claims Core principal that the Core side does not hold: snapSrcWei == 0.
        h.setBuckets(0, 0, 0, 5e8, 0, 0, 0);
        h.startReturn(true, B4VaultStorage.Purpose.Generic, 5e8);
        assertEq(uint8(kind()), uint8(B4VaultStorage.IntentKind.ReturnDir));

        vm.warp(block.timestamp + 1 hours + 1);
        assertTrue(h.verify(), "progress: the leg resolves");
        assertEq(
            uint8(kind()),
            uint8(B4VaultStorage.IntentKind.None),
            "a zero re-clamp must clear, not loop forever"
        );

        // And it stays cleared — the vault is idle again, so settle/exit/recovery live.
        vm.warp(block.timestamp + 10 hours);
        assertFalse(h.verify());
        assertEq(uint8(kind()), uint8(B4VaultStorage.IntentKind.None));
    }
}
