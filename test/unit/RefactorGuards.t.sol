// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {B4Factory} from "src/core/B4Factory.sol";
import {B4Pool} from "src/core/B4Pool.sol";
import {B4PoolDeployer} from "src/core/B4PoolDeployer.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {B4VaultOps} from "src/core/B4VaultOps.sol";
import {B4VaultRecovery} from "src/core/B4VaultRecovery.sol";
import {B4VaultStorage} from "src/core/B4VaultStorage.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";
import {Phi} from "src/libraries/Phi.sol";

/// @notice Guards introduced by the EIP-170 refactor (`B4PoolDeployer`, `B4VaultRecovery`).
///         None of these had a test: `ZeroOps`, `ZeroPoolDeployer` and `NotDelegated` all
///         returned zero hits across `test/` before this file.
contract RefactorGuardsTest is VaultTestBase {
    function setUp() public {
        setUpProtocol();
    }

    // ------------------------------------------------- vault module wiring

    function test_vault_rejects_zero_modules() public {
        address ops = address(new B4VaultOps());
        address rec = address(new B4VaultRecovery());
        vm.expectRevert(B4Vault.ZeroOps.selector);
        new B4Vault(address(0), rec);
        vm.expectRevert(B4Vault.ZeroOps.selector);
        new B4Vault(ops, address(0));
    }

    /// Equal modules would route every cold-path dispatch into `ops`, where those selectors
    /// do not exist — bricking recovery and deferred payouts on an implementation that can
    /// never be redeployed for existing clones.
    function test_vault_rejects_identical_modules() public {
        address ops = address(new B4VaultOps());
        vm.expectRevert(B4Vault.ZeroOps.selector);
        new B4Vault(ops, ops);
    }

    /// Both modules must be inert when called directly: they operate on their own empty
    /// storage, so `_initialized` is false and every entry point refuses.
    function test_both_modules_are_inert_on_a_direct_call() public {
        B4VaultOps ops = new B4VaultOps();
        B4VaultRecovery rec = new B4VaultRecovery();
        vm.expectRevert(B4VaultOps.NotDelegated.selector);
        ops.opsPlanStep();
        vm.expectRevert(B4VaultRecovery.NotDelegated.selector);
        rec.opsRecoverPerpSurplus();
    }

    /// The implementation self-seals, so the clone template can never be initialized.
    function test_implementation_cannot_be_initialized_after_split() public {
        B4Vault impl = B4Vault(factory.vaultImplementation());
        assertTrue(impl.ops() != impl.recovery(), "two distinct modules");
        vm.expectRevert(B4VaultStorage.AlreadyInitialized.selector);
        impl.initialize(
            address(this),
            address(pool),
            address(oracle),
            ubtcDescriptor(),
            usdcDescriptor(),
            1,
            address(mini),
            Phi.WAD,
            int256(Phi.WAD),
            int256(Phi.WAD),
            100,
            defaultRoute()
        );
    }

    // ------------------------------------------------- pool deployer wiring

    function test_factory_rejects_zero_pool_deployer() public {
        vm.expectRevert(B4Factory.ZeroPoolDeployer.selector);
        new B4Factory(address(oracle), usdcDescriptor(), address(1), address(0));
    }

    function test_pool_deployer_is_verifiable_on_chain() public view {
        assertEq(factory.poolDeployer(), address(poolDeployer), "wiring is readable");
    }

    /// `B4Pool.factory` is now a constructor parameter, so it is SELF-DECLARED: anyone can
    /// name a real factory. That is decorative and grants nothing — authority flows only
    /// from a factory's own `isPool` registry, which is written solely for pools that
    /// factory created. This test pins that property so nobody later treats `factory()` as
    /// a provenance check.
    function test_impostor_pool_may_name_the_real_factory_and_gains_nothing() public {
        CoreTypes.AssetDescriptor[] memory ds = new CoreTypes.AssetDescriptor[](2);
        ds[0] = usdcDescriptor();
        ds[1] = ubtcDescriptor();
        B4Pool rogue = new B4Pool(address(oracle), ds, address(factory));

        assertEq(rogue.factory(), address(factory), "the field is caller-supplied");
        assertFalse(factory.isPool(address(rogue)), "but the registry is the truth");

        vm.expectRevert();
        factory.createVault(
            address(rogue),
            CoreTypes.descriptorHash(ubtcDescriptor()),
            address(mini),
            Phi.WAD,
            100,
            defaultRoute()
        );
    }

    /// A pool obtained straight from the shared deployer is owned by its caller, exactly as
    /// an inline `new B4Pool(...)` was before the split — the trust model did not widen.
    function test_direct_deployer_call_yields_a_pool_owned_by_its_caller() public {
        CoreTypes.AssetDescriptor[] memory ds = new CoreTypes.AssetDescriptor[](2);
        ds[0] = usdcDescriptor();
        ds[1] = ubtcDescriptor();
        B4Pool p = B4Pool(B4PoolDeployer(address(poolDeployer)).deploy(address(oracle), ds));
        assertEq(p.factory(), address(this), "factory = the deployer's caller");
        assertFalse(factory.isPool(address(p)), "and it is in no real registry");
    }
}
