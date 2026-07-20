// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {B4VaultStorage} from "src/core/B4VaultStorage.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {Phi} from "src/libraries/Phi.sol";
import {SafeTransfer} from "src/libraries/SafeTransfer.sol";
import {Keeper} from "src/periphery/Keeper.sol";

/// @notice Consistency-sweep fixes (fail-before/pass-after):
///         (a) a payout recipient whose token transfer fails (USDC blacklist — in-model,
///             SECURITY_MODEL §4 excepts settlement USDC) must never freeze settle/exit
///             (H3); the amount defers, stays accounted, and is retryable;
///         (b) settling while an EVM→Core Fund leg is in flight must not re-anchor the
///             entry ledger below the in-flight principal — returning principal must
///             never read as next-interval "profit".
contract DeferredPayoutTest is VaultTestBase {
    function setUp() public {
        setUpProtocol();
    }

    function p1() internal pure returns (uint256) {
        return Calendar.P - Calendar.H;
    }

    // ------------------------------------------------------- (a) deferred payouts

    /// Fail-before: settle reverted on the blacklisted operator, permanently blocking
    /// the interval report. Pass-after: settle succeeds, the fee defers, retry pays.
    function test_settle_with_blacklisted_operator_defers_not_freezes() public {
        B4Vault v = createVault(address(mini));
        fundAndDeposit(v, 1e8, 0);
        hub.setSpotPx(SPOT_MKT, 120_000e4);
        warpTo(p1());
        pool.advance();
        pool.lockPrices(0);

        ubtc.setBlockedTo(operator, true); // issuer blacklists the operator
        v.settle(0); // MUST NOT revert (H3)

        uint256 vf = Phi.wmul(20_000e18, Phi.FEE_F);
        uint256 oc = Phi.bps(vf, 3000);
        uint256 ocBtc = Phi.mulDiv(1e8, oc, 120_000e18);
        uint256 refBtc = Phi.bps(ocBtc, 4000);
        assertEq(ubtc.balanceOf(referrer), refBtc); // referrer unaffected
        assertEq(ubtc.balanceOf(operator), 0); // deferred, not lost
        assertEq(v.deferredPayout(operator, address(ubtc)), ocBtc - refBtc);
        assertEq(pool.weightOf(0, address(v)), vf - oc); // report happened

        // Still blacklisted: retry reverts (stays claimable), nothing lost.
        vm.expectRevert(SafeTransfer.TransferFailed.selector);
        v.claimDeferred(operator, address(ubtc));

        // Unblacklisted: permissionless retry pays exactly the deferred amount.
        ubtc.setBlockedTo(operator, false);
        v.claimDeferred(operator, address(ubtc));
        assertEq(ubtc.balanceOf(operator), ocBtc - refBtc);
        assertEq(v.deferredPayout(operator, address(ubtc)), 0);
    }

    /// Exit liveness under a blacklisted operator — the owner's funds come home.
    function test_exit_with_blacklisted_operator_completes() public {
        warpTo(100 days);
        B4Vault v = createVault(address(mini));
        fundAndDeposit(v, 1e8, 0);
        hub.setSpotPx(SPOT_MKT, 110_000e4);
        ubtc.setBlockedTo(operator, true);

        vm.prank(user);
        v.initiateExit(1e18);
        crankUntilIdle(v, 10);
        assertEq(v.exitShareWad(), 0); // exit finalized despite the blacklist

        uint256 gross = 110_000e18;
        uint256 penalty = Phi.wmul(gross, Phi.EXIT_Q);
        assertEq(ubtc.balanceOf(user), Phi.mulDiv(1e8, gross - penalty, gross));
        assertGt(v.deferredPayout(operator, address(ubtc)), 0);
    }

    /// Deferred amounts are accounted: the owner cannot sweep them as "unaccounted" EVM
    /// surplus.
    function test_deferred_not_recoverable_as_surplus() public {
        B4Vault v = createVault(address(mini));
        fundAndDeposit(v, 1e8, 0);
        hub.setSpotPx(SPOT_MKT, 120_000e4);
        warpTo(p1());
        pool.advance();
        pool.lockPrices(0);
        ubtc.setBlockedTo(operator, true);
        v.settle(0);
        uint256 deferred = v.deferredPayout(operator, address(ubtc));
        assertGt(deferred, 0);

        // balance = accounted bucket + deferred ⇒ nothing recoverable.
        vm.prank(user);
        vm.expectRevert(B4VaultStorage.NothingToRecover.selector);
        v.recoverEvm(address(ubtc));

        // A real donation on top is still recoverable — bounded correctly.
        ubtc.mint(address(v), 5e6);
        vm.prank(user);
        v.recoverEvm(address(ubtc));
        assertEq(ubtc.balanceOf(user), 5e6);
        assertEq(v.deferredPayout(operator, address(ubtc)), deferred); // untouched
    }

    /// The keeper retries deferred payouts as part of its crank (G2).
    function test_keeper_retries_deferred() public {
        B4Vault v = createVault(address(mini));
        fundAndDeposit(v, 1e8, 0);
        hub.setSpotPx(SPOT_MKT, 120_000e4);
        warpTo(p1());
        pool.advance();
        pool.lockPrices(0);
        ubtc.setBlockedTo(operator, true);
        v.settle(0);
        uint256 deferred = v.deferredPayout(operator, address(ubtc));

        Keeper keeper = new Keeper();
        address[] memory vaults = new address[](1);
        vaults[0] = address(v);
        keeper.crank(pool, vaults, 5); // blacklisted: defer stays, crank doesn't revert
        assertEq(v.deferredPayout(operator, address(ubtc)), deferred);

        ubtc.setBlockedTo(operator, false);
        keeper.crank(pool, vaults, 5);
        assertEq(v.deferredPayout(operator, address(ubtc)), 0);
        assertEq(ubtc.balanceOf(operator), deferred);
    }

    // ------------------------------------------------------- (b) settle mid-Fund-flight

    /// Fail-before: settling while 1 BTC was in flight EVM→Core re-anchored E to ≈ 0, so
    /// the landed credit read as next-interval "profit" and was fee'd as such.
    /// Pass-after: settle REQUIRES an idle engine, so it never values a mid-flight
    /// vault; once the credit lands and the machine is idle, NAV is exact and the
    /// returning principal never reads as profit.
    function test_settle_requires_idle_then_no_phantom_profit() public {
        B4Vault v = createVault(address(b4));
        fundAndDeposit(v, 1e8, 0); // E = 100,000 at 100k
        warpTo(p1()); // the crossing: B4 target 0 ⇒ planner starts the rotation
        hub.setAuto(true, false, true); // bridge credit HELD in flight
        v.crank(); // FundDir created: dirEvm → 0, Core not yet credited
        assertEq(v.dirEvm(), 0);
        assertEq(v.coreDirWei(), 0);
        assertEq(uint8(intentKindOf(v)), uint8(B4VaultStorage.IntentKind.FundDir));

        pool.advance();
        pool.lockPrices(0);
        // Settle while a Fund leg is in flight is rejected — no mid-flight valuation.
        vm.expectRevert(B4VaultStorage.IntentPending.selector);
        v.settle(0);

        // Credit lands, machine reaches idle, THEN settle values an exact NAV.
        hub.applyCredits();
        crankUntilIdle(v, 20);
        v.settle(0);
        assertApproxEqAbs(v.entryLedgerWad(), 100_000e18, 1e15); // principal, not profit
        assertEq(pool.weightOf(0, address(v)), 0); // no fee on returning principal
    }
}
