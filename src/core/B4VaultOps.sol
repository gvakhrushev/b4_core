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
import {IStrategy} from "../interfaces/IStrategy.sol";
import {IB4PoolPolicy} from "../interfaces/IB4PoolPolicy.sol";

interface IB4PoolVault {
    function reportWeight(uint256 id, uint256 weight) external;
    function scaleWeight(uint256 id, uint256 keepWad) external;
    function reportDeadline(uint256 id) external view returns (uint256);
    function intervalInfo(uint256 id)
        external
        view
        returns (uint64 pointTime, uint64 lockedAt, bool swept, uint256 totalWeight);
    function lockedPxWad(uint256 id, uint256 assetIndex) external view returns (uint256);
    function capturePenalty() external;
    function beginPenalty() external;
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

    // ================================================================= policy

    /// @notice Read a strategy once, then bind its resolved targets.  A configured
    ///         pool validates the exact canonical strategy pair, scale and direction of
    ///         the product transition before any vault state changes.
    function opsSelectPolicy(address strategy, uint256 scaleWad) external onlyInitialized {
        // Re-targeting mutates growth/fall; a leg already in flight was planned against the OLD
        // target and would verify against the new one. Require idle. `targets()` is an external
        // call to a not-yet-validated strategy address, so the entry (B4Vault.selectPolicy)
        // carries `nonReentrant`; this cannot re-enter deposit/crank mid-selection.
        _requireIdle();
        (int256 g, int256 f) = IStrategy(strategy).targets();
        if (!IB4PoolPolicy(pool).policyAllowedForVault(address(this), strategy, g, f, scaleWad)) {
            revert BadPolicy();
        }
        if (scaleWad == 0 || scaleWad > Phi.MAX_SCALE) revert BadPolicy();
        if (Phi.abs(g) > Phi.MAX_BASE_TARGET || Phi.abs(f) > Phi.MAX_BASE_TARGET) {
            revert BadPolicy();
        }
        int256 rg = g * int256(scaleWad) / int256(Phi.WAD);
        int256 rf = f * int256(scaleWad) / int256(Phi.WAD);
        if (Phi.abs(rg) > Phi.PHI || Phi.abs(rf) > Phi.PHI) revert BadPolicy();
        growthTarget = rg;
        fallTarget = rf;
        IB4PoolPolicy(pool).setVaultPolicy(IB4PoolPolicy(pool).policyIdForStrategy(strategy));
        emit PolicySelected(strategy, rg, rf, scaleWad);
    }

    // ================================================================= settlement snapshot

    /// @notice Capture the interval's valuation instant — permissionless, one-shot, and confined
    ///         to the settlement day (`Calendar.SNAPSHOT_WINDOW`).
    /// @dev AUDIT-2026-07-29 F4. Settlement is one-shot per interval and used to value the vault
    ///      at the price of the instant `settle` ran, anywhere in the 3-day report window — so a
    ///      third party picked the valuation instant for a vault it did not own, pinned that
    ///      vault's minted weight at a trough, and the owner had no second attempt. The
    ///      mitigation the `Calendar` docstring records for `lockPrices` ("the harmed party can
    ///      call it at `pointTime` and remove all discretion") had stopped applying, because
    ///      since C-1 the locked price feeds no valuation and the discretion had moved here.
    ///
    ///      Separating the valuation instant from the report restores it: the owner takes this at
    ///      `pointTime` and there is nothing left for a front-runner to choose. It narrows the
    ///      choosable span from three days to one, and reporting liveness is untouched — the
    ///      weight report still has until `reportDeadline`, and the ordinary keeper path is still
    ///      a single `settle` call, which captures the snapshot itself when it runs inside the
    ///      window.
    ///
    ///      Deliberately NOT gated on the wrong-sign check that `opsSettle` applies: NAV is
    ///      well-defined whatever the position's sign, and requiring flatness here would deny the
    ///      owner the pre-emption at `pointTime` exactly when the crank has not finished closing
    ///      — which is the moment the pre-emption matters most. Settle still enforces it.
    ///      Idle IS required: only then has every in-flight leg credited its bucket, so NAV is
    ///      exact (B2).
    function opsSnapshotNav(uint256 intervalId) external onlyInitialized {
        if (exitShareWad != 0) revert ExitPending();
        _requireIdle();
        if (intervalId + 1 <= lastSettledPlusOne) revert AlreadySettled();
        if (settleNavIdPlusOne == intervalId + 1) revert AlreadySettled(); // one-shot
        (uint64 pointTime, uint64 lockedAt,,) = IB4PoolVault(pool).intervalInfo(intervalId);
        if (lockedAt == 0) revert NotSettleable();
        if (
            block.timestamp < pointTime
                || block.timestamp > uint256(pointTime) + Calendar.SNAPSHOT_WINDOW
        ) revert OutsideSnapshotWindow();
        _reconcile();
        _captureNav(intervalId);
    }

