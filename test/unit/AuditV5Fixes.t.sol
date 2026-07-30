// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {EngineHarness} from "../utils/EngineHarness.sol";
import {StructuralLeverage} from "src/libraries/StructuralLeverage.sol";
import {Phi} from "src/libraries/Phi.sol";
import {B4Factory} from "src/core/B4Factory.sol";
import {B4PoolDeployer} from "src/core/B4PoolDeployer.sol";
import {B4VaultStorage} from "src/core/B4VaultStorage.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {DescriptorLib} from "src/venue/DescriptorLib.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";

/// @notice Regressions for the 2026-07-22 full-code-audit fixes (F1–F4). Each asserts the
///         corrected behaviour; the pre-fix code fails these.
///         V6-M-5: the F2 tests call the engine's REAL `_quantizePx8` via the EngineHarness
///         exposure — the previous in-test uint256 mirror passed on PRE-FIX code (the
///         "fail-before" claim was false) and structurally could not observe the uint64
///         narrowing cast (V6-I-4) or its V8-I-7 clamp.
///         V6-L-9: F3 (settlement-decimals binding) and F4 (spot zero-price guard) regressions
///         the V5 commit message claimed but never shipped.
contract AuditV5FixesTest is VaultTestBase {
    EngineHarness h;

    function setUp() public {
        setUpProtocol();
        h = new EngineHarness();
        h.setup(ubtcDescriptor(), usdcDescriptor(), address(oracle));
        hub.setUserExists(address(h), true);
    }

    // ------------------------------------------------------------- F2: price quantization

    /// A HyperCore price is valid iff ≤5 significant figures (integer exempt) AND ≤
    /// maxDec−szDec decimal places. The venue rule the quantizer must always satisfy.
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

    function test_F2_quantizes_realistic_price_to_valid() public {
        // UBTC spot, szDecimals 4: live px $97,431.845 (a valid market price) → buy limit
        // 97431.845·1.005; the RAW writer field is 9-sig-fig invalid; quantized must be valid.
        uint256 limitWad = 97_431_845e15 * 1005 / 1000; // ~$97,918.7 in WAD
        uint256 rawPx8 = limitWad / 1e10;
        assertFalse(_valid(rawPx8, 4, true), "raw price is venue-invalid (pre-fix behaviour)");
        uint256 q = h.quantizePx8(limitWad, false, 4, true); // buy → round down
        assertTrue(_valid(q, 4, true), "quantized price is venue-valid");
        assertLe(q, rawPx8, "buy limit rounded down, never above the envelope");
    }

    function test_F2_sell_rounds_up_within_envelope() public {
        uint256 limitWad = 97_431_845e15 * 995 / 1000; // sell limit
        uint256 rawPx8 = limitWad / 1e10;
        uint256 q = h.quantizePx8(limitWad, true, 4, true); // sell → round up
        assertTrue(_valid(q, 4, true));
        assertGe(q, rawPx8, "sell limit rounded up, never below the envelope");
    }

    function test_F2_fuzz_always_valid(uint256 pxWad, bool roundUp, uint8 szDecRaw, bool isSpot)
        public
    {
        // Below the uint64-clamp region (px8 + one grid step < 2^64) so a valid price
        // always exists; the clamp region is pinned separately below.
        pxWad = bound(pxWad, 1e10, 1e28); // ≥ 1 px8 unit, px8 ≤ 1e18
        uint8 szDec = uint8(bound(szDecRaw, 0, isSpot ? 8 : 6));
        uint256 q = h.quantizePx8(pxWad, roundUp, szDec, isSpot);
        assertTrue(_valid(q, szDec, isSpot), "quantizer must always emit a valid venue price");
    }

    function test_F2_integer_price_preserved() public {
        // A whole-dollar price ($100,000) is already valid — must pass through unchanged.
        uint256 q = h.quantizePx8(100_000e18, false, 4, true);
        assertEq(q, 100_000e8, "integer price unchanged");
    }

    /// V6-I-4 / V8-I-7: the uint64 narrowing the mirror could never see. Above ~$1.8e11/unit
    /// the quantized px8 exceeds uint64 — the real function must SATURATE at the ceiling
    /// (order still emitted, never a silent mod-2^64 wrap), and just below the ceiling an
    /// integer-exempt price passes through unclamped.
    function test_F2_quantize_px8_uint64_clamp_region() public {
        assertEq(
            h.quantizePx8(2e29, false, 4, true), // px8 = 2e19 > uint64.max
            type(uint64).max,
            "saturates at the uint64 ceiling, no truncation wrap"
        );
        assertEq(
            h.quantizePx8(1e29, false, 4, true), // px8 = 1e19 < uint64.max, integer-exempt
            10_000_000_000_000_000_000,
            "below the ceiling: no clamp, no wrap"
        );
    }

    // ------------------------------------- F3: settlement-decimals binding (V6-L-9)

    /// The settlement descriptor must be the fixed-USD asset: a non-fixedUsd settlement is
    /// rejected at binding (DescriptorLib.verifySettlement, first branch).
    function test_F3_non_fixed_usd_settlement_rejected() public {
        CoreTypes.AssetDescriptor memory bad = usdcDescriptor();
        bad.fixedUsd = false;
        // Construct the deployer BEFORE expectRevert: it applies to the next call, and an
        // inline `new` in the argument list would consume it.
        address dep = address(new B4PoolDeployer());
        vm.expectRevert(DescriptorLib.BadSettlement.selector);
        new B4Factory(address(oracle), bad, address(1), dep);
    }

    /// A settlement token with coreWeiDecimals < PERP_USD_DECIMALS (6) would underflow-panic
    /// the engine's `10 ** (coreWeiDecimals − 6)` conversions on every perp-bearing vault —
    /// rejected at binding (verifySettlement, second branch). A weiDec-5 token is
    /// venue-legal per-token, so only this guard stands between it and the panic.
    function test_F3_weiDec5_settlement_rejected() public {
        CoreTypes.AssetDescriptor memory bad = usdcDescriptor();
        bad.coreWeiDecimals = 5;
        // Construct the deployer BEFORE expectRevert: it applies to the next call, and an
        // inline `new` in the argument list would consume it.
        address dep = address(new B4PoolDeployer());
        vm.expectRevert(DescriptorLib.BadSettlement.selector);
        new B4Factory(address(oracle), bad, address(1), dep);
    }

    // ------------------------------------- F4: spot zero-price guard (V6-L-9)

    /// A halted spot feed (pxWad == 0) on the ENGINE path: the planner must HOLD without
    /// reverting and without emitting any venue action (H3 — never a revert-loop), then
    /// resume the moment the feed returns.
    function test_F4_halted_spot_feed_holds_then_recovers() public {
        h.setTargets(int256(Phi.WAD), 0); // spot-only target 1 (growth)
        warpTo(Calendar.T + Calendar.W + 1); // growth plateau
        h.setBuckets(0, 0, 0, 0, 100_000_000_000, 0, 0); // $1,000 USDC sitting on Core

        hub.setSpotPx(SPOT_MKT, 0); // feed down
        assertFalse(h.planSync(), "halted feed: planner holds, no revert");
        assertEq(uint8(h.intentKind()), 0, "no intent may be created on a zero price");
        assertEq(hub.pendingActions(), 0, "no order may reach the venue on a zero price");

        hub.setSpotPx(SPOT_MKT, SPOT_PX); // feed returns
        assertTrue(h.planSync(), "feed back: the pending rotation proceeds");
        assertEq(
            uint8(h.intentKind()),
            uint8(B4VaultStorage.IntentKind.SpotOrder),
            "buy order emitted once the price is live"
        );
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
