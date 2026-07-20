// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CoreTypes} from "./CoreTypes.sol";

interface ICoreWriter {
    function sendRawAction(bytes calldata data) external;
}

/// @title CoreWriterLib — HyperCore action encoding and emission.
/// @notice Emitting an action is NOT evidence it executed (HAZARDS A1); every caller must
///         prove the effect with a later CoreReader state read. Encoding per public docs;
///         live encoding correctness is a funded gate (SECURITY_MODEL §5.4–5).
library CoreWriterLib {
    function _send(uint24 actionId, bytes memory args) private {
        ICoreWriter(CoreTypes.CORE_WRITER)
            .sendRawAction(abi.encodePacked(CoreTypes.ACTION_VERSION, actionId, args));
    }

    /// @notice One IOC limit order. `limitPx` and `sz` are FIXED-POINT 1e8 (human value
    ///         × 10⁸) per the CoreWriter action convention — deliberately different from
    ///         the szDecimals-scaled precompile READ conventions; callers convert.
    ///         Zero-size orders MUST NOT be sent (SPEC §7) — callers guard; this reverts
    ///         as defense in depth.
    function iocOrder(uint32 asset, bool isBuy, uint64 limitPx, uint64 sz, bool reduceOnly)
        internal
    {
        require(sz != 0, "zero-size order");
        _send(
            CoreTypes.ACTION_LIMIT_ORDER,
            abi.encode(asset, isBuy, limitPx, sz, reduceOnly, CoreTypes.TIF_IOC, uint128(0))
        );
    }

    /// @notice Core-spot → destination transfer. Destination = the token's system address
    ///         moves Core → EVM (credits our own EVM address); it has a debit-then-deliver
    ///         window and MUST NOT be resent once the source decreased (HAZARDS A7).
    function spotSend(address destination, uint64 token, uint64 weiAmount) internal {
        _send(CoreTypes.ACTION_SPOT_SEND, abi.encode(destination, token, weiAmount));
    }

    /// @notice USDC between spot and perp accounts (intra-Core; assumed atomic — funded
    ///         gate). `ntl` is 1e6 USD.
    function usdClassTransfer(uint64 ntl, bool toPerp) internal {
        _send(CoreTypes.ACTION_USD_CLASS_TRANSFER, abi.encode(ntl, toPerp));
    }
}
