// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Phi — protocol constants and floor fixed-point math.
/// @notice All fixed-point division floors toward the protocol (HAZARDS B5): fees,
///         penalties, cuts and pool claims never round up; dust stays with the protocol.
library Phi {
    uint256 internal constant WAD = 1e18;

    /// φ (golden ratio), WAD.
    uint256 internal constant PHI = 1_618033988749894848;
    /// φ² = φ + 1, WAD.
    uint256 internal constant PHI_SQ = 2_618033988749894848;
    /// 1/φ = φ − 1, WAD.
    uint256 internal constant INV_PHI = 618033988749894848;

    /// Virtual performance-fee rate f = φ⁻⁵/2 (SPECIFICATION §8), WAD.
    uint256 internal constant FEE_F = 45084971874737120;
    /// Exit penalty rate q = φ⁻³/2 (SPECIFICATION §9), WAD.
    uint256 internal constant EXIT_Q = 118033988749894848;

    uint256 internal constant BPS = 10_000;
    /// operatorBps ≤ 38.19% of the virtual fee (SPECIFICATION §2).
    uint256 internal constant MAX_OPERATOR_BPS = 3819;
    /// referrerBps ∈ [38.19%, 100%] of the operator payment (SPECIFICATION §2).
    uint256 internal constant MIN_REFERRER_BPS = 3819;

    /// Policy bounds (SPECIFICATION §3): |base| ≤ 10 WAD, 0 < scale ≤ 10 WAD, |resolved| ≤ φ.
    uint256 internal constant MAX_BASE_TARGET = 10e18;
    uint256 internal constant MAX_SCALE = 10e18;

    error MulDivOverflow();
    error DivByZero();

    /// @notice Full-precision floor(a·b/d). Reverts on d == 0 or a result ≥ 2²⁵⁶.
    /// @dev 512-bit multiply then division; standard published technique
    ///      (2¹⁹²-trick via mulmod + modular inverse of the odd part of d).
    function mulDiv(uint256 a, uint256 b, uint256 d) internal pure returns (uint256 result) {
        // 512-bit product [p1 p0] = a·b.
        uint256 p0;
        uint256 p1;
        unchecked {
            uint256 mm = mulmod(a, b, type(uint256).max);
            p0 = a * b;
            p1 = mm - p0;
            if (mm < p0) p1 -= 1;
        }
        if (p1 == 0) {
            if (d == 0) revert DivByZero();
            return p0 / d;
        }
        if (d <= p1) revert MulDivOverflow(); // covers d == 0 as well
        unchecked {
            // Remainder, then subtract from the 512-bit product.
            uint256 r = mulmod(a, b, d);
            if (r > p0) p1 -= 1;
            p0 -= r;
            // Factor out powers of two from d.
            uint256 twos = d & (0 - d);
            d /= twos;
            p0 /= twos;
            // Shift high bits of p1 into p0. twos is a power of two, so
            // 2²⁵⁶/twos = (0 - twos)/twos + 1.
            p0 |= p1 * ((0 - twos) / twos + 1);
            // Modular inverse of (now odd) d via Newton iterations.
            uint256 inv = (3 * d) ^ 2;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            result = p0 * inv;
        }
    }

    /// @notice floor(a·b/WAD).
    function wmul(uint256 a, uint256 b) internal pure returns (uint256) {
        return mulDiv(a, b, WAD);
    }

    /// @notice floor(a·bps/10000).
    function bps(uint256 a, uint256 rateBps) internal pure returns (uint256) {
        return mulDiv(a, rateBps, BPS);
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    function abs(int256 a) internal pure returns (uint256) {
        return a >= 0 ? uint256(a) : uint256(-a);
    }
}
