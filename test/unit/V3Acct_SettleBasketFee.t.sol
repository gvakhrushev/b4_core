// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {B4VaultStorage} from "src/core/B4VaultStorage.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {Phi} from "src/libraries/Phi.sol";

/// @notice V3-ACCT: settle pays the operator cut in kind from the EVM basket ONLY,
///         capped by that basket (B4VaultOps._payOperatorInKind), while NAV — and the
///         entry re-anchor — include the Core buckets. Settle requires an IDLE engine,
///         but idle != repatriated: a vault can sit idle with its whole value on Core
///         (mid-rotation, or simply never cranked to completion). Calling settle in that
///         state caps the in-kind payment at the (empty) EVM basket, permanently waiving
///         the operator/referrer cut — the entry ledger re-anchors to nav − 0, so the
///         waived fee is never re-charged — while the FULL client share is still reported
///         as pool weight. Permissionless settle timing makes this owner-triggerable at
///         every checkpoint.
contract V3AcctSettleBasketFeeTest is VaultTestBase {
    function setUp() public {
        setUpProtocol();
    }

    function p1() internal pure returns (uint256) {
        return Calendar.P - Calendar.H;
    }

    /// PASS-AFTER (V3-ACCT-1 fix): settling while the vault is idle but holds ALL value on
    /// Core (empty EVM basket) now REVERTS FeeNotRepatriated — the operator cut can't be
    /// paid in kind, so the fee/weight can't be finalized. After repatriation the same
    /// interval settles and pays the full cut.
    function test_V3ACCT_settle_with_empty_evm_basket_reverts() public {
        B4Vault v = createVault(address(b4));
        fundAndDeposit(v, 1e8, 0); // E = 100,000 at $100k
        hub.setSpotPx(SPOT_MKT, 120_000e4); // +20% ⇒ profit = 20,000

        warpTo(p1()); // the crossing: B4 target 0 ⇒ rotation wants to sell everything
        pool.advance();
        pool.lockPrices(0);

        // Two cranks: FundDir then verify — idle but the whole $120k is on Core; basket = 0.
        v.crank();
        v.crank();
        assertEq(v.dirEvm(), 0);
        assertEq(v.coreDirWei(), 1e8);
        assertEq(uint8(intentKindOf(v)), uint8(B4VaultStorage.IntentKind.None)); // idle

        // The fee dodge is blocked: settle reverts because the EVM basket can't cover the cut.
        vm.expectRevert(B4VaultStorage.FeeNotRepatriated.selector);
        v.settle(0);

        // Crank to repatriation (steady-state custody is EVM), then settle pays in full.
        crankUntilIdle(v, 20);
        assertGt(v.usdcRotatedEvm(), 119_000e6);
        v.settle(0);

        uint256 vf = Phi.wmul(20_000e18, Phi.FEE_F);
        uint256 oc = Phi.bps(vf, 3000);
        uint256 clientShare = vf - oc;
        uint256 expected = Phi.mulDiv(v.usdcRotatedEvm() + oc, oc, 120_000e18); // ≈ oc in USDC
        expected;
        // Operator/referrer are paid; weight reported; entry net of the paid cut.
        assertGt(usdc.balanceOf(operator) + usdc.balanceOf(referrer), 0);
        assertEq(pool.weightOf(0, address(v)), clientShare);
        assertLt(v.entryLedgerWad(), 120_000e18); // entry = nav − paid, not full nav
    }

    /// Contrast: the SAME interval settled AFTER repatriation pays the cut in full.
    /// Identical vault economics — only the settle timing differs.
    function test_V3ACCT_settle_after_repatriation_pays_full_fee() public {
        B4Vault v = createVault(address(b4));
        fundAndDeposit(v, 1e8, 0);
        hub.setSpotPx(SPOT_MKT, 120_000e4);

        warpTo(p1());
        pool.advance();
        pool.lockPrices(0);

        crankUntilIdle(v, 20); // full rotation first: everything back on EVM
        assertEq(v.coreDirWei(), 0);
        assertGt(v.usdcRotatedEvm(), 119_000e6);

        v.settle(0);

        uint256 vf = Phi.wmul(20_000e18, Phi.FEE_F);
        uint256 oc = Phi.bps(vf, 3000);
        // Full cut paid in kind (all-USDC basket): rotPay = oc expressed in 1e6 USDC.
        uint256 expected = Phi.mulDiv(120_000e6, oc, 120_000e18);
        assertEq(usdc.balanceOf(operator) + usdc.balanceOf(referrer), expected);
        assertGt(expected, 0);
        assertEq(usdc.balanceOf(referrer), Phi.bps(expected, 4000));
        // And entry re-anchored to nav − oc here (not nav − 0).
        assertEq(v.entryLedgerWad(), 120_000e18 - oc);
    }

    /// PASS-AFTER: the owner cannot dodge by simply stopping the crank Core-heavy — the
    /// settle guard reverts until the ledger is repatriated.
    function test_V3ACCT_settle_idle_after_first_fund_reverts() public {
        B4Vault v = createVault(address(b4));
        fundAndDeposit(v, 1e8, 0);
        hub.setSpotPx(SPOT_MKT, 120_000e4);

        warpTo(p1());
        pool.advance();
        pool.lockPrices(0);

        v.crank(); // FundDir
        v.crank(); // verify — now idle, Core-heavy
        vm.expectRevert(B4VaultStorage.FeeNotRepatriated.selector);
        v.settle(0);
    }
}
