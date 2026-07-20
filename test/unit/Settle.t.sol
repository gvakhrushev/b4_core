// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {B4VaultOps} from "src/core/B4VaultOps.sol";
import {B4VaultStorage} from "src/core/B4VaultStorage.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {Phi} from "src/libraries/Phi.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";

/// @notice Settlement: checkpoint NAV, virtual-fee split, weight reporting — including
///         TEST_PLAN §2 regression 8 (B2: reconcile realized loss before valuation).
contract SettleTest is VaultTestBase {
    function setUp() public {
        setUpProtocol();
    }

    function p1() internal pure returns (uint256) {
        return Calendar.P - Calendar.H;
    }

    function _lockAt(uint256 t) internal returns (uint256 id) {
        warpTo(t);
        pool.advance();
        id = pool.intervalCount() - 1;
        pool.lockPrices(id);
    }

    // ------------------------------------------------------------- fee & weight flow

    function test_settle_profit_fee_weight() public {
        B4Vault v = createVault(address(mini));
        fundAndDeposit(v, 1e8, 0); // E = 100,000
        hub.setSpotPx(SPOT_MKT, 120_000e4); // price appreciates
        uint256 id = _lockAt(p1());

        v.settle(id);

        uint256 profit = 20_000e18;
        uint256 vf = Phi.wmul(profit, Phi.FEE_F);
        uint256 oc = Phi.bps(vf, 3000);
        uint256 clientShare = vf - oc;
        // Weight = priorRewardBase (0) + clientShare, reported once.
        assertEq(pool.weightOf(id, address(v)), clientShare);
        assertEq(v.rewardBaseWad(), clientShare);
        // Operator cut paid in kind from the EVM basket (all-BTC basket here),
        // referral carved from the operator payment: 40% / 60%.
        uint256 ocBtc = Phi.mulDiv(1e8, oc, 120_000e18); // bucket·pay/basket
        uint256 refBtc = Phi.bps(ocBtc, 4000);
        assertEq(ubtc.balanceOf(referrer), refBtc);
        assertEq(ubtc.balanceOf(operator), ocBtc - refBtc);
        // Next-interval entry = checkpoint NAV − value physically paid.
        assertEq(v.entryLedgerWad(), 120_000e18 - oc);
        assertEq(v.dirEvm(), 1e8 - ocBtc);
    }

    function test_settle_no_profit_no_fee_no_weight() public {
        B4Vault v = createVault(address(mini));
        fundAndDeposit(v, 1e8, 0);
        hub.setSpotPx(SPOT_MKT, 90_000e4); // drawdown
        uint256 id = _lockAt(p1());
        v.settle(id);
        assertEq(pool.weightOf(id, address(v)), 0); // R == 0 ⇒ no report
        assertEq(ubtc.balanceOf(operator), 0);
        assertEq(v.entryLedgerWad(), 90_000e18); // entry re-anchors to checkpoint NAV
    }

    function test_settle_uses_checkpoint_price_not_live() public {
        B4Vault v = createVault(address(mini));
        fundAndDeposit(v, 1e8, 0);
        hub.setSpotPx(SPOT_MKT, 120_000e4);
        uint256 id = _lockAt(p1()); // locked at 120k
        hub.setSpotPx(SPOT_MKT, 300_000e4); // live price runs away AFTER the lock
        v.settle(id);
        // Snapshot-protected: profit measured at 120k, not 300k.
        uint256 clientShare =
            Phi.wmul(20_000e18, Phi.FEE_F) - Phi.bps(Phi.wmul(20_000e18, Phi.FEE_F), 3000);
        assertEq(pool.weightOf(id, address(v)), clientShare);
    }

    function test_settle_gates() public {
        B4Vault v = createVault(address(mini));
        fundAndDeposit(v, 1e8, 0);

        // Not materialized / not locked.
        warpTo(p1());
        pool.advance();
        vm.expectRevert(B4VaultStorage.NotSettleable.selector);
        v.settle(0);

        pool.lockPrices(0);
        v.settle(0);
        // One settle per interval.
        vm.expectRevert(B4VaultStorage.AlreadySettled.selector);
        v.settle(0);

        // Report window expiry.
        B4Vault v2 = createVault(address(mini));
        warpTo(p1() + Calendar.SNAPSHOT_WINDOW + Calendar.REPORT_WINDOW + 1);
        vm.expectRevert(B4VaultStorage.NotSettleable.selector);
        v2.settle(0);
    }

    /// SPEC §8: settlement rejects a still-wrong-sign perp for the interval; once sync
    /// has passed it through zero, settlement proceeds.
    function test_settle_rejects_wrong_sign_perp_then_accepts() public {
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 1e8, 20_000e6);
        crankUntilIdle(v, 30); // growth long open
        uint256 id = _lockAt(p1()); // at the crossing the perp target is exactly 0

        vm.expectRevert(B4VaultStorage.WrongSignPerp.selector);
        v.settle(id);

        // Sync drives the long through the verified zero…
        crankUntilIdle(v, 40);
        assertEq(readSzi(address(v)), 0);
        // …after which the interval settles (still inside the report window).
        v.settle(id);
        assertEq(v.lastSettledPlusOne(), id + 1);
    }

    // ------------------------------------------------------------- regression 8 (B2)

    /// Settle over an unreconciled Core loss MUST NOT over-report weight/fee:
    /// reconciliation happens before valuation. The reported weight equals the
    /// written-down computation exactly (the fail-before build reported more).
    function test_R8_settle_reconciles_realized_loss_before_valuation() public {
        B4Vault v = createVault(address(pro));
        fundAndDeposit(v, 1e8, 10_000e6);
        // Fall regime: Pro opens a short with allocated margin.
        warpTo(Calendar.P);
        crankUntilIdle(v, 40);
        assertLt(readSzi(address(v)), 0);
        uint64 marginBefore = v.perpMargin6();
        assertGt(uint256(marginBefore), 0);

        // The vault is idle with the short open and margin recorded. Simulate an EXTERNAL
        // liquidation to raw zero plus a realized loss (withdrawable below recorded
        // principal) — the vault stays idle, so settle's own _reconcile must catch it.
        uint64 recorded = v.perpMargin6();
        uint64 actual = recorded / 2;
        hub.setPosition(address(v), PERP_MKT, 0, 0);
        hub.setWithdrawable(address(v), actual);

        warpTo(Calendar.T + Calendar.H);
        pool.advance(); // materializes the long-expired P−H interval…
        pool.advance(); // …then the current T+H one
        uint256 id = pool.intervalCount() - 1;
        pool.lockPrices(id);
        uint256 pxWad = pool.lockedPxWad(id, 1);

        vm.recordLogs();
        v.settle(id);

        // Principal was written down BEFORE valuation…
        assertEq(v.perpMargin6(), actual);
        // …and the weight/entry reflect the written-down NAV exactly. An over-report
        // would show up as entry above this reconstruction.
        uint256 expectedNav = Phi.wmul(Phi.mulDiv(v.dirEvm(), 1e18, 1e8), pxWad)
            + Phi.mulDiv(v.usdcRotatedEvm(), 1e18, 1e6) + Phi.mulDiv(v.usdcMarginEvm(), 1e18, 1e6)
            + Phi.mulDiv(v.coreUsdcRotatedWei(), 1e18, 1e8)
            + Phi.mulDiv(v.coreUsdcMarginWei(), 1e18, 1e8) + Phi.mulDiv(actual, 1e18, 1e6);
        assertEq(v.entryLedgerWad(), expectedNav); // no fee was due ⇒ entry == NAV
        assertEq(pool.weightOf(id, address(v)), 0); // loss ⇒ no profit, no weight
    }

    /// The same discipline on the exit path: an unreconciled flat loss cannot inflate
    /// the exit NAV (B2 in exit).
    function test_R8_exit_reconciles_before_valuation() public {
        B4Vault v = createVault(address(pro));
        fundAndDeposit(v, 1e8, 10_000e6);
        warpTo(Calendar.P);
        crankUntilIdle(v, 40); // short 1/φ open with margin
        assertLt(readSzi(address(v)), 0);

        warpTo(Calendar.T); // ClosingFall: free-exit zone
        vm.prank(user);
        v.initiateExit(1e18);
        // The exit machine flattens the live position first.
        v.crank(); // reduce submitted
        v.crank(); // verified: raw zero
        assertEq(readSzi(address(v)), 0);
        uint64 recorded = v.perpMargin6();
        assertGt(uint256(recorded), 0);

        // Loss surfaces while flat, before the margin-return step.
        hub.setWithdrawable(address(v), recorded / 2);
        v.crank(); // exit planner: harvest none → RECONCILE → margin return create
        // B2: written down BEFORE the valuation/return, never returned at face.
        assertEq(v.perpMargin6(), recorded / 2);

        crankUntilIdle(v, 40);
        assertEq(v.exitShareWad(), 0); // exit completed on the written-down NAV
        assertEq(v.perpMargin6(), 0);
    }

    function readSzi(address who) internal view returns (int64) {
        (bool ok, bytes memory ret) =
            CoreTypes.PRECOMPILE_POSITION.staticcall(abi.encode(who, uint16(PERP_MKT)));
        require(ok, "read");
        CoreTypes.Position memory p = abi.decode(ret, (CoreTypes.Position));
        return p.szi;
    }
}
