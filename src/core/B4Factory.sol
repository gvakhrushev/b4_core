// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {B4Pool} from "./B4Pool.sol";
import {B4Vault} from "./B4Vault.sol";
import {B4VaultStorage} from "./B4VaultStorage.sol";
import {CoreTypes} from "../venue/CoreTypes.sol";
import {DescriptorLib} from "../venue/DescriptorLib.sol";

/// @title B4Factory — permissionless pool creation and atomic vault binding.
/// @notice No authority anywhere (F1): the factory holds no funds, has no owner, and only
///         deploys immutable configurations. Vault creation atomically binds owner, pool,
///         execution identity, stored targets and the immutable fee route in one
///         transaction — no front-run window, no half-initialized state (F3).
contract B4Factory {
    address public immutable oracle;
    address public immutable vaultImplementation;
    CoreTypes.AssetDescriptor internal _settlement;

    mapping(address => bool) public isPool;
    mapping(address => bool) public isVault;

    event PoolCreated(address indexed pool, uint256 directionalAssets);
    event VaultCreated(
        address indexed vault, address indexed owner, address indexed pool, bytes32 dirHash
    );

    error NotAPool();
    error UnknownDescriptor();
    error CloneFailed();

    /// @param vaultImplementation_ pre-deployed B4Vault implementation (bound to its
    ///        B4VaultOps module by immutable). Deployed separately to respect EIP-3860;
    ///        both are part of the reproducible-build manifest (SECURITY_MODEL §5.14).
    constructor(
        address oracle_,
        CoreTypes.AssetDescriptor memory settlement_,
        address vaultImplementation_
    ) {
        oracle = oracle_;
        DescriptorLib.verifySettlement(settlement_);
        _settlement = settlement_;
        vaultImplementation = vaultImplementation_;
    }

    function settlementDescriptor() external view returns (CoreTypes.AssetDescriptor memory) {
        return _settlement;
    }

    /// @notice Permissionless pool creation — not endorsement (REQUIREMENTS §1). Every
    ///         directional descriptor is validated against the venue before binding.
    function createPool(CoreTypes.AssetDescriptor[] calldata directional)
        external
        returns (address poolAddr)
    {
        CoreTypes.AssetDescriptor[] memory all =
            new CoreTypes.AssetDescriptor[](directional.length + 1);
        all[0] = _settlement;
        for (uint256 i = 0; i < directional.length; i++) {
            DescriptorLib.verifyDirectional(directional[i], _settlement);
            all[i + 1] = directional[i];
        }
        poolAddr = address(new B4Pool(oracle, all));
        isPool[poolAddr] = true;
        emit PoolCreated(poolAddr, directional.length);
    }

    /// @notice Create a vault: msg.sender becomes the fixed owner and signs the whole
    ///         configuration — pool, descriptor, policy, scale, slippage and the immutable
    ///         fee route — by sending this transaction (REQUIREMENTS §5.2).
    function createVault(
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
        CoreTypes.AssetDescriptor memory dir = B4Pool(pool).asset(indexPlusOne - 1);

        vault = _clone(vaultImplementation);
        isVault[vault] = true;
        B4Vault(vault)
            .initialize(
                msg.sender,
                pool,
                oracle,
                dir,
                _settlement,
                indexPlusOne - 1,
                strategy,
                scaleWad,
                slippageBps,
                route
            );
        B4Pool(pool).registerVault(vault);
        emit VaultCreated(vault, msg.sender, pool, dirDescriptorHash);
    }

    /// @dev Minimal EIP-1167 clone.
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
