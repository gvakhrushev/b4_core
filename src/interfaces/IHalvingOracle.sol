// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IHalvingOracle {
    function halvingHeight() external view returns (uint256);
    function halvingTs() external view returns (uint256);
    function epoch() external view returns (uint256);
    function timeSinceHalving() external view returns (uint256);
}
