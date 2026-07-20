// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {B4VaultEngine} from "./B4VaultEngine.sol";
import {Phi} from "../libraries/Phi.sol";
import {Calendar} from "../libraries/Calendar.sol";
import {SafeTransfer} from "../libraries/SafeTransfer.sol";
import {CoreTypes} from "../venue/CoreTypes.sol";
import {CoreWriterLib} from "../venue/CoreWriterLib.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IHalvingOracle} from "../interfaces/IHalvingOracle.sol";

interface IB4PoolVault {
    function reportWeight(uint256 id, uint256 weight) external;
    function reportDeadline(uint256 id) external view returns (uint256);
    function intervalInfo(uint256 id)
        external
        view
        returns (uint64 pointTime, uint64 lockedAt, bool swept, uint256 totalWeight);
    function lockedPxWad(uint256 id, uint256 assetIndex) external view returns (uint256);
    function capture() external;
}

/// @title B4VaultOps — settle / exit-finalize / recovery module.
/// @notice Reached ONLY by delegatecall from B4Vault (same inherited storage layout, no
///         extra state). The module address is an immutable of the vault implementation,
///         fixed at deployment — this is code organization to satisfy EIP-170, not an
///         upgrade path: nothing can ever repoint it (F1). Direct calls operate on this
///         contract's own empty storage and revert on the _initialized guard.
contract B4VaultOps is B4VaultEngine {
    using SafeTransfer for address;

    error NotDelegated();

    modifier onlyInitialized() {
        if (!_initialized) revert NotDelegated();
        _;
    }

    // ================================================================= settle

    /// @notice SPEC §8: checkpoint-priced NAV, wrong-sign rejection, reconcile before
    ///         valuation (B2), operator cut paid in kind from the EVM basket, one weight
    ///         report per interval.
    function opsSettle(uint256 intervalId) external onlyInitialized {
        if (exitShareWad != 0) revert ExitPending();
        // Settle values NAV and IRREVERSIBLY pays the operator fee + reports weight, so it
        // MUST see a settled ledger: require an idle engine. An in-flight leg completes
        // within RESEND_TIMEOUT (~1h) ≪ the report window (>2 days), so a keeper always
        // reaches idle in time; only an ecosystem-wide venue failure could stall an intent
        // past the window, which is a documented liveness residual (H3), not custody.
        _requireIdle();
        if (intervalId + 1 <= lastSettledPlusOne) revert AlreadySettled();
        (, uint64 lockedAt,,) = IB4PoolVault(pool).intervalInfo(intervalId);
        if (lockedAt == 0 || block.timestamp > IB4PoolVault(pool).reportDeadline(intervalId)) {
            revert NotSettleable();
        }
        // Still-wrong-sign perp for the interval: the previous regime's exposure must
        // pass through a verified zero before the interval can settle.
        CoreTypes.Position memory pos = _position();
        if (pos.szi != 0) {
            (, int256 perpF) = Calendar.decompose(_currentTarget());
            if (perpF == 0 || (pos.szi > 0) != (perpF > 0)) revert WrongSignPerp();
        }
        _reconcile();

        uint256 pxWad = IB4PoolVault(pool).lockedPxWad(intervalId, _dirAssetIndex);
        // Idle ⇒ every in-flight leg has credited its bucket; NAV is exact.
        uint256 nav = _navWad(pxWad);
        uint256 e = entryLedgerWad;
        uint256 profit = nav > e ? nav - e : 0;
        uint256 virtualFee = Phi.wmul(profit, Phi.FEE_F);
        uint256 operatorCut = Phi.bps(virtualFee, route.operatorBps);
        uint256 clientShare = virtualFee - operatorCut;

        // The operator cut is paid IN KIND from the EVM basket. An idle-but-not-repatriated
        // vault (value still on Core) has an empty basket, so settle would waive the cut
        // yet still re-anchor the entry and report the FULL client weight — a fee dodge +
        // pool-weight-integrity break (V3-ACCT-1). Require the basket to cover the cut,
        // forcing repatriation first (steady-state custody is EVM). Since the cut is
        // ≤ ~1.72% of profit, a properly-cranked vault always passes; a stuck vault that
        // misses its report window makes the interval unreportable (liveness, not custody).
        if (operatorCut > 0 && _evmBasketWad(pxWad) < operatorCut) revert FeeNotRepatriated();

        // Effect first: mark the interval settled before the external reportWeight call
        // (checks-effects-interactions; the vault's settle guard already blocks reentry).
        lastSettledPlusOne = intervalId + 1;
        uint256 paidVal = _payOperatorInKind(operatorCut, pxWad);
        entryLedgerWad = nav - paidVal;
        rewardBaseWad += clientShare;
        if (rewardBaseWad > 0) {
            IB4PoolVault(pool).reportWeight(intervalId, rewardBaseWad);
        }
        emit Settled(intervalId, nav, profit, paidVal);
    }

    /// @dev Pay `valueWad` of operator fee in kind, proportionally from the accounted EVM
    ///      basket (dir at `pxWad`, USDC at 1). Returns the value actually paid (capped by
    ///      the basket; floors favor the protocol, B5).
    /// @dev WAD value of the accounted EVM basket (dir at `pxWad`, USDC at 1) — the source
    ///      the operator cut is paid from.
    function _evmBasketWad(uint256 pxWad) internal view returns (uint256) {
        return Phi.wmul(_toWad(dirEvm, _dir.evmDecimals), pxWad)
            + _toWad(usdcRotatedEvm, _usdc.evmDecimals) + _toWad(usdcMarginEvm, _usdc.evmDecimals);
    }

    function _payOperatorInKind(uint256 valueWad, uint256 pxWad) internal returns (uint256) {
        if (valueWad == 0 || route.operator == address(0)) return 0;
        uint256 basketWad = _evmBasketWad(pxWad);
        if (basketWad == 0) return 0;
        uint256 payWad = Phi.min(valueWad, basketWad);

        uint256 dirPay = Phi.mulDiv(dirEvm, payWad, basketWad);
        uint256 rotPay = Phi.mulDiv(usdcRotatedEvm, payWad, basketWad);
        uint256 marPay = Phi.mulDiv(usdcMarginEvm, payWad, basketWad);
        dirEvm -= dirPay;
        usdcRotatedEvm -= rotPay;
        usdcMarginEvm -= marPay;
        _routeFee(_dir.evmToken, dirPay);
        _routeFee(_usdc.evmToken, rotPay + marPay);
        emit FeePaid(route.operator, payWad, route.referrer);
        return payWad;
    }

    /// @dev The referral is carved only from the operator payment (SPEC §2).
    function _routeFee(address token, uint256 amount) internal {
        if (amount == 0) return;
        uint256 refShare = route.referrer == address(0) ? 0 : Phi.bps(amount, route.referrerBps);
        if (refShare > 0) _payOut(token, route.referrer, refShare);
        if (amount - refShare > 0) _payOut(token, route.operator, amount - refShare);
    }

    /// @dev Pay-or-defer: a recipient whose transfer fails (e.g. USDC blacklist) must
    ///      never freeze settle/exit (H3). The amount stays accounted as a deferred
    ///      payout, retryable permissionlessly via claimDeferred, and is excluded from
    ///      unaccounted-EVM recovery so the owner cannot sweep it.
    function _payOut(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (!token.tryTransfer(to, amount)) {
            deferredPayout[to][token] += amount;
            deferredPayoutTotal[token] += amount;
            emit PayoutDeferred(to, token, amount);
        }
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

    // ================================================================= planners

    /// @notice One planning step under the crank: exit machine if an exit is pending,
    ///         else one sync step toward the time-derived target.
    function opsPlanStep() external onlyInitialized returns (bool) {
        if (exitShareWad != 0) return _planExitStep();
        return _planSyncStep();
    }

    /// @dev One exit step: flatten to raw zero → harvest → reconcile → return all Core
    ///      principal → finalize. Strict flatness everywhere (A10); driven by the LIVE
    ///      position, resubmitting on partial fills (SPEC §9).
    function _planExitStep() internal returns (bool) {
        CoreTypes.Position memory pos = _position();
        if (pos.szi != 0) {
            _startPerpOrder(pos.szi < 0, uint64(Phi.abs(pos.szi)), true);
            return true;
        }
        if (pendingHarvest6 > 0) {
            _startFromPerp(Purpose.Harvest, 0);
            return true;
        }
        _reconcile();
        if (perpMargin6 > 0) {
            _startFromPerp(Purpose.Margin, perpMargin6);
            return true;
        }
        if (coreUsdcRotatedWei > 0) {
            _startReturn(false, Purpose.Generic, coreUsdcRotatedWei);
            return true;
        }
        if (coreUsdcMarginWei > 0) {
            _startReturn(false, Purpose.Margin, coreUsdcMarginWei);
            return true;
        }
        if (coreDirWei > 0) {
            _startReturn(true, Purpose.Generic, coreDirWei);
            return true;
        }
        _finalizeExit();
        return true;
    }

    // ================================================================= exit finalize

    struct ExitSplit {
        uint256 grossWad;
        uint256 ownerWad;
        uint256 operatorWad;
        uint256 poolWad;
        bool free;
    }

    /// @notice Final exit step, reached only after the perp is strictly flat, PnL is
    ///         harvested, loss reconciled and ALL Core principal returned (SPEC §9).
    function _finalizeExit() internal {
        uint256 x = exitShareWad;
        if (x == 0) revert NoExitPending();
        uint256 pxWad = _livePxWad(); // live oracle valuation (decision C2)
        uint256 nav = _navWad(pxWad);
        uint256 e = entryLedgerWad;
        uint256 profit = nav > e ? nav - e : 0;
        uint256 virtualFee = Phi.wmul(profit, Phi.FEE_F);
        uint256 operatorCut = Phi.bps(virtualFee, route.operatorBps);
        uint256 clientShare = virtualFee - operatorCut;

        ExitSplit memory s;
        s.grossWad = Phi.wmul(nav, x);
        uint256 ocx = Phi.wmul(operatorCut, x);
        s.free = Calendar.freeExit(IHalvingOracle(oracle).timeSinceHalving());
        if (s.free) {
            s.operatorWad = ocx;
            s.ownerWad = s.grossWad - ocx;
        } else {
            // One in-kind penalty; the operator payment is carved from it, never added.
            uint256 penalty = Phi.wmul(s.grossWad, Phi.EXIT_Q);
            s.operatorWad = Phi.min(ocx, penalty);
            s.poolWad = penalty - s.operatorWad;
            s.ownerWad = s.grossWad - penalty;
        }

        // Effects before interactions (checks-effects-interactions): the ledger writes
        // are independent of the transfer results (buckets are separate storage), so
        // committing them first is behavior-identical and adds defense-in-depth beyond
        // the vault's crank-level nonReentrant guard.
        // Ledger (SPEC §9): nextEntry = E·(1−x); nextRewardBase = (R + C·x)·(1−x), where
        // C = virtualFee − operatorCut is the full-position client share, so C·x is the
        // EXITING share's client share — symmetric with the proportional operator cut.
        // The remaining share's open profit settles at the next checkpoint (entry is
        // scaled, not re-anchored), so each share's profit earns client share exactly
        // once and repeated partial exits can never mint or duplicate weight.
        uint256 keep = Phi.WAD - x;
        entryLedgerWad = Phi.wmul(e, keep);
        rewardBaseWad = Phi.wmul(rewardBaseWad + Phi.wmul(clientShare, x), keep);
        exitShareWad = 0;

        // Interactions: pay each accounted bucket's share in kind, then push the penalty
        // into the pool.
        if (s.grossWad > 0) {
            dirEvm = _payBucket(_dir.evmToken, dirEvm, x, s);
            usdcRotatedEvm = _payBucket(_usdc.evmToken, usdcRotatedEvm, x, s);
            usdcMarginEvm = _payBucket(_usdc.evmToken, usdcMarginEvm, x, s);
            // Penalty tokens have already been transferred to the pool by _payBucket;
            // capture() only ACCOUNTS them. try/catch so a griefing co-asset in the pool
            // can never freeze this exit (V3-POOL-1) — the penalty is safe in the pool and
            // any keeper capture() re-accounts it later.
            if (s.poolWad > 0) {
                try IB4PoolVault(pool).capture() {} catch {}
            }
        }

        emit ExitFinalized(
            x, s.grossWad, s.ownerWad, s.grossWad - s.ownerWad - s.operatorWad, s.free
        );
    }

    /// @dev Pay one accounted bucket's share x, split in kind by value ratios; flooring
    ///      dust stays accounted with the remaining vault (B5). Returns the new bucket.
    function _payBucket(address token, uint256 bucket, uint256 x, ExitSplit memory s)
        internal
        returns (uint256)
    {
        uint256 out = Phi.wmul(bucket, x);
        if (out == 0) return bucket;
        uint256 toOwner = Phi.mulDiv(out, s.ownerWad, s.grossWad);
        uint256 toOperator = Phi.mulDiv(out, s.operatorWad, s.grossWad);
        uint256 toPool = Phi.mulDiv(out, s.poolWad, s.grossWad);
        _payOut(token, owner, toOwner);
        _routeFee(token, toOperator);
        _payOut(token, pool, toPool);
        return bucket - toOwner - toOperator - toPool;
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
