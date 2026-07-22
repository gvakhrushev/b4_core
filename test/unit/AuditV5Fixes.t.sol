// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StructuralLeverage} from "src/libraries/StructuralLeverage.sol";
import {Phi} from "src/libraries/Phi.sol";

/// @notice Regressions for the 2026-07-22 full-code-audit fixes (F1–F4). Each asserts the
///         corrected behaviour; the pre-fix code fails these.
contract AuditV5FixesTest is Test {
    // ------------------------------------------------------------- F2: price quantization
    // A thin harness exposing the engine's price quantizer via an identical implementation
    // (the engine method is internal; this mirrors it exactly and is pinned to the same
    // venue rule). Real-engine coverage lands in the venue integration tests.
    function _quantize(uint256 pxWad, bool roundUp, uint8 szDec, bool isSpot)
        internal
        pure
        returns (uint256)
    {
        uint256 px8 = pxWad / 1e10;
        if (px8 == 0) return 0;
        uint256 maxDec = isSpot ? 8 : 6;
        uint256 dcap = maxDec > szDec ? maxDec - szDec : 0;
        uint256 step = 10 ** (8 - dcap);
        if (px8 % 1e8 != 0) {
            uint256 digits;
            for (uint256 t = px8; t != 0; t /= 10) {
                digits++;
            }
            uint256 sigStep = digits > 5 ? 10 ** (digits - 5) : 1;
            if (sigStep > step) step = sigStep;
        }
        uint256 q = (px8 / step) * step;
        if (roundUp && q != px8) q += step;
        return q;
    }

    /// A HyperCore price is valid iff ≤5 significant figures (integer exempt) AND ≤
    /// maxDec−szDec decimal places. Assert the quantizer always emits a valid price.
    function _valid(uint256 px8, uint8 szDec, bool isSpot) internal pure returns (bool) {
        if (px8 == 0) return true;
        uint256 maxDec = isSpot ? 8 : 6;
        uint256 dcap = maxDec > szDec ? maxDec - szDec : 0;
        if (px8 % (10 ** (8 - dcap)) != 0) return false; // decimal-place cap
        if (px8 % 1e8 == 0) return true; // integer price: sig-fig rule exempt
        uint256 digits;
        for (uint256 t = px8; t != 0; t /= 10) {
            digits++;
        }
        uint256 trailing;
        for (uint256 t = px8; t % 10 == 0; t /= 10) {
            trailing++;
        }
        return digits - trailing <= 5;
    }

    function test_F2_quantizes_realistic_price_to_valid() public pure {
        // UBTC spot, szDecimals 4: live px $97,431.845 (a valid market price) → buy limit
        // 97431.845·1.005; the RAW writer field is 9-sig-fig invalid; quantized must be valid.
        uint256 limitWad = 97_431_845e15 * 1005 / 1000; // ~$97,918.7 in WAD
        uint256 rawPx8 = limitWad / 1e10;
        assertFalse(_valid(rawPx8, 4, true), "raw price is venue-invalid (pre-fix behaviour)");
        uint256 q = _quantize(limitWad, false, 4, true); // buy → round down
        assertTrue(_valid(q, 4, true), "quantized price is venue-valid");
        assertLe(q, rawPx8, "buy limit rounded down, never above the envelope");
    }

    function test_F2_sell_rounds_up_within_envelope() public pure {
        uint256 limitWad = 97_431_845e15 * 995 / 1000; // sell limit
        uint256 rawPx8 = limitWad / 1e10;
        uint256 q = _quantize(limitWad, true, 4, true); // sell → round up
        assertTrue(_valid(q, 4, true));
        assertGe(q, rawPx8, "sell limit rounded up, never below the envelope");
    }

    function test_F2_fuzz_always_valid(uint256 pxWad, bool roundUp, uint8 szDecRaw, bool isSpot)
        public
        pure
    {
        pxWad = bound(pxWad, 1e10, 1e30); // ≥ 1 px8 unit, ≤ astronomical
        uint8 szDec = uint8(bound(szDecRaw, 0, isSpot ? 8 : 6));
        uint256 q = _quantize(pxWad, roundUp, szDec, isSpot);
        assertTrue(_valid(q, szDec, isSpot), "quantizer must always emit a valid venue price");
    }

    function test_F2_integer_price_preserved() public pure {
        // A whole-dollar price ($100,000) is already valid — must pass through unchanged.
        uint256 q = _quantize(100_000e18, false, 4, true);
        assertEq(q, 100_000e8, "integer price unchanged");
    }

    // -------------------------------------------------- F5/F6: short-side crossover truth
    // The corrected claim: post-pivot leverage exceeds the flat base for entries above
    // maxStop/2 (well below C), NOT "only above C". Pin the real crossover.
    function test_F5_leverage_exceeds_base_below_C() public pure {
        uint256 phi = Phi.PHI;
        uint256 prevPeak = 67_774e18;
        uint256 C = 115_265e18;
        // maxStop = C + (C−prevPeak)(φ−1); crossover (L = φ) at maxStop/2, which is < C.
        uint256 maxStop = C + Phi.mulDiv(C - prevPeak, phi - Phi.WAD, Phi.WAD);
        uint256 half = maxStop / 2;
        assertLt(half, C, "crossover maxStop/2 lies BELOW the confirmed peak C");
        // An entry between maxStop/2 and C already exceeds the flat base — the doc claim
        // 'exceeds base only above C' was false.
        uint256 mid = (half + C) / 2;
        uint256 l = StructuralLeverage.shortLeverageWad(mid, phi, prevPeak, C);
        assertGt(l, phi, "leverage exceeds flat phi for an entry below C");
    }
}
