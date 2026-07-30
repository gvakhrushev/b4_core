// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {B4VaultEngine} from "./B4VaultEngine.sol";
import {Phi} from "../libraries/Phi.sol";
import {SafeTransfer} from "../libraries/SafeTransfer.sol";
import {CoreTypes} from "../venue/CoreTypes.sol";
import {CoreWriterLib} from "../venue/CoreWriterLib.sol";
import {IERC20} from "../interfaces/IERC20.sol";

/// @title B4VaultRecovery — cold-path module: owner surplus recovery and deferred payouts.
/// @notice Second delegatecall module, split out of `B4VaultOps` because that contract had
///         fallen to ~90 spare bytes and both it and `B4Vault` inherit `B4VaultEngine`, so
///         every engine byte is paid twice and accepted audit fixes could no longer land
///         (`docs/audits/REMEDIATION-2026-07-25.md`). Recovery and deferred payouts are the
///         cold path — owner-initiated, never on the crank — so they are what moves.
///
///         Same rules as `B4VaultOps`: reached ONLY by delegatecall from B4Vault, same
///         inherited storage layout, no extra state, address fixed as an immutable of the
///         vault implementation at deployment. Code organization to satisfy EIP-170, not an
///         upgrade path: nothing can ever repoint it (F1). Direct calls operate on this
///         contract's own empty storage and revert on the _initialized guard.
contract B4VaultRecovery is B4VaultEngine {
    using SafeTransfer for address;

    error NotDelegated();

    modifier onlyInitialized() {
        if (!_initialized) revert NotDelegated();
        _;
    }

    /// @notice Retry a deferred payout — permissionless; pays only the recorded
    ///         recipient (F2). Reverts if the transfer still fails (retryable).
    function opsClaimDeferred(address recipient, address token) external onlyInitialized {
        uint256 amount = deferredPayout[recipient][token];
        if (amount == 0) revert NothingToRecover();
        deferredPayout[recipient][token] = 0;
        deferredPayoutTotal[token] -= amount;
        token.safeTransfer(recipient, amount); // revert rolls the clearing back
        emit DeferredPayoutClaimed(recipient, token, amount);
    }

    // ================================================================= recovery (B6)

    /// @notice Recover unaccounted EVM assets to the owner. For the two accounted tokens
    ///         this requires an idle engine (an in-flight return could otherwise be
    ///         siphoned mid-delivery).
    function opsRecoverEvm(address token) external onlyInitialized {
        uint256 excess;
        uint256 bal = IERC20(token).balanceOf(address(this));
        // Deferred payouts are accounted value owed to their recipients — never
        // recoverable as "unaccounted" surplus.
        uint256 deferred = deferredPayoutTotal[token];
        if (token == _dir.evmToken) {
            _requireIdle();
            excess = bal - Phi.min(dirEvm + deferred, bal);
        } else if (token == _usdc.evmToken) {
            _requireIdle();
            uint256 accounted = usdcRotatedEvm + usdcMarginEvm + deferred;
            excess = bal - Phi.min(accounted, bal);
        } else {
            excess = bal - Phi.min(deferred, bal);
        }
        if (excess == 0) revert NothingToRecover();
        token.safeTransfer(owner, excess);
        emit UnaccountedEvmRecovered(token, excess);
    }

    /// @notice Recover Core spot balance above recorded principal — bounded, flat/idle,
    ///         no accounting callback (B6). Works with zero recorded principal.
    function opsRecoverCoreSpot(bool dirToken) external onlyInitialized {
        _requireIdleFlat();
        CoreTypes.AssetDescriptor memory d = dirToken ? _dir : _usdc;
        uint64 bal = _spotBal(d.coreToken);
        uint64 recorded = dirToken ? coreDirWei : coreUsdcRotatedWei + coreUsdcMarginWei;
        if (bal <= recorded) revert NothingToRecover();
        _startRecoverySpot(
            dirToken ? IntentKind.RecoverSpotDir : IntentKind.RecoverSpotUsdc, bal - recorded
        );
    }

    /// @notice Recover perp withdrawable above (margin principal + any outstanding harvest
    ///         claim) — two-phase perp→spot→EVM→owner. The pending harvest claim is a
    ///         RECORDED intent to route realized perp PnL into the taxed strategy ledger
    ///         (bearing the operator/referrer performance fee, decision C1). It must be
    ///         reserved here: only genuine funding surplus above margin AND the claim is
    ///         the owner's untaxed recoverable surplus. Reserving (not gating on)
    ///         pendingHarvest6 preserves A5 — the planner still settles the claim normally.
    function opsRecoverPerpSurplus() external onlyInitialized {
        _requireIdleFlat();
        _reconcile(); // honest surplus: losses written down first
        uint64 wd = _wd();
        uint256 reserved = uint256(perpMargin6) + pendingHarvest6;
        if (wd <= reserved) revert NothingToRecover();
        uint64 surplus6 = uint64(wd - reserved);
        _snapshotBase(IntentKind.RecoverPerpPhase1, Purpose.Generic, surplus6);
        intent.snapSrcWei = _spotBal(_usdc.coreToken);
        CoreWriterLib.usdClassTransfer(surplus6, false);
    }

    function _requireIdleFlat() internal view {
        _requireIdle();
        if (exitShareWad != 0) revert ExitPending();
        // Strict custody flatness: raw position exactly zero (A10), never an epsilon.
        if (_position().szi != 0) revert NotFlat();
    }
}
