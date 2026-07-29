// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Narrow policy-domain interface shared by a vault and its pool.
/// @dev A configured pool is an immutable product domain.  The vault asks the
///      pool before accepting a policy change; the pool never gets authority
///      over a user vault's funds or arbitrary calls.
interface IB4PoolPolicy {
    function policyAllowedForVault(
        address vault,
        address strategy,
        int256 growth,
        int256 fall,
        uint256 scaleWad
    ) external view returns (bool);

    function setVaultPolicy(uint8 policy) external;

    function policyIdForStrategy(address strategy) external view returns (uint8);
}
