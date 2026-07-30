// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IB4PoolDeployer} from "./B4PoolDeployer.sol";
import {B4FactoryStorage, B4FactoryVaultCreator} from "./B4FactoryVaultCreator.sol";
import {B4VaultStorage} from "./B4VaultStorage.sol";
import {CoreTypes} from "../venue/CoreTypes.sol";
import {DescriptorLib} from "../venue/DescriptorLib.sol";
import {IHalvingOracle} from "../interfaces/IHalvingOracle.sol";

/// @title B4Factory — permissionless legacy-pool creation and atomic vault binding.
/// @notice The strict four-product path is `B4ProductFactory`; this ABI remains intact
///         for generic pools. Creation code is sharded into a fixed delegate module to
///         keep both paths deployable under EIP-170.
contract B4Factory is B4FactoryStorage {
    address public immutable oracle;
    address public immutable vaultImplementation;
    address public immutable vaultCreator;

    event PoolCreated(address indexed pool, uint256 directionalAssets);
    event VaultCreated(
        address indexed vault, address indexed owner, address indexed pool, bytes32 dirHash
    );

    error CloneFailed();
    error NotAPool();
    error UnknownDescriptor();
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
    }

    function settlementDescriptor() external view returns (CoreTypes.AssetDescriptor memory) {
        return _settlement;
    }

    function createPool(CoreTypes.AssetDescriptor[] calldata directional)
        external
        returns (address poolAddr)
    {
        if (IHalvingOracle(oracle).halvingHeight() == 0) revert OracleNotBootstrapped();
        CoreTypes.AssetDescriptor[] memory all =
            new CoreTypes.AssetDescriptor[](directional.length + 1);
        all[0] = _settlement;
        for (uint256 i = 0; i < directional.length; i++) {
            DescriptorLib.verifyDirectional(directional[i], _settlement);
            all[i + 1] = directional[i];
        }
        poolAddr = IB4PoolDeployer(poolDeployer).deploy(oracle, all);
        isPool[poolAddr] = true;
        emit PoolCreated(poolAddr, directional.length);
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
