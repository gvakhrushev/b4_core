// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {B4Pool} from "./B4Pool.sol";
import {CoreTypes} from "../venue/CoreTypes.sol";

/// @notice The factories reference the deployer through this interface ONLY. Importing the
///         concrete contract would pull `B4Pool`'s creation code straight back into them,
///         which is the whole thing this split exists to prevent.
interface IB4PoolDeployer {
    function deploy(address oracle, CoreTypes.AssetDescriptor[] memory descriptors)
        external
        returns (address);
}

/// @title B4PoolDeployer — the single place that holds `B4Pool`'s creation code.
/// @notice Both factory paths used to run `new B4Pool(...)` inline, which embeds `B4Pool`'s
///         entire ~18 KB of creation code into each of them. That left `B4Factory` with 326
///         spare bytes and `B4ProductPoolCreator` with 38, and — because the creator is what
///         actually carries the pool's bytecode — it made `B4Pool`'s own 8 KB of apparent
///         headroom unusable: every byte added to the pool overflowed the creator instead.
///         Four accepted audit fixes were blocked by that and by nothing else
///         (`docs/audits/REGISTRY.md`).
///
///         Holding the creation code once, here, gives the pool back its real headroom and
///         costs the factories a single external call.
///
/// @dev No owner, no state, no upgrade path — one immutable function. Deployed ONCE and
///      passed to both factories by address; a factory that constructed its own would embed
///      the creation code again and defeat the purpose.
///
///      Trust model is unchanged: `factory` is set from `msg.sender` here, exactly as it was
///      set from `msg.sender` by the inline `new B4Pool(...)` before. Anyone may call this
///      and obtain a pool whose `factory` is themselves — just as anyone could always deploy
///      a `B4Pool` directly. Such a pool is inert: authority comes from a factory's own
///      `isPool` registry, which is written only for pools that factory created, and every
///      vault-creating path checks it.
contract B4PoolDeployer {
    /// @notice Deploy a pool owned by the caller as its factory.
    /// @param oracle the halving oracle the pool reads its calendar from
    /// @param descriptors settlement descriptor at [0], then 1..N directional
    function deploy(address oracle, CoreTypes.AssetDescriptor[] memory descriptors)
        external
        returns (address)
    {
        return address(new B4Pool(oracle, descriptors, msg.sender));
    }
}
