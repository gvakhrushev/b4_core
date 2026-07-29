// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {B4FactoryStorage, B4FactoryVaultCreator} from "./B4FactoryVaultCreator.sol";
import {B4ProductPoolCreator} from "./B4ProductPoolCreator.sol";
import {B4VaultStorage} from "./B4VaultStorage.sol";
import {CoreTypes} from "../venue/CoreTypes.sol";
import {DescriptorLib} from "../venue/DescriptorLib.sol";
import {IHalvingOracle} from "../interfaces/IHalvingOracle.sol";

/// @title B4ProductFactory — strict four-product / aggregate-pool deployment.
/// @notice No owner, no post-deployment controls. Immutable delegate modules only shard
///         code size; they execute in this factory's context, preserving the same atomic
///         pool/vault registration guarantees as a monolithic factory.
contract B4ProductFactory is B4FactoryStorage {
    address public immutable oracle;
    address public immutable vaultImplementation;
    address public immutable vaultCreator;
    address public immutable poolCreator;

    event ProductPoolCreated(address indexed pool, uint256 directionalAssets, uint8 policyMask);
    event VaultCreated(
        address indexed vault, address indexed owner, address indexed pool, bytes32 dirHash
    );

    error OracleNotBootstrapped();
    error ZeroPoolDeployer();

    constructor(
        address oracle_,
        CoreTypes.AssetDescriptor memory settlement_,
        address vaultImplementation_,
        address poolDeployer_
    ) {
        if (poolDeployer_ == address(0)) revert ZeroPoolDeployer();
        poolDeployer = poolDeployer_;
        oracle = oracle_;
        DescriptorLib.verifySettlement(settlement_);
        _settlement = settlement_;
        vaultImplementation = vaultImplementation_;
        vaultCreator = address(new B4FactoryVaultCreator());
        poolCreator = address(new B4ProductPoolCreator());
    }

    function settlementDescriptor() external view returns (CoreTypes.AssetDescriptor memory) {
        return _settlement;
    }

    /// @notice Single masks 1/2/4/8 are isolated Mini/B4/Pro/Pro Max pools. Mask 15
    ///         is the fifth, explicit aggregate pool; it still keeps four sleeves while
    ///         capital trades, and reunites their realised proceeds only at distribution.
    function createProductPool(
        CoreTypes.AssetDescriptor[] calldata directional,
        address[4] calldata strategies,
        uint8 policyMask
    ) external returns (address poolAddr) {
        if (IHalvingOracle(oracle).halvingHeight() == 0) {
            revert OracleNotBootstrapped();
        }
        bytes memory data = abi.encodeCall(
            B4ProductPoolCreator.createProductPool,
            (oracle, vaultImplementation, directional, strategies, policyMask)
        );
        (bool ok, bytes memory ret) = poolCreator.delegatecall(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        poolAddr = abi.decode(ret, (address));
        emit ProductPoolCreated(poolAddr, directional.length, policyMask);
    }

    function createVault(
        address pool,
        bytes32 dirDescriptorHash,
        address strategy,
        uint256 scaleWad,
        uint16 slippageBps,
        B4VaultStorage.FeeRoute calldata route
    ) external returns (address vault) {
        bytes memory data = abi.encodeCall(
            B4FactoryVaultCreator.createVault,
            (
                oracle,
                vaultImplementation,
                pool,
                dirDescriptorHash,
                strategy,
                scaleWad,
                slippageBps,
                route
            )
        );
        (bool ok, bytes memory ret) = vaultCreator.delegatecall(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        vault = abi.decode(ret, (address));
        emit VaultCreated(vault, msg.sender, pool, dirDescriptorHash);
    }
}
