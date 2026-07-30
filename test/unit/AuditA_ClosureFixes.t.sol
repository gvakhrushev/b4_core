// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {B4VaultStorage} from "src/core/B4VaultStorage.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";
import {Phi} from "src/libraries/Phi.sol";

/// @notice Regression suite for the pre-mainnet closure fixes A1–A4. Each test is
///         fail-before / pass-after against the tree it ships with (H1).
contract AuditAClosureFixesTest is VaultTestBase {
    function setUp() public {
        setUpProtocol();
    }

    function readSzi(address who) internal view returns (int64) {
        (bool ok, bytes memory ret) =
            CoreTypes.PRECOMPILE_POSITION.staticcall(abi.encode(who, uint16(PERP_MKT)));
        require(ok, "read");
        return abi.decode(ret, (CoreTypes.Position)).szi;
    }

    // ============================================================= A1
    /// A deposit landing AFTER a settlement snapshot but before `settle` must not be dropped
    /// from the re-anchored entry basis, or the depositor's own principal reappears as phantom
    /// profit next checkpoint and mints pool weight (weight integrity, INVARIANTS #19).
    /// Fail-before: `settle` re-anchored from the frozen pre-deposit NAV, leaving entry at 100k
    /// and minting weight on the dropped 100k at the next checkpoint.
    function test_A1_deposit_after_snapshot_kept_in_basis() public {
        B4Vault v = createVault(address(mini));
        hub.setSpotPx(SPOT_MKT, SPOT_PX); // 100k, flat
        fundAndDeposit(v, 1e8, 0); // deposit #1: 1 BTC ⇒ E = 100k

        warpTo(Calendar.P - Calendar.H);
        pool.advance();
        uint256 id = pool.intervalCount() - 1;
        pool.lockPrices(id);
        v.snapshotNav(id); // freeze settle NAV at the pre-deposit 100k

        fundAndDeposit(v, 1e8, 0); // deposit #2 AFTER the snapshot ⇒ 2 BTC, E = 200k
        v.settle(id);

        assertEq(v.entryLedgerWad(), 200_000e18, "basis keeps BOTH deposits");
        assertEq(pool.weightOf(id, address(v)), 0, "no phantom weight this interval");
        assertEq(v.rewardBaseWad(), 0);

        // Next checkpoint, price unchanged: the deposited principal must never tax as profit.
        warpTo(Calendar.T + Calendar.H);
        pool.advance();
        uint256 id2 = pool.intervalCount() - 1;
        pool.lockPrices(id2);
        v.settle(id2);
        assertEq(pool.weightOf(id2, address(v)), 0, "no phantom profit next checkpoint");
        assertEq(v.rewardBaseWad(), 0);
    }

    // ============================================================= A2
    /// A spot bucket booked ABOVE the real Core balance (cross-margin liquidation reaching
    /// spot, or a partial spotSend) must be written down, or the Return leg for the phantom
    /// remainder livelocks the exit (audit M-1, 2nd clause).
    /// Fail-before: `exitShareWad` never clears — the phantom bucket is retried forever.
    function test_A2_spot_writedown_prevents_exit_livelock() public {
        B4Vault v = createVault(address(pro));
        fundAndDeposit(v, 1e8, 10_000e6);
        warpTo(Calendar.P);
        crankUntilIdle(v, 40); // fall: short opens, margin on the perp
        assertLt(readSzi(address(v)), 0);

        warpTo(Calendar.T); // ClosingFall: free-exit window
        vm.prank(user);
        v.initiateExit(1e18);

        // Crank until the perp margin is pulled back onto Core spot USDC.
        for (uint256 i = 0; i < 15 && v.coreUsdcMarginWei() == 0; i++) {
            v.crank();
        }
        uint64 booked = v.coreUsdcMarginWei();
        assertGt(uint256(booked), 0, "precondition: USDC margin on Core spot");
        assertEq(readSzi(address(v)), 0, "flat");

        // Real Core USDC balance drops below books.
        hub.coreDrawdown(address(v), USDC_CORE, booked / 2);

        crankUntilIdle(v, 40);
        assertEq(v.exitShareWad(), 0, "exit finalized - no M-1 livelock");
    }

    // ============================================================= A3
    /// With a dead perp mark feed and a still-open wrong-sign perp, the sync planner cannot
    /// flatten, so `crank()` must report NO progress (A13 / audit L-6) instead of spinning.
    /// Fail-before: `_startPerpOrder` was void and the caller returned `true` unconditionally.
    function test_A3_dead_mark_reports_no_progress() public {
        B4Vault v = createVault(address(pro));
        fundAndDeposit(v, 1e8, 10_000e6);
        warpTo(Calendar.P);
        crankUntilIdle(v, 40); // short open
        assertLt(readSzi(address(v)), 0);

        // Terminal growth: Pro target = +1 ⇒ perp component 0, so sync WANTS to flatten.
        warpTo(Calendar.T + Calendar.W + 1);
        hub.setMarkPx(PERP_MKT, 0); // kill the mark feed

        assertTrue(intentKindOf(v) == B4VaultStorage.IntentKind.None);
        bool progressed = v.crank();
        assertEq(progressed, false, "no false progress on a dead mark feed");
        assertLt(readSzi(address(v)), 0, "position held, not flattened");
        assertTrue(intentKindOf(v) == B4VaultStorage.IntentKind.None, "no intent emitted");
    }

    // ============================================================= A4
    /// Re-selecting a policy while a leg is in flight must revert: the in-flight leg was
    /// planned against the old target. Fail-before: `opsSelectPolicy` had no idle gate.
    function test_A4_selectPolicy_rejects_inflight() public {
        hub.setAuto(false, false, false); // emitted actions stay pending ⇒ engine non-idle
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 1e8, 20_000e6);
        v.crank(); // creates an in-flight intent that does not auto-execute
        assertTrue(intentKindOf(v) != B4VaultStorage.IntentKind.None, "intent pending");

        vm.prank(user);
        vm.expectRevert(B4VaultStorage.IntentPending.selector);
        v.selectPolicy(address(proMax), 1e18);
    }
}
