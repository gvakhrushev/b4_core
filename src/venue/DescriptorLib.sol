// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CoreTypes} from "./CoreTypes.sol";
import {CoreReader} from "./CoreReader.sol";

/// @title DescriptorLib — venue-side consistency verification of asset descriptors.
/// @notice SPECIFICATION §2: before a vault accepts funds, the descriptor's
///         token/decimals/spot-pair/perp identities must verify against the venue and the
///         perp must be cross-marginable. The token↔perp ASSOCIATION itself has no
///         canonical on-chain statement — the immutable descriptor supplies it and the
///         user must verify it before signing (SECURITY_MODEL §3).
library DescriptorLib {
    error TokenMismatch();
    error DecimalsMismatch();
    error SpotPairMismatch();
    error PerpNotCrossMarginable();
    error PerpMismatch();
    error PerpIdUnsupported();
    error BadSettlement();
    error BadDirectional();

    function verifyDirectional(
        CoreTypes.AssetDescriptor memory d,
        CoreTypes.AssetDescriptor memory settlement
    ) internal view {
        if (d.fixedUsd || d.evmToken == settlement.evmToken || d.coreToken == settlement.coreToken)
        {
            revert BadDirectional();
        }
        _verifyToken(d);
        // Spot lot decimals bound the fixed-point exponents `10^(8 − spotSzDecimals)`
        // used at order emission and price normalization; > 8 would underflow.
        if (d.spotSzDecimals > 8) revert DecimalsMismatch();
        CoreTypes.SpotInfo memory s = CoreReader.spotInfo(d.spotMarket);
        if (s.tokens[0] != d.coreToken || s.tokens[1] != settlement.coreToken) {
            revert SpotPairMismatch();
        }
        if (d.perpMarket != CoreTypes.NO_MARKET) {
            // Extended (HIP-3 style) perp ids above uint16 are rejected at binding: the
            // legacy position precompile takes a uint16 id, so a wider id would silently
            // alias an UNRELATED market in every flatness/verification read — orders to
            // one market, custody proofs from another. Support requires the wide
            // position read confirmed on the funded venue first (REPORT.md).
            if (d.perpMarket > type(uint16).max) revert PerpIdUnsupported();
            // Perp px normalization uses `10^(6 − perpSzDecimals)`; > 6 would underflow.
            if (d.perpSzDecimals > 6) revert PerpMismatch();
            CoreTypes.PerpAssetInfo memory p = CoreReader.perpAssetInfo(d.perpMarket);
            if (p.onlyIsolated) revert PerpNotCrossMarginable();
            if (
                p.szDecimals != d.perpSzDecimals || p.maxLeverage != d.perpMaxLeverage
                    || p.maxLeverage == 0
            ) revert PerpMismatch();
        } else {
            // Spot-only descriptor: the perp fields are inert and MUST be zeroed so no
            // future path can dereference a stale szDecimals/leverage into an underflow.
            if (d.perpSzDecimals != 0 || d.perpMaxLeverage != 0) revert PerpMismatch();
        }
    }

    function verifySettlement(CoreTypes.AssetDescriptor memory s) internal view {
        if (!s.fixedUsd) revert BadSettlement();
        _verifyToken(s);
    }

    function _verifyToken(CoreTypes.AssetDescriptor memory d) private view {
        // The token-info precompile takes a uint32 id; a wider coreToken would verify
        // against the ALIASED token (id mod 2³²) while spot balance/send use the full
        // width — reject at binding, symmetric with the perp-id guard.
        if (d.coreToken > type(uint32).max) revert TokenMismatch();
        // Decimal-spread sanity (V3-VENUE-2): a live lot is ≥ 1 wei so szDecimals ≤
        // weiDecimals always, and the wei/EVM spread is small — but a venue-impossible
        // descriptor (szDecimals > weiDecimals, or a >30 decimal spread) would panic the
        // `10 ** (…)` exponents in the engine's unit conversions. Reject at binding.
        if (d.spotSzDecimals > d.coreWeiDecimals) revert DecimalsMismatch();
        uint256 spread = d.evmDecimals >= d.coreWeiDecimals
            ? d.evmDecimals - d.coreWeiDecimals
            : d.coreWeiDecimals - d.evmDecimals;
        if (spread > 30) revert DecimalsMismatch();
        CoreTypes.TokenInfo memory t = CoreReader.tokenInfo(d.coreToken);
        if (t.evmContract != d.evmToken) revert TokenMismatch();
        int256 extra = int256(uint256(d.evmDecimals)) - int256(uint256(d.coreWeiDecimals));
        if (
            t.weiDecimals != d.coreWeiDecimals || t.szDecimals != d.spotSzDecimals
                || int256(t.evmExtraWeiDecimals) != extra
        ) revert DecimalsMismatch();
    }

    // ------------------------------------------------------------------ unit conversion

    /// @notice EVM token units → Core wei units (floor), clamped to uint64. A raw
    ///         truncating cast would wrap mod 2⁶⁴ for a value above the ceiling and
    ///         mis-size a fund; clamping caps the chunk and the delta-measured engine
    ///         re-derives across cranks (V3-ACCT-2).
    function evmToCore(CoreTypes.AssetDescriptor memory d, uint256 evmAmount)
        internal
        pure
        returns (uint64)
    {
        uint256 v = d.evmDecimals >= d.coreWeiDecimals
            ? evmAmount / 10 ** (d.evmDecimals - d.coreWeiDecimals)
            : evmAmount * 10 ** (d.coreWeiDecimals - d.evmDecimals);
        return v > type(uint64).max ? type(uint64).max : uint64(v);
    }

    /// @notice Core wei units → EVM token units (floor).
    function coreToEvm(CoreTypes.AssetDescriptor memory d, uint64 weiAmount)
        internal
        pure
        returns (uint256)
    {
        if (d.evmDecimals >= d.coreWeiDecimals) {
            return uint256(weiAmount) * 10 ** (d.evmDecimals - d.coreWeiDecimals);
        }
        return uint256(weiAmount) / 10 ** (d.coreWeiDecimals - d.evmDecimals);
    }
}
