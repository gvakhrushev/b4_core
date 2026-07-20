// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title SafeTransfer — minimal ERC20 transfer helpers tolerating missing return data.
/// @dev Directional assets are required to be plain ERC20s (SECURITY_MODEL §4 excludes
///      rebasing/fee-on-transfer); this wrapper normalizes the bool-return quirk AND
///      malformed return data: a successful call returning junk bytes must degrade to a
///      soft failure, never an abi.decode revert — the fail-soft claim paths (HAZARDS D5)
///      and the pay-or-defer payout path rely on tryTransfer being revert-free.
library SafeTransfer {
    error TransferFailed();

    function safeTransfer(address token, address to, uint256 amount) internal {
        if (!_call(token, abi.encodeWithSelector(0xa9059cbb, to, amount))) {
            revert TransferFailed();
        }
    }

    function safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        if (!_call(token, abi.encodeWithSelector(0x23b872dd, from, to, amount))) {
            revert TransferFailed();
        }
    }

    /// @notice Non-reverting variant for per-token retryable claims (HAZARDS D5) and
    ///         deferred payouts. NEVER reverts, whatever the token returns.
    function tryTransfer(address token, address to, uint256 amount) internal returns (bool) {
        return _call(token, abi.encodeWithSelector(0xa9059cbb, to, amount));
    }

    /// @dev Success = call succeeded on a contract AND the return data is either empty
    ///      (Tether style) or a canonical ABI-encoded `true` (a 32-byte word equal to 1).
    ///      Anything else — a short buffer, a zero/false word, a non-canonical truthy
    ///      word, or a call that reverted — is treated as failure WITHOUT reverting.
    ///      The return-data copy is capped at 32 bytes so a "return bomb" (huge
    ///      returndatasize) can never OOG the caller: `tryTransfer` is unconditionally
    ///      revert-free, which the D5 fail-soft claim path and pay-or-defer rely on.
    function _call(address token, bytes memory data) private returns (bool) {
        if (token.code.length == 0) return false;
        bool ok;
        uint256 rds;
        uint256 word;
        assembly {
            // Cap forwarded gas: a hostile token that burns all forwarded gas would
            // otherwise (EIP-150 63/64) let a few basket entries exhaust a claim/capture
            // loop and defeat per-token isolation (V3-POOL-1). 500k ≫ any real ERC20
            // transfer; an over-cap token degrades to the fail-soft path (defer/revert).
            let g := gas()
            if gt(g, 500000) { g := 500000 }
            ok := call(g, token, 0, add(data, 0x20), mload(data), 0x00, 0x20)
            rds := returndatasize()
            word := mload(0x00) // only the first 32 bytes were copied into scratch
        }
        if (!ok) return false;
        if (rds == 0) return true; // no-return-value token: success on a non-reverting call
        if (rds < 32) return false; // malformed short buffer
        return word == 1; // canonical ABI `true`
    }
}
