// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {B4Pool} from "./B4Pool.sol";
import {B4Vault} from "./B4Vault.sol";
import {B4VaultStorage} from "./B4VaultStorage.sol";
import {CoreTypes} from "../venue/CoreTypes.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";

/// @dev Exact storage prefix of both factory flavours. The creator is reached only
///      through delegatecall, so its writes affect the calling factory's mappings.
abstract contract B4FactoryStorage {
    CoreTypes.AssetDescriptor internal _settlement;
    mapping(address => bool) public isPool;
    mapping(address => bool) public isVault;
    /// The shared `B4PoolDeployer`. Storage, not an immutable, because the size-sharded
    /// creator modules run by delegatecall and must see it in the factory's own context.
    /// Public: it is the one trust input the pool-deployment split introduced, so it must be
    /// verifiable on-chain after deployment like every other factory wiring field.
    address public poolDeployer;
}

/// @dev Size-sharded implementation of the common create-vault ABI. It has no useful
///      standalone state: a direct call sees an empty pool registry and reverts.
contract B4FactoryVaultCreator is B4FactoryStorage {
    struct VaultInit {
        address vault;
        address owner;
        address pool;
        CoreTypes.AssetDescriptor dir;
        uint256 dirAssetIndex;
        address strategy;
        uint256 scaleWad;
        int256 growth;
        int256 fall;
        uint16 slippageBps;
        uint8 policy;
        B4VaultStorage.FeeRoute route;
    }

    error NotAPool();
    error UnknownDescriptor();
    error CloneFailed();
    error BadPolicyConfig();

    function createVault(
        address oracle,
        address vaultImplementation,
        address pool,
        bytes32 dirDescriptorHash,
        address strategy,
        uint256 scaleWad,
        uint16 slippageBps,
        B4VaultStorage.FeeRoute calldata route
    ) external returns (address vault) {
        if (!isPool[pool]) revert NotAPool();
        uint256 indexPlusOne = B4Pool(pool).descriptorIndexPlusOne(dirDescriptorHash);
        if (indexPlusOne == 0) revert UnknownDescriptor();

        VaultInit memory init;
        init.owner = msg.sender;
        init.pool = pool;
        init.dir = B4Pool(pool).asset(indexPlusOne - 1);
        init.dirAssetIndex = indexPlusOne - 1;
        init.strategy = strategy;
        init.scaleWad = scaleWad;
        (init.growth, init.fall) = IStrategy(strategy).targets();
        if (!B4Pool(pool)
                .policyAllowedForVault(address(0), strategy, init.growth, init.fall, scaleWad)) revert BadPolicyConfig();
        init.policy = B4Pool(pool).policyIdForStrategy(strategy);
        init.slippageBps = slippageBps;
        init.route = route;

        vault = _clone(vaultImplementation);
        isVault[vault] = true;
        init.vault = vault;
        B4Vault(vault)
            .initialize(
                init.owner,
                init.pool,
                oracle,
                init.dir,
                _settlement,
                init.dirAssetIndex,
                init.strategy,
                init.scaleWad,
                init.growth,
                init.fall,
                init.slippageBps,
                init.route
            );
        B4Pool(pool).registerVault(vault, init.policy, init.dirAssetIndex);
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
        if (instance == address(0)) revert CloneFailed();
    }
}
