// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Phi} from "src/libraries/Phi.sol";

contract PhiTest is Test {
    function test_constants_relations() public pure {
        // φ² = φ + 1, 1/φ = φ − 1 (exact at WAD resolution with these literals).
        assertEq(Phi.PHI_SQ, Phi.PHI + Phi.WAD);
        assertEq(Phi.INV_PHI, Phi.PHI - Phi.WAD);
        // φ·(φ−1) ≈ 1 (WAD): |φ·invφ − 1| within 1 wei of flooring error.
        uint256 prod = Phi.mulDiv(Phi.PHI, Phi.INV_PHI, Phi.WAD);
        assertApproxEqAbs(prod, Phi.WAD, 1);
        // f = φ⁻⁵/2 and q = φ⁻³/2 sanity: q = f·φ² (within flooring).
        assertApproxEqAbs(Phi.mulDiv(Phi.FEE_F, Phi.PHI_SQ, Phi.WAD), Phi.EXIT_Q, 2);
    }

    /// Exact agreement with native division whenever the product does not overflow.
    function testFuzz_mulDiv_matchesNative(uint256 a, uint256 b, uint256 d) public pure {
        d = bound(d, 1, type(uint256).max);
        if (b != 0) a = bound(a, 0, type(uint256).max / b);
        assertEq(Phi.mulDiv(a, b, d), (a * b) / d);
    }

    /// Full-width path: mulDiv(a, b, b) == a for any a, b — exercises 512-bit products.
    function testFuzz_mulDiv_cancellation(uint256 a, uint256 b) public pure {
        b = bound(b, 1, type(uint256).max);
        assertEq(Phi.mulDiv(a, b, b), a);
    }

    /// Floor semantics: mulDiv(a,b,d)·d ≤ a·b < (mulDiv+1)·d, checked via mulmod identity.
    function testFuzz_mulDiv_floorIdentity(uint256 a, uint256 b, uint256 d) public pure {
        a = bound(a, 0, type(uint128).max);
        b = bound(b, 0, type(uint128).max);
        d = bound(d, 1, type(uint256).max);
        uint256 q = Phi.mulDiv(a, b, d);
        uint256 r = mulmod(a, b, d);
        // a*b fits in 256 bits here (both ≤ 2^128−1).
        assertEq(q * d + r, a * b);
        assertLt(r, d);
    }

    function test_mulDiv_revertsOnOverflow() public {
        vm.expectRevert(Phi.MulDivOverflow.selector);
        this.mulDivExternal(type(uint256).max, type(uint256).max, 1);
    }

    function test_mulDiv_revertsOnZeroDenominator() public {
        vm.expectRevert(Phi.DivByZero.selector);
        this.mulDivExternal(1, 1, 0);
        vm.expectRevert(Phi.MulDivOverflow.selector);
        this.mulDivExternal(type(uint256).max, type(uint256).max, 0);
    }

    function mulDivExternal(uint256 a, uint256 b, uint256 d) external pure returns (uint256) {
        return Phi.mulDiv(a, b, d);
    }

    function testFuzz_wmul_bps_floor(uint256 a) public pure {
        a = bound(a, 0, type(uint128).max);
        assertEq(Phi.wmul(a, Phi.WAD), a);
        assertLe(Phi.bps(a, Phi.MAX_OPERATOR_BPS), a);
        // Floor toward protocol: bps never rounds up.
        assertEq(Phi.bps(a, 3819), (a * 3819) / 10_000);
    }
}
