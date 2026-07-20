// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IStrategy} from "../interfaces/IStrategy.sol";
import {Phi} from "../libraries/Phi.sol";

/// @notice The reference product ladder (WHITEPAPER §2). The core stores no product
///         names — a strategy is just a (growth, fall) pair read once at selection.
contract StrategyMini is IStrategy {
    function targets() external pure returns (int256, int256) {
        return (int256(Phi.WAD), int256(Phi.WAD)); // hold spot in both regimes
    }
}

contract StrategyB4 is IStrategy {
    function targets() external pure returns (int256, int256) {
        return (int256(Phi.WAD), int256(0)); // fall-regime rotation into USDC
    }
}

contract StrategyPro is IStrategy {
    function targets() external pure returns (int256, int256) {
        return (int256(Phi.WAD), -int256(Phi.INV_PHI)); // hedge: short 1/φ in fall
    }
}

contract StrategyProMax is IStrategy {
    function targets() external pure returns (int256, int256) {
        return (int256(Phi.PHI), -int256(Phi.PHI)); // leveraged expression, |n| = φ
    }
}
