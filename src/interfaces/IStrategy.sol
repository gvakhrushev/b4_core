// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice A strategy exposes one (growth, fall) pair of signed WAD base targets. It is
///         read ONCE at selection; later mutation of a strategy contract never changes a
///         vault's stored targets unless the owner re-selects (REQUIREMENTS §2).
interface IStrategy {
    function targets() external view returns (int256 growth, int256 fall);
}
