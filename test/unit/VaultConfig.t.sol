// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {B4Pool} from "src/core/B4Pool.sol";
import {B4Factory} from "src/core/B4Factory.sol";
import {B4VaultStorage} from "src/core/B4VaultStorage.sol";
import {Phi} from "src/libraries/Phi.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";
import {IStrategy} from "src/interfaces/IStrategy.sol";
import {MockERC20} from "../mocks/MockCore.sol";

contract EvilStrategy is IStrategy {
    int256 public g;
    int256 public f;

    function set(int256 g_, int256 f_) external {
        g = g_;
        f = f_;
    }

    function targets() external view returns (int256, int256) {
        return (g, f);
    }
}

contract VaultConfigTest is VaultTestBase {
    MockERC20 strayToken;

    function setUp() public {
        setUpProtocol();
        strayToken = new MockERC20("STRAY", 18);
    }

    // ------------------------------------------------------------- factory & init (F3)

    function test_createVault_atomicBinding() public {
        B4Vault v = createVault(address(proMax));
        assertEq(v.owner(), user);
        assertEq(v.pool(), address(pool));
        assertTrue(factory.isVault(address(v)));
        assertTrue(pool.isVault(address(v)));
        assertEq(v.growthTarget(), int256(Phi.PHI));
        assertEq(v.fallTarget(), -int256(Phi.PHI));
        (address op, uint16 opBps, address ref, uint16 refBps) = v.route();
        assertEq(op, operator);
        assertEq(opBps, 3000);
        assertEq(ref, referrer);
        assertEq(refBps, 4000);
    }

    function test_reinit_guarded_oneShot() public {
        B4Vault v = createVault(address(proMax));
        vm.expectRevert(B4VaultStorage.AlreadyInitialized.selector);
        v.initialize(
            address(this),
            address(pool),
            address(oracle),
            ubtcDescriptor(),
            usdcDescriptor(),
            1,
            address(mini),
            1e18,
            100,
            defaultRoute()
        );
    }

    function test_implementation_cannot_be_initialized() public {
        B4Vault impl = B4Vault(factory.vaultImplementation());
        vm.expectRevert(B4VaultStorage.AlreadyInitialized.selector);
        impl.initialize(
            address(this),
            address(pool),
            address(oracle),
            ubtcDescriptor(),
            usdcDescriptor(),
            1,
            address(mini),
            1e18,
            100,
            defaultRoute()
        );
    }

    function test_createVault_rejects_unknownPool_and_descriptor() public {
        vm.expectRevert(B4Factory.NotAPool.selector);
        factory.createVault(address(0xDEAD), bytes32(0), address(mini), 1e18, 100, defaultRoute());
        vm.expectRevert(B4Factory.UnknownDescriptor.selector);
        factory.createVault(
            address(pool), bytes32(uint256(123)), address(mini), 1e18, 100, defaultRoute()
        );
    }

    /// A rogue pool deployed directly (not via the factory) cannot host factory vaults,
    /// and a rogue "vault" cannot report weight to a legitimate pool.
    function test_rogue_pool_and_vault_isolation() public {
        CoreTypes.AssetDescriptor[] memory ds = new CoreTypes.AssetDescriptor[](2);
        ds[0] = usdcDescriptor();
        ds[1] = ubtcDescriptor();
        B4Pool rogue = new B4Pool(address(oracle), ds); // creator = this, not factory
        vm.expectRevert(B4Factory.NotAPool.selector);
        factory.createVault(
            address(rogue),
            CoreTypes.descriptorHash(ubtcDescriptor()),
            address(mini),
            1e18,
            100,
            defaultRoute()
        );
        vm.expectRevert(B4Pool.NotAVault.selector);
        pool.reportWeight(0, 1e18); // this test contract is not a registered vault
    }

    // ------------------------------------------------------------- fee route (SPEC §2)

    function _routeOf(address op, uint16 opBps, address ref, uint16 refBps)
        internal
        pure
        returns (B4VaultStorage.FeeRoute memory)
    {
        return B4VaultStorage.FeeRoute(op, opBps, ref, refBps);
    }

    function _tryRoute(B4VaultStorage.FeeRoute memory r) internal {
        vm.prank(user);
        factory.createVault(
            address(pool), CoreTypes.descriptorHash(ubtcDescriptor()), address(mini), 1e18, 100, r
        );
    }

    function test_route_validation_matrix() public {
        // operator bps over the 38.19% cap
        vm.expectRevert(B4VaultStorage.BadRoute.selector);
        this.tryRouteExt(_routeOf(operator, 3820, address(0), 0));
        // non-zero rate with zero operator
        vm.expectRevert(B4VaultStorage.BadRoute.selector);
        this.tryRouteExt(_routeOf(address(0), 100, address(0), 0));
        // referrer requires non-zero operator rate
        vm.expectRevert(B4VaultStorage.BadRoute.selector);
        this.tryRouteExt(_routeOf(operator, 0, referrer, 4000));
        // referrer share below the protected 38.19% floor
        vm.expectRevert(B4VaultStorage.BadRoute.selector);
        this.tryRouteExt(_routeOf(operator, 3000, referrer, 3818));
        // referrer share above 100%
        vm.expectRevert(B4VaultStorage.BadRoute.selector);
        this.tryRouteExt(_routeOf(operator, 3000, referrer, 10_001));
        // stray referrerBps without referrer
        vm.expectRevert(B4VaultStorage.BadRoute.selector);
        this.tryRouteExt(_routeOf(operator, 3000, address(0), 4000));
        // boundary-valid routes
        this.tryRouteExt(_routeOf(operator, 3819, referrer, 3819));
        this.tryRouteExt(_routeOf(operator, 3819, referrer, 10_000));
        this.tryRouteExt(_routeOf(address(0), 0, address(0), 0)); // no-fee route
    }

    function tryRouteExt(B4VaultStorage.FeeRoute memory r) external {
        _tryRoute(r);
    }

    function test_route_immutable_no_setter_exists() public {
        B4Vault v = createVault(address(mini));
        // No function on the vault can change the route (invariant 15): verified by ABI
        // construction — assert the stored route survives policy/deposit operations.
        vm.prank(user);
        v.selectPolicy(address(proMax), 1e18);
        (address op,,,) = v.route();
        assertEq(op, operator);
    }

    // ------------------------------------------------------------- policy (SPEC §3)

    function test_policy_bounds() public {
        EvilStrategy evil = new EvilStrategy();
        B4Vault v = createVault(address(mini));

        // |resolved| ≤ φ enforced
        evil.set(int256(Phi.PHI) + 1, 0);
        vm.prank(user);
        vm.expectRevert(B4VaultStorage.BadPolicy.selector);
        v.selectPolicy(address(evil), 1e18);

        // |base| ≤ 10 WAD enforced even if scale would bring it back
        evil.set(11e18, 0);
        vm.prank(user);
        vm.expectRevert(B4VaultStorage.BadPolicy.selector);
        v.selectPolicy(address(evil), 1e17);

        // scale bounds: 0 < k ≤ 10
        evil.set(1e17, -1e17);
        vm.prank(user);
        vm.expectRevert(B4VaultStorage.BadPolicy.selector);
        v.selectPolicy(address(evil), 0);
        vm.prank(user);
        vm.expectRevert(B4VaultStorage.BadPolicy.selector);
        v.selectPolicy(address(evil), 10e18 + 1);

        // valid: 0.1·(1, −1) at scale 10 ⇒ (1, −1)
        vm.prank(user);
        v.selectPolicy(address(evil), 10e18);
        assertEq(v.growthTarget(), 1e18);
        assertEq(v.fallTarget(), -1e18);
    }

    /// Strategy read once: mutating the strategy later never changes stored targets.
    function test_strategy_readOnce() public {
        EvilStrategy evil = new EvilStrategy();
        evil.set(1e18, 0);
        B4Vault v = createVault(address(evil));
        assertEq(v.growthTarget(), 1e18);
        evil.set(-int256(Phi.PHI), -int256(Phi.PHI)); // mutate after selection
        assertEq(v.growthTarget(), 1e18); // unchanged
        assertEq(v.fallTarget(), 0);
    }

    /// Invariant 12: product/scale change never invokes exit or penalty logic.
    function test_policyChange_noExit_noPenalty() public {
        B4Vault v = createVault(address(mini));
        fundAndDeposit(v, 1e8, 1_000e6);
        uint256 navBefore = v.navWad();
        vm.prank(user);
        v.selectPolicy(address(proMax), 1e18);
        // Nothing left the vault; entry ledger untouched; no penalty of any kind.
        assertEq(v.navWad(), navBefore);
        assertEq(usdc.balanceOf(address(pool)), 0);
        assertEq(v.exitShareWad(), 0);
    }

    function test_onlyOwner_guards() public {
        B4Vault v = createVault(address(mini));
        vm.expectRevert(B4VaultStorage.OnlyOwner.selector);
        v.selectPolicy(address(proMax), 1e18);
        vm.expectRevert(B4VaultStorage.OnlyOwner.selector);
        v.deposit(1, 0);
        vm.expectRevert(B4VaultStorage.OnlyOwner.selector);
        v.initiateExit(1e18);
        vm.expectRevert(B4VaultStorage.OnlyOwner.selector);
        v.recoverEvm(address(usdc));
        vm.expectRevert(B4VaultStorage.OnlyOwner.selector);
        v.recoverCoreSpot(false);
        vm.expectRevert(B4VaultStorage.OnlyOwner.selector);
        v.recoverPerpSurplus();
        vm.expectRevert(B4VaultStorage.OnlyOwner.selector);
        v.emergencyClearRecovery();
    }

    // ------------------------------------------------------------- deposits

    function test_deposit_measuredDelta_and_entryLedger() public {
        B4Vault v = createVault(address(mini));
        fundAndDeposit(v, 1e8, 1_000e6); // 1 BTC @ 100k + $1000 margin
        assertEq(v.dirEvm(), 1e8);
        assertEq(v.usdcMarginEvm(), 1_000e6);
        assertEq(v.entryLedgerWad(), 101_000e18);
    }

    function test_deposit_windows_closed_in_opening_subwindows() public {
        B4Vault v = createVault(address(mini));
        ubtc.mint(user, 3e8);
        vm.prank(user);
        ubtc.approve(address(v), 3e8);

        warpTo(Calendar.P - Calendar.H); // OpeningFall
        vm.prank(user);
        vm.expectRevert(B4VaultStorage.DepositWindowClosed.selector);
        v.deposit(1e8, 0);

        warpTo(Calendar.T + Calendar.H); // OpeningGrowth
        vm.prank(user);
        vm.expectRevert(B4VaultStorage.DepositWindowClosed.selector);
        v.deposit(1e8, 0);

        warpTo(Calendar.T + Calendar.W); // terminal growth: open
        vm.prank(user);
        v.deposit(1e8, 0);
        assertEq(v.dirEvm(), 1e8);
    }

    /// An unsolicited transfer never increases accounting (B1) and is owner-recoverable.
    function test_donation_not_accounted_recoverable() public {
        B4Vault v = createVault(address(mini));
        fundAndDeposit(v, 1e8, 0);
        ubtc.mint(address(v), 5e7); // donation
        assertEq(v.dirEvm(), 1e8); // accounting unchanged
        vm.prank(user);
        v.recoverEvm(address(ubtc));
        assertEq(ubtc.balanceOf(user), 5e7);
        assertEq(v.dirEvm(), 1e8); // no accounting callback (B6)
    }

    function test_unrelated_token_fully_recoverable() public {
        B4Vault v = createVault(address(mini));
        ueth_mint_to(address(v));
        vm.prank(user);
        v.recoverEvm(address(strayToken));
        assertEq(strayToken.balanceOf(user), 777);
    }

    // stray token helper
    function ueth_mint_to(address to) internal {
        strayToken.mint(to, 777);
    }

    function test_zero_deposit_reverts() public {
        B4Vault v = createVault(address(mini));
        vm.prank(user);
        vm.expectRevert(B4VaultStorage.ZeroDeposit.selector);
        v.deposit(0, 0);
    }
}
