// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {B4Pool} from "src/core/B4Pool.sol";
import {B4ProductFactory} from "src/core/B4ProductFactory.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {B4VaultStorage} from "src/core/B4VaultStorage.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {Phi} from "src/libraries/Phi.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";

/// @notice AUDIT-2026-07-25 L-1 + INVARIANTS rows 20/21: a pool-OWNED sleeve is
///         initialized with `owner == pool`, so the B4Pool is the only address that can
///         ever satisfy the vault's `onlyOwner`. Before the pool exposed forwarders, the
///         documented dead-feed escape (`cancelExit`) and the whole HAZARDS-B6 surplus
///         recovery family were structurally uncallable for every sleeve.
contract AuditL1SleeveEscapesTest is VaultTestBase {
    B4ProductFactory productFactory;
    address[4] strategies;

    uint256 constant DIR = 1;

    function setUp() public {
        setUpProtocol();
        productFactory = new B4ProductFactory(
            address(oracle),
            usdcDescriptor(),
            factory.vaultImplementation(),
            address(poolDeployer)
        );
        strategies = [address(mini), address(b4), address(pro), address(proMax)];
    }

    function _productPool(uint8 mask) internal returns (B4Pool p) {
        CoreTypes.AssetDescriptor[] memory dirs = new CoreTypes.AssetDescriptor[](1);
        dirs[0] = ubtcDescriptor();
        p = B4Pool(productFactory.createProductPool(dirs, strategies, mask));
    }

    function _createProductVault(B4Pool p, address strategy) internal returns (B4Vault v) {
        vm.prank(user);
        v = B4Vault(
            productFactory.createVault(
                address(p),
                CoreTypes.descriptorHash(ubtcDescriptor()),
                strategy,
                Phi.WAD,
                100,
                B4VaultStorage.FeeRoute(address(0), 0, address(0), 0)
            )
        );
    }

    function _deposit(B4Vault v, uint256 dirAmount, uint256 usdcAmount) internal {
        if (dirAmount != 0) ubtc.mint(user, dirAmount);
        if (usdcAmount != 0) usdc.mint(user, usdcAmount);
        vm.startPrank(user);
        if (dirAmount != 0) ubtc.approve(address(v), dirAmount);
        if (usdcAmount != 0) usdc.approve(address(v), usdcAmount);
        v.deposit(dirAmount, usdcAmount);
        vm.stopPrank();
    }

    function _crankSleeve(B4Pool p, uint8 policy) internal {
        for (uint256 i = 0; i < 200; i++) {
            if (!p.crankSleeve(policy, DIR)) break;
        }
    }

    /// @dev Drive a Mini penalty into the Mini sleeve so it holds real directional value.
    function _fundedMiniSleeve() internal returns (B4Pool p, B4Vault sleeve) {
        p = _productPool(1);
        B4Vault v = _createProductVault(p, address(mini));

        warpTo(30 days); // Growth zone: a non-free exit, so the exit pays a penalty
        _deposit(v, 1e8, 0);
        crankUntilIdle(v, 60);

        vm.prank(user);
        v.initiateExit(Phi.WAD);
        crankUntilIdle(v, 120);
        assertGt(p.penaltyEscrow(1, DIR, DIR), 0, "Mini penalty escrowed");

        assertTrue(p.foldPenalty(1, DIR), "escrow folds into the sleeve");
        _crankSleeve(p, 1);
        sleeve = B4Vault(p.sleeveOf(1, DIR));
        assertGt(sleeve.dirEvm() + sleeve.coreDirWei(), 0, "sleeve holds directional value");
    }

    /// @dev A further non-free Mini exit, leaving NEW escrow for the same (policy, dir).
    function _newMiniPenalty(B4Pool p, uint256 amount) internal {
        B4Vault v = _createProductVault(p, address(mini));
        _deposit(v, amount, 0);
        crankUntilIdle(v, 80);
        vm.prank(user);
        v.initiateExit(Phi.WAD);
        crankUntilIdle(v, 160);
    }

    // ------------------------------------------------------ invariant 20: the escape

    /// The harm the escape actually repairs, plus its HONEST BOUND. While the sleeve is
    /// wedged, `foldPenalty` reverts `ExitPending`, so every FUTURE penalty for that
    /// (policy, dir) pair is sterilized. Cancelling clears that — but while the feed is
    /// still dead a DIRECTIONAL fold stays blocked by `B4Vault.deposit`'s own H-3 guard,
    /// so what the escape buys is the sync planner, the settlement-only fold, and
    /// immediate reuse the instant the feed returns. Asserted, not assumed.
    function test_L1_cancel_restores_foldPenalty_only_once_the_feed_returns() public {
        (B4Pool p, B4Vault sleeve) = _fundedMiniSleeve();

        _newMiniPenalty(p, 2e8); // still in the growth zone: a non-free exit
        assertGt(p.penaltyEscrow(1, DIR, DIR), 0, "new escrow waiting to fold");

        warpTo(Calendar.T);
        assertTrue(p.initiateSleeveExit(1, DIR));
        hub.setSpotPx(SPOT_MKT, 0);
        _crankSleeve(p, 1);
        assertEq(sleeve.exitShareWad(), Phi.WAD, "wedged by the dead feed");

        vm.expectRevert(B4VaultStorage.ExitPending.selector);
        p.foldPenalty(1, DIR); // the sterilization

        assertTrue(p.cancelSleeveExit(1, DIR), "the escape exists");
        vm.expectRevert(B4VaultStorage.ZeroPrice.selector);
        p.foldPenalty(1, DIR); // honest bound: the directional leg stays price-gated

        hub.setSpotPx(SPOT_MKT, SPOT_PX);
        assertTrue(p.foldPenalty(1, DIR), "folds again once the feed returns");
        assertEq(p.penaltyEscrow(1, DIR, DIR), 0, "escrow reached the sleeve");
    }

    /// A permanently dead directional feed defers `_finalizeExit` forever. The sleeve's
    /// owner is the pool, so `cancelSleeveExit` IS the escape row 20 promises.
    function test_L1_sleeve_exit_is_cancellable_under_a_dead_feed() public {
        (B4Pool p, B4Vault sleeve) = _fundedMiniSleeve();

        warpTo(Calendar.T); // ClosingFall: a free-exit window
        assertTrue(p.initiateSleeveExit(1, DIR), "free-window sleeve exit begins");

        hub.setSpotPx(SPOT_MKT, 0); // the feed dies and never returns
        _crankSleeve(p, 1);
        assertEq(sleeve.exitShareWad(), Phi.WAD, "the exit cannot finalize at a zero price");

        assertTrue(p.cancelSleeveExit(1, DIR), "the pool-side escape exists");
        assertEq(sleeve.exitShareWad(), 0, "sleeve is out of ExitPending");
        assertGt(sleeve.dirEvm(), 0, "cancelling moved no funds");

        // And the documented outcome is restored once the feed returns.
        hub.setSpotPx(SPOT_MKT, SPOT_PX);
        assertTrue(p.initiateSleeveExit(1, DIR), "re-exitable in the same free window");
        _crankSleeve(p, 1);
        assertEq(sleeve.exitShareWad(), 0, "sleeve fully exits");
        assertGt(p.accruing(DIR), 0, "realised sleeve capital joins claim inventory");
    }

    /// The escape is NOT a control: with a live feed the exit can finalize, so the pool
    /// refuses to cancel. This is what stops a permissionless cancel from becoming an
    /// indefinite grief on sleeve repatriation.
    function test_L1_sleeve_exit_cancel_refused_while_the_feed_is_live() public {
        (B4Pool p, B4Vault sleeve) = _fundedMiniSleeve();

        warpTo(Calendar.T);
        assertTrue(p.initiateSleeveExit(1, DIR));

        vm.expectRevert(B4Pool.NotStuck.selector);
        p.cancelSleeveExit(1, DIR);
        assertEq(sleeve.exitShareWad(), Phi.WAD, "exit untouched");
    }

    /// Exact complement of `_finalizeExit`'s deferral test: a zero price alone is not
    /// enough — a sleeve holding no directional value finalizes at px 0, so cancelling is
    /// refused there too.
    function test_L1_dead_feed_cancel_refused_when_the_sleeve_holds_no_directional()
        public
    {
        B4Pool p = _productPool(15);
        B4Vault sleeve = B4Vault(p.sleeveOf(2, DIR)); // never funded

        warpTo(Calendar.T);
        assertTrue(p.initiateSleeveExit(2, DIR));
        hub.setSpotPx(SPOT_MKT, 0);

        vm.expectRevert(B4Pool.NotStuck.selector);
        p.cancelSleeveExit(2, DIR);

        _crankSleeve(p, 2);
        assertEq(sleeve.exitShareWad(), 0, "a price-independent exit still finalizes");
    }

    // --------------------------------------------- invariant 21 / HAZARDS B6 for sleeves

    /// Unaccounted EVM surplus (donations, A11 favourable overfill) becomes ordinary
    /// claim inventory — never a caller-chosen payout.
    function test_L1_sleeve_evm_surplus_becomes_claim_inventory() public {
        B4Pool p = _productPool(1);
        address sleeve = p.sleeveOf(1, DIR);

        ubtc.mint(sleeve, 5e7);
        usdc.mint(sleeve, 250e6);

        p.recoverSleeveEvm(1, DIR, DIR);
        p.recoverSleeveEvm(1, DIR, 0);

        assertEq(ubtc.balanceOf(sleeve), 0, "sleeve drained of directional surplus");
        assertEq(usdc.balanceOf(sleeve), 0, "sleeve drained of settlement surplus");
        assertEq(ubtc.balanceOf(address(p)), 5e7, "value landed at the pool");
        assertEq(usdc.balanceOf(address(p)), 250e6);
        assertEq(p.accruing(DIR), 5e7, "and became claim inventory");
        assertEq(p.accruing(0), 250e6);
        assertEq(p.liability(address(ubtc)), 5e7, "liability grew only by measured receipt");
        assertEq(p.liability(address(usdc)), 250e6);
    }

    /// Core-spot surplus above recorded principal: the two-leg async path ends at the
    /// pool because the sleeve's immutable `owner` IS the pool.
    function test_L1_sleeve_core_spot_surplus_becomes_claim_inventory() public {
        B4Pool p = _productPool(1);
        address sleeve = p.sleeveOf(1, DIR);

        hub.coreTopUp(sleeve, USDC_CORE, 50e8);
        p.recoverSleeveCoreSpot(1, DIR, false);
        _crankSleeve(p, 1);

        assertEq(usdc.balanceOf(address(p)), 50e6);
        assertEq(p.accruing(0), 50e6);
        assertEq(p.liability(address(usdc)), 50e6);
    }

    /// Perp funding surplus — decision C1's untaxed surplus, which for a pool-owned
    /// sleeve belongs to pool claimants.
    function test_L1_sleeve_perp_surplus_becomes_claim_inventory() public {
        B4Pool p = _productPool(1);
        address sleeve = p.sleeveOf(1, DIR);

        hub.setUserExists(sleeve, true);
        hub.setWithdrawable(sleeve, 200e6);

        p.recoverSleevePerpSurplus(1, DIR);
        _crankSleeve(p, 1);

        assertEq(usdc.balanceOf(address(p)), 200e6);
        assertEq(p.accruing(0), 200e6);
        assertEq(B4Vault(sleeve).perpMargin6(), 0, "books untouched: no callback (B6)");
    }

    /// The A6 escape is mandatory alongside the recovery forwarders: a recovery intent
    /// the venue never completes would otherwise block every later `crankSleeve` and
    /// strand the sleeve's principal forever.
    function test_L1_clearSleeveRecovery_unsticks_a_dropped_recovery_leg() public {
        B4Pool p = _productPool(1);
        address sleeve = p.sleeveOf(1, DIR);

        hub.setUserExists(sleeve, true);
        hub.setAuto(false, true, true);
        hub.setWithdrawable(sleeve, 200e6);
        hub.setDropNext(1);

        p.recoverSleevePerpSurplus(1, DIR);
        hub.executeActions(); // dropped: nothing moves
        _crankSleeve(p, 1);
        assertEq(
            uint8(intentKindOf(B4Vault(sleeve))),
            uint8(B4VaultStorage.IntentKind.RecoverPerpPhase1),
            "sleeve is wedged on the dropped leg"
        );

        vm.expectRevert(B4VaultStorage.TooEarly.selector);
        p.clearSleeveRecovery(1, DIR);

        vm.warp(block.timestamp + 3 days);
        p.clearSleeveRecovery(1, DIR);
        assertEq(uint8(intentKindOf(B4Vault(sleeve))), uint8(B4VaultStorage.IntentKind.None));

        hub.setAuto(true, true, true);
        p.recoverSleevePerpSurplus(1, DIR);
        _crankSleeve(p, 1);
        assertEq(p.accruing(0), 200e6, "re-recoverable end to end");
    }

    // ------------------------------------------------------------- no new discretion

    /// A caller may only name a registered sleeve out of the immutable `sleeveOf` table
    /// and a token by whitelist index — never an address, an amount or a recipient.
    function test_L1_sleeve_escape_forwarders_admit_no_caller_discretion() public {
        B4Pool p = _productPool(1); // mask 1: only the Mini sleeve exists

        vm.expectRevert(B4Pool.NotASleeve.selector);
        p.recoverSleevePerpSurplus(2, DIR);
        vm.expectRevert(B4Pool.NotASleeve.selector);
        p.recoverSleeveCoreSpot(1, 2, false);
        vm.expectRevert(B4Pool.NotASleeve.selector);
        p.clearSleeveRecovery(4, DIR);
        vm.expectRevert(B4Pool.NotASleeve.selector);
        p.cancelSleeveExit(1, 7);

        // Token choice is an index into the immutable descriptor whitelist.
        vm.expectRevert(B4Pool.BadAsset.selector);
        p.recoverSleeveEvm(1, DIR, 2);

        // Nothing to escape from: a no-op, not a revert.
        assertFalse(p.cancelSleeveExit(1, DIR), "no exit pending");
        vm.expectRevert(B4VaultStorage.NothingToRecover.selector);
        p.recoverSleeveEvm(1, DIR, 0);
        vm.expectRevert(B4VaultStorage.NotRecoveryIntent.selector);
        p.clearSleeveRecovery(1, DIR);
    }
}