    /// @dev Measure and store the interval's NAV and the price it was measured at, together, at
    ///      this instant. Storing the price is what lets settle pay the in-kind operator cut on
    ///      the same basis the NAV was taken on when it runs a day later; using the live price
    ///      there against a day-old NAV would re-create the C-1 mismatch in miniature.
    function _captureNav(uint256 intervalId) internal returns (uint256 pxWad) {
        pxWad = _livePxWad();
        if (pxWad == 0) revert ZeroPrice();
        uint256 nav = _navWad(pxWad);
        settleNavWad = nav;
        _settleNavPxWad = pxWad;
        settleNavIdPlusOne = intervalId + 1;
        emit SettleNavSnapshotted(intervalId, nav, pxWad);
    }

    /// @dev The valuation basis for `opsSettle`: reuse the captured snapshot, or capture it now if
    ///      settle is still inside the settlement day. Past the window with nothing captured the
    ///      interval simply defers, which is the documented cost of missing the snapshot window
    ///      for `lockPrices` too — deferral (~0.94–1.5 years), never destruction.
    function _snapshotNav(uint256 intervalId) internal returns (uint256) {
        if (settleNavIdPlusOne == intervalId + 1) return _settleNavPxWad;
        (uint64 pointTime,,,) = IB4PoolVault(pool).intervalInfo(intervalId);
        if (block.timestamp > uint256(pointTime) + Calendar.SNAPSHOT_WINDOW) {
            revert NavNotSnapshotted();
        }
        return _captureNav(intervalId);
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

        // Value the composition and the price TOGETHER, at one instant (audit C-1). Valuing the
        // current composition at the interval's locked checkpoint price instead — a price up to
        // 3 days old — was the defect: `_navWad` reads composition at call time, so every
        // composition change inside the report window was measured against a stale reference and
        // the gap read as interval profit no capital earned. The window is exactly when the
        // calendar MANDATES a change (`Calendar.targetAt` is 0 at the point and ramps immediately
        // after, so a flattening product sells and a spot product buys), and `deposit` and
        // `crank` are both reachable there — so no deposit-side rule can close it: only a shared
        // basis can. `_finalizeExit` values at the live price of its own instant (C2), the same
        // kind of basis, so settle and exit still agree; while they disagreed, the gap between
        // them was itself harvestable.
        //
        // WHICH instant is no longer the settle caller's choice (AUDIT-2026-07-29 F4). It is the
        // one-shot snapshot below, confined to the settlement day, which the owner can take at
        // `pointTime` to remove all discretion. Settle itself may still take it when it runs
        // inside that window — the common keeper path, one call as before — but past the window
        // it must use what was captured, or defer the interval.
        uint256 pxWad = _snapshotNav(intervalId);
        // Idle ⇒ every in-flight leg has credited its bucket; NAV is exact.
        //
        // Capped by what the books say the vault holds NOW, valued at the SAME frozen price.
        // Freezing a NAV promises the interval is valued at one instant, which makes it wrong the
        // moment the vault's value moves for a reason that is not the price — and the window is
        // three days long, so several such movers are reachable: a deposit raises the books
        // (A1 keeps the snapshot in step), an exit scales them down (A5 does), and a realized
        // loss lowers them with nothing tracking it at all. The target ramps away from zero right
        // after the settlement point, so the crank re-opens a position and funds margin inside
        // the window; an adverse close there is written down by `_reconcile` while the snapshot
        // still values the vault as it stood before. Measured on the pre-cap tree: live NAV
        // 117,000 against a frozen 120,000, so settle charged a fee and minted pool weight on
        // 3,000 of capital the venue had already taken.
        //
        // The cap is what makes that a closed class rather than a list of patched movers: no
        // future mover can raise the settled NAV above the recorded books, whether or not anyone
        // remembers to hook it. Re-valuing at the LIVE price instead would reopen F4 — the settle
        // caller would choose the price again — so the books are valued at `pxWad`, the instant
        // the snapshot pinned. Only the downward direction is covered here by construction; the
        // upward one still needs its mover to raise the snapshot (A1), because a cap cannot
        // invent value the snapshot never recorded.
        uint256 nav = _navWad(pxWad);
        if (settleNavWad < nav) nav = settleNavWad;
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

    // ================================================================= planners

    /// @notice One planning step under the crank: exit machine if an exit is pending,
    ///         else one sync step toward the time-derived target.
    function opsPlanStep() external onlyInitialized returns (bool) {
        if (exitShareWad != 0) return _planExitStep();
        return _planSyncStep();
    }

    /// @dev Write down spot principal to the real Core spot balance — the spot analogue of
    ///      `_reconcile` (which covers only perp margin). A vault's own spot balance normally
    ///      only GROWS from outside (donations add; nothing external subtracts), so this is a
    ///      no-op on the happy path. But a cross-margin liquidation reaching spot USDC, or a
    ///      partial `spotSend`, can leave a booked bucket ABOVE the real balance; a Return leg
    ///      for that phantom remainder then proves `decreased` yet never reaches
    ///      `received >= evmNeeded` and livelocks the exit while NAV stays overstated (audit
    ///      M-1, second clause). Called only at an idle engine (its callers require it), so any
    ///      gap is a realized loss, not an in-flight leg of our own.
    function _reconcileSpot() internal {
        uint64 dirBal = _spotBal(_dir.coreToken);
        if (coreDirWei > dirBal) {
            emit LossReconciled(coreDirWei - dirBal);
            coreDirWei = dirBal;
        }
        // Rotation and margin USDC share one Core token; funding is headroom-capped so their
        // sum always fits uint64. Compare the SUM to the real balance, absorbing any shortfall
        // from rotation (strategy) first, then margin.
        uint64 rot = coreUsdcRotatedWei;
        uint64 marg = coreUsdcMarginWei;
        uint64 usdcBal = _spotBal(_usdc.coreToken);
        // uint256 sum so this can NEVER revert-on-overflow: a revert here runs on the exit
        // crank and would re-freeze the very exit this heals.
        uint256 booked = uint256(rot) + marg;
        if (booked > usdcBal) {
            uint256 loss = booked - usdcBal;
            uint64 fromRot = loss < rot ? uint64(loss) : rot; // ≤ rot
            coreUsdcRotatedWei = rot - fromRot;
            coreUsdcMarginWei = marg - uint64(loss - fromRot); // loss − fromRot ≤ marg
            emit LossReconciled(uint64(loss));
        }
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
        _reconcileSpot(); // write down spot principal above the real Core balance (audit M-1)
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
        // Propagate: a deferred finalize must report NO progress, or the keeper's burst loop
        // and every bounded crank loop spin forever on a step that changed nothing (A13/L-6).
        return _finalizeExit();
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
    /// @return done false ⇒ no progress this crank; the exit stays pending and retries.
    function _finalizeExit() internal returns (bool done) {
        uint256 x = exitShareWad;
        if (x == 0) revert NoExitPending();
        uint256 pxWad = _livePxWad(); // live oracle valuation (decision C2)
        // A zero read is not a valuation (audit H-3): `grossWad` would be 0, the whole
        // in-kind payment block would be skipped, yet the exit share would be consumed and
        // the entry ledger and reward base scaled by (1−x) — an exit that destroys the
        // ledger and pays nothing. Defer instead. This is a no-progress RETURN, never a
        // revert: `_planExitStep` runs under the permissionless crank, and reverting would
        // take down every other step with it. Deferral only where the price actually
        // matters — a vault holding no directional asset is valued exactly at px 0, so it
        // must still be able to exit during a feed outage. `B4Vault.cancelExit` is the
        // escape if the feed never returns — for a pool-OWNED sleeve (`owner == pool`)
        // that escape is reached through `B4Pool.cancelSleeveExit`, which is gated on the
        // exact complement of this deferral predicate (audit L-1 / INVARIANTS row 20).
        if (pxWad == 0 && dirEvm + coreDirWei != 0) return false;
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
        // Keep a frozen settlement snapshot consistent with the capital that just left — the
        // EXIT-side counterpart of the deposit-side raise in `B4Vault.deposit` (audit A1).
        // `settle` re-anchors `entryLedgerWad` from the frozen `settleNavWad`, and the settlement
        // point sits inside a `freeExit` transition zone, so an exit between `snapshotNav` and
        // `settle` is both reachable and penalty-free. Left stale, the snapshot still values the
        // withdrawn share: `entryLedgerWad` scales by `keep` while the NAV does not, so the
        // exited notional reads as profit. Measured on a 50% exit at a 130k NAV over a 100k
        // entry: settle took 80k of profit where 15k was real — 5.3x — minting pool weight
        // against a shared basket on capital the vault no longer held (INVARIANTS #19, the
        // exit-in-window residual of F4). Scaling by the same `keep` both sides use restores it.
        if (settleNavIdPlusOne > lastSettledPlusOne) {
            settleNavWad = Phi.wmul(settleNavWad, keep);
        }
        // A full exit (`keep == 0`) therefore zeroes the standing base, as SPEC §9 requires.
        // The call-ORDER asymmetry this used to leave — `settle` then `exit` kept the weight
        // already reported to the pool, `exit` then `settle` never reported it — is closed on
        // the POOL side just below, by scaling the reported weight, not by letting the base
        // survive the exit: a vault that has left is a leaver, and the basket is funded by
        // leavers for the benefit of stayers. Keeping a claim while holding no capital inverts
        // that (AUDIT-2026-07-25 C-1 half B).
        //
        // Scaled on EVERY exit that follows a settle, by the SAME `keep` the base above uses —
        // not only on a full one. Weight tracks the capital still standing behind it, so there
        // is no boundary for an exit to sit just above: `initiateExit(WAD − 1)` used to pay out
        // everything but flooring dust and keep 100% of the reported weight, because the pool
        // side tested the exact equality `keep == 0` on a number the owner chooses
        // (AUDIT-2026-07-29 F1). `keep == 0` still forfeits everything, so the full-exit rule
        // is the endpoint of the ramp rather than a special case, and the two sides of the
        // ledger now state one rule instead of two.
        if (lastSettledPlusOne != 0) {
            IB4PoolVault(pool).scaleWeight(lastSettledPlusOne - 1, keep);
        }
        exitShareWad = 0;
        // The exit flattened the perp to szi 0; the frozen structural stop is stale. Clear it so
        // the re-opened kept capital re-derives at the CURRENT price — the fan-out's confirmed
        // CRITICAL (a free partial exit over-levering the re-open at the stale entry) is closed.
        perpStopWad = 0;

        // Interactions: pay each accounted bucket's share in kind, then push the penalty
        // into the pool.
        if (s.grossWad > 0) {
            // Snapshot the pool BEFORE pushing the penalty in, so its capturePenalty
            // escrows the measured receipt of THIS exit rather than every unattributed
            // token sitting there (audit H-1). try/catch for the same reason the capture
            // below is wrapped: a pool-side failure must never freeze an exit.
            if (s.poolWad > 0) {
                try IB4PoolVault(pool).beginPenalty() {} catch {}
            }
            dirEvm = _payBucket(_dir.evmToken, dirEvm, x, s);
            usdcRotatedEvm = _payBucket(_usdc.evmToken, usdcRotatedEvm, x, s);
            usdcMarginEvm = _payBucket(_usdc.evmToken, usdcMarginEvm, x, s);
            // Penalty tokens have already been transferred to the pool by _payBucket;
            // capturePenalty() only ACCOUNTS them. In a configured pool it routes the
            // measured receipt to the exiting vault's immutable policy sleeve; legacy
            // pools retain the original generic basket path. try/catch so a griefing co-asset in the pool
            // can never freeze this exit (V3-POOL-1) — the penalty is safe in the pool and
            // any keeper capture() re-accounts it later.
            if (s.poolWad > 0) {
                try IB4PoolVault(pool).capturePenalty() {} catch {}
            }
        }

        emit ExitFinalized(
            x, s.grossWad, s.ownerWad, s.grossWad - s.ownerWad - s.operatorWad, s.free
        );
        return true;
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
}
