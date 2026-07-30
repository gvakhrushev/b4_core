// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {B4Pool} from "./B4Pool.sol";
import {IB4PoolDeployer} from "./B4PoolDeployer.sol";
import {B4Vault} from "./B4Vault.sol";
import {B4FactoryStorage} from "./B4FactoryVaultCreator.sol";
import {B4VaultStorage} from "./B4VaultStorage.sol";
import {CoreTypes} from "../venue/CoreTypes.sol";
import {DescriptorLib} from "../venue/DescriptorLib.sol";
import {Phi} from "../libraries/Phi.sol";

/// @dev Delegate-only product-pool deployer. The calling `B4ProductFactory` remains
///      the pool's immutable factory, so it is the only address able to register sleeves
///      and later user vaults.
contract B4ProductPoolCreator is B4FactoryStorage {
    uint16 internal constant POOL_SLIPPAGE_BPS = 100;

    error BadPolicyConfig();

    function createProductPool(
        address oracle,
        address vaultImplementation,
        CoreTypes.AssetDescriptor[] calldata directional,
        address[4] calldata strategies,
        uint8 policyMask
    ) external returns (address poolAddr) {
        if (!_isProductChoice(policyMask)) {
            revert BadPolicyConfig();
        }
        CoreTypes.AssetDescriptor[] memory all =
            new CoreTypes.AssetDescriptor[](directional.length + 1);
        all[0] = _settlement;
        for (uint256 i = 0; i < directional.length; i++) {
            DescriptorLib.verifyDirectional(directional[i], _settlement);
            all[i + 1] = directional[i];
        }
        poolAddr = IB4PoolDeployer(poolDeployer).deploy(oracle, all);
        isPool[poolAddr] = true;
        B4Pool p = B4Pool(poolAddr);
        p.configurePolicies(strategies, policyMask);

        for (uint256 d = 0; d < directional.length; d++) {
            for (uint8 policy = 1; policy <= 4; policy++) {
                if ((policyMask & (uint8(1) << (policy - 1))) == 0) continue;
                _createSleeve(
                    oracle,
                    vaultImplementation,
                    poolAddr,
                    directional[d],
                    d + 1,
                    strategies[policy - 1],
                    policy
                );
            }
        }
    }

    function _createSleeve(
        address oracle,
        address vaultImplementation,
        address poolAddr,
        CoreTypes.AssetDescriptor calldata dir,
        uint256 dirAssetIndex,
        address strategy,
        uint8 policy
    ) internal {
        (int256 g, int256 f) = _referenceTargets(policy);
        address sleeve = _clone(vaultImplementation);
        B4Vault(sleeve)
            .initialize(
                poolAddr,
                poolAddr,
                oracle,
                dir,
                _settlement,
                dirAssetIndex,
                strategy,
                Phi.WAD,
                g,
                f,
                POOL_SLIPPAGE_BPS,
                B4VaultStorage.FeeRoute(address(0), 0, address(0), 0)
            );
        B4Pool(poolAddr).registerSleeve(sleeve, policy, dirAssetIndex);
    }

    function _referenceTargets(uint8 policy) internal pure returns (int256 g, int256 f) {
        if (policy == 1) return (int256(Phi.WAD), int256(Phi.WAD));
        if (policy == 2) return (int256(Phi.WAD), int256(0));
        if (policy == 3) return (int256(Phi.WAD), -int256(Phi.WAD));
        if (policy == 4) return (int256(Phi.PHI), -int256(Phi.PHI));
        revert BadPolicyConfig();
    }

    /// @dev Deliberately only the four isolated products and the explicit all-products
    ///      aggregate are deployable. A partial mixed mask would be a sixth economics
    ///      choice with no user-facing specification.
    function _isProductChoice(uint8 mask) internal pure returns (bool) {
        return mask == 1 || mask == 2 || mask == 4 || mask == 8 || mask == 15;
    }

    function _clone(address impl) internal returns (address instance) {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, impl))
            mstore(
                add(ptr, 0x28),
                0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000
            )
            instance := create(0, ptr, 0x37)
        }
        if (instance == address(0)) revert BadPolicyConfig();
    }
}
