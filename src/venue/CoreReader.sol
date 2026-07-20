// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CoreTypes} from "./CoreTypes.sol";
import {Phi} from "../libraries/Phi.sol";

/// @title CoreReader — staticcall wrappers over the HyperCore read precompiles.
/// @notice Every async completion proof reads through here (HAZARDS A1/A2). Precompile
///         gas costs and exact live ABI are funded gates (SECURITY_MODEL §5.15).
library CoreReader {
    error PrecompileFailed();

    function _read(address precompile, bytes memory callData) private view returns (bytes memory) {
        (bool ok, bytes memory result) = precompile.staticcall(callData);
        if (!ok) revert PrecompileFailed();
        return result;
    }

    function position(address user, uint32 perp) internal view returns (CoreTypes.Position memory) {
        return abi.decode(
            _read(CoreTypes.PRECOMPILE_POSITION, abi.encode(user, uint16(perp))),
            (CoreTypes.Position)
        );
    }

    /// @notice Core spot balance — the RELIABLE balance: decreased only by our own
    ///         actions; external transfers can only add (HAZARDS A2).
    function spotBalance(address user, uint64 token) internal view returns (uint64) {
        CoreTypes.SpotBalance memory b = abi.decode(
            _read(CoreTypes.PRECOMPILE_SPOT_BALANCE, abi.encode(user, token)),
            (CoreTypes.SpotBalance)
        );
        return b.total;
    }

    /// @notice Perp withdrawable — PnL-driven and externally toppable. MUST NEVER be a
    ///         completion or retry counter (HAZARDS A2); used only to SIZE clamps and to
    ///         reconcile/measure surplus.
    function withdrawable(address user) internal view returns (uint64) {
        return abi.decode(_read(CoreTypes.PRECOMPILE_WITHDRAWABLE, abi.encode(user)), (uint64));
    }

    function markPx(uint32 perp) internal view returns (uint64) {
        return abi.decode(_read(CoreTypes.PRECOMPILE_MARK_PX, abi.encode(perp)), (uint64));
    }

    function oraclePx(uint32 perp) internal view returns (uint64) {
        return abi.decode(_read(CoreTypes.PRECOMPILE_ORACLE_PX, abi.encode(perp)), (uint64));
    }

    function spotPx(uint32 spotMarket) internal view returns (uint64) {
        return abi.decode(_read(CoreTypes.PRECOMPILE_SPOT_PX, abi.encode(spotMarket)), (uint64));
    }

    function perpAssetInfo(uint32 perp) internal view returns (CoreTypes.PerpAssetInfo memory) {
        return abi.decode(
            _read(CoreTypes.PRECOMPILE_PERP_ASSET_INFO, abi.encode(perp)), (CoreTypes.PerpAssetInfo)
        );
    }

    function spotInfo(uint32 spotMarket) internal view returns (CoreTypes.SpotInfo memory) {
        return abi.decode(
            _read(CoreTypes.PRECOMPILE_SPOT_INFO, abi.encode(spotMarket)), (CoreTypes.SpotInfo)
        );
    }

    function tokenInfo(uint64 token) internal view returns (CoreTypes.TokenInfo memory) {
        return abi.decode(
            _read(CoreTypes.PRECOMPILE_TOKEN_INFO, abi.encode(uint32(token))), (CoreTypes.TokenInfo)
        );
    }

    function coreUserExists(address user) internal view returns (bool) {
        return abi.decode(_read(CoreTypes.PRECOMPILE_CORE_USER_EXISTS, abi.encode(user)), (bool));
    }

    // ------------------------------------------------------------------ price normalization

    /// @notice Spot price → WAD USD per whole token. Spot px has (8 − szDecimals) decimals.
    function spotPxWad(CoreTypes.AssetDescriptor memory d) internal view returns (uint256) {
        uint256 raw = spotPx(d.spotMarket);
        return Phi.mulDiv(raw, Phi.WAD, 10 ** (8 - d.spotSzDecimals));
    }

    /// @notice Perp mark/oracle price → WAD USD. Perp px has (6 − szDecimals) decimals.
    function perpPxWad(CoreTypes.AssetDescriptor memory d, bool mark)
        internal
        view
        returns (uint256)
    {
        uint256 raw = mark ? markPx(d.perpMarket) : oraclePx(d.perpMarket);
        return Phi.mulDiv(raw, Phi.WAD, 10 ** (6 - d.perpSzDecimals));
    }
}
