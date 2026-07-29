// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {B4VaultStorage} from "src/core/B4VaultStorage.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {Phi} from "src/libraries/Phi.sol";

/// @notice Regression for AUDIT-2026-07-25 H-3 — the two ledger-WRITING consumers of
///         `_livePxWad()` had no zero-price guard, unlike the order-emission and pool
///         consumers, which all reject a zero read.
///
/// H-3 became load-bearing when C-1 moved settlement onto the live price: `lockPrices`
/// used to be the thing refusing a poisoned zero, and it no longer feeds the valuation.
contract AuditH3_ZeroPriceTest is VaultTestBase {
    function setUp() public {
        setUpProtocol();
    }

    function _p1() internal pure returns (uint256) {
        return GENESIS_TS + Calendar.P - Calendar.H;
    }

    // ------------------------------------------------------------------------ deposit

    /// A zero read would book principal at basis 0, and the next checkpoint would then
    /// charge a performance fee on the entire NAV and mint the matching pool weight — paid
    /// out of the depositor's own capital.
    function test_H3_directional_deposit_reverts_on_zero_price() public {
        B4Vault v = createVault(address(mini));
        ubtc.mint(user, 1e8);
        hub.setSpotPx(SPOT_MKT, 0);
        vm.startPrank(user);
        ubtc.approve(address(v), 1e8);
        vm.expectRevert(B4VaultStorage.ZeroPrice.selector);
        v.deposit(1e8, 0);
        vm.stopPrank();
    }

    /// The guard must NOT be hoisted out of the directional branch: USDC is fixed at 1 USD
    /// (C3), so a USDC top-up is price-independent — and a feed outage is exactly when an
    /// owner needs to add margin to a leveraged position.
    function test_H3_usdc_deposit_still_works_during_a_feed_outage() public {
        B4Vault v = createVault(address(mini));
        usdc.mint(user, 50_000e6);
        hub.setSpotPx(SPOT_MKT, 0);
        vm.startPrank(user);
        usdc.approve(address(v), 50_000e6);
        v.deposit(0, 50_000e6);
        vm.stopPrank();
        assertEq(v.entryLedgerWad(), 50_000e18, "booked at a fixed 1 USD, no price needed");
    }

    /// A settle during an outage must defer, not value the whole vault at zero.
    function test_H3_settle_reverts_on_zero_price() public {
        B4Vault v = createVault(address(mini));
        fundAndDeposit(v, 1e8, 0);
        crankUntilIdle(v, 20);
        vm.warp(_p1());
        pool.advance();
        uint256 id = pool.intervalCount() - 1;
        pool.lockPrices(id);

        hub.setSpotPx(SPOT_MKT, 0);
        vm.expectRevert(B4VaultStorage.ZeroPrice.selector);
        v.settle(id);

        // Recovers by itself once the feed returns — deferral, not destruction.
        hub.setSpotPx(SPOT_MKT, 100_000 * 1e4);
        v.settle(id);
        assertEq(v.lastSettledPlusOne(), id + 1);
    }

    // --------------------------------------------------------------------------- exit

    /// The exit must DEFER (no progress), not consume the share while paying nothing, and
    /// not revert — `_planExitStep` runs under the permissionless crank.
    function test_H3_exit_defers_on_zero_price_then_completes() public {
        B4Vault v = createVault(address(mini));
        fundAndDeposit(v, 1e8, 0);
        crankUntilIdle(v, 20);

        vm.prank(user);
        v.initiateExit(Phi.WAD);

        hub.setSpotPx(SPOT_MKT, 0);
        assertFalse(v.crank(), "no progress reported while the feed is dead");
        assertEq(v.exitShareWad(), Phi.WAD, "the exit share survives");
        assertGt(v.entryLedgerWad(), 0, "and the ledger is NOT scaled away");

        hub.setSpotPx(SPOT_MKT, 100_000 * 1e4);
        crankUntilIdle(v, 20);
        assertEq(v.exitShareWad(), 0, "completes once the feed returns");
        assertGt(ubtc.balanceOf(user), 0, "and actually pays");
    }

    /// Deferral only where the price matters: a vault holding no directional asset is
    /// valued exactly at px 0 and must still be able to exit during an outage.
    function test_H3_usdc_only_exit_unaffected_by_zero_price() public {
        B4Vault v = createVault(address(mini));
        usdc.mint(user, 50_000e6);
        vm.startPrank(user);
        usdc.approve(address(v), 50_000e6);
        v.deposit(0, 50_000e6);
        v.initiateExit(Phi.WAD);
        vm.stopPrank();

        hub.setSpotPx(SPOT_MKT, 0);
        crankUntilIdle(v, 20);
        assertEq(v.exitShareWad(), 0, "no directional asset means no price needed");
        assertEq(usdc.balanceOf(user), 50_000e6, "paid in full");
    }

    /// Without an escape, a permanently dead feed would leave the vault stuck in
    /// ExitPending forever: that state gates deposit, settle, selectPolicy, initiateExit
    /// and both recovery paths, and there is no admin and no pause.
    function test_H3_cancelExit_escapes_a_permanently_dead_feed() public {
        B4Vault v = createVault(address(mini));
        fundAndDeposit(v, 1e8, 0);
        crankUntilIdle(v, 20);

        vm.prank(user);
        v.initiateExit(Phi.WAD);
        hub.setSpotPx(SPOT_MKT, 0);
        assertFalse(v.crank());

        // Stuck: every owner action is gated by the pending exit.
        usdc.mint(user, 1e6);
        vm.startPrank(user);
        usdc.approve(address(v), 1e6);
        vm.expectRevert(B4VaultStorage.ExitPending.selector);
        v.deposit(0, 1e6);

        v.cancelExit();
        v.deposit(0, 1e6); // unstuck
        vm.stopPrank();
        assertEq(v.exitShareWad(), 0);

        // Cancelling moved no funds — the vault still holds its position.
        assertEq(v.dirEvm(), 1e8);
    }

    function test_H3_cancelExit_requires_a_pending_exit() public {
        B4Vault v = createVault(address(mini));
        vm.prank(user);
        vm.expectRevert(B4VaultStorage.NoExitPending.selector);
        v.cancelExit();
    }

    function test_H3_cancelExit_is_owner_only() public {
        B4Vault v = createVault(address(mini));
        fundAndDeposit(v, 1e8, 0);
        vm.prank(user);
        v.initiateExit(Phi.WAD);
        vm.expectRevert(B4VaultStorage.OnlyOwner.selector);
        v.cancelExit();
    }
}
