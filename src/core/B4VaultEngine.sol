// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {B4VaultStorage} from "./B4VaultStorage.sol";
import {Phi} from "../libraries/Phi.sol";
import {Calendar} from "../libraries/Calendar.sol";
import {SafeTransfer} from "../libraries/SafeTransfer.sol";
import {CoreTypes} from "../venue/CoreTypes.sol";
import {CoreReader} from "../venue/CoreReader.sol";
import {CoreWriterLib} from "../venue/CoreWriterLib.sol";
import {DescriptorLib} from "../venue/DescriptorLib.sol";
import {StructuralLeverage} from "../libraries/StructuralLeverage.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IHalvingOracle} from "../interfaces/IHalvingOracle.sol";

/// @dev Minimal view of B4Pool for the structural-leverage anchors (SPECIFICATION §7b):
///      confirmed lows for the long, confirmed peaks for the short.
interface IB4PoolAnchors {
    function anchors(uint256 assetIndex) external view returns (uint256 floor, uint256 cap);
    function peaks(uint256 assetIndex)
        external
        view
        returns (uint256 prevPeak, uint256 peakC, uint256 peakTag);
}

/// @title B4VaultEngine — the asynchronous execution engine.
/// @notice The core discipline (HAZARDS A):
///         * emitting an action never finalizes accounting — a later state read proves the
///           effect and only measured deltas are credited (A1/B1);
///         * completion keys ONLY on the Core spot balance (self-decreased) plus, for
///           Core→EVM, the EVM receipt; the perp `withdrawable` is never a completion or
///           retry counter (A2) — it only sizes clamps;
///         * every resend condition is the exact complement of its completion condition,
///           evaluated on the same reads, with no post-timeout dead zone (A3);
///         * a resend re-arms the timeout so at most one emitted action can be live at a
///           time (the venue drops unexecuted actions long before RESEND_TIMEOUT — funded
///           gate SECURITY_MODEL §5.10);
///         * the pending harvest claim gates nothing and is always settled as
///           min(claim, available-now) then cleared entirely (A4/A5);
///         * a Core→EVM leg is never resent once its source decreased (A7);
///         * EVM→Core credits are polled forever, never re-emitted or abandoned (A8);
///         * credits are capped at the intended amount and the price envelope in both
///           directions; any residual is attacker-funded surplus, recoverable (A11).
abstract contract B4VaultEngine is B4VaultStorage {
    using SafeTransfer for address;

    /// Persistent harvest quota (1e6). NOTHING is allowed to gate on this being zero
    /// (A5); the planner settles-and-clears it via a single FromPerp(Harvest) intent.
    uint64 public pendingHarvest6;

    // ================================================================= units & prices

    function _toWad(uint256 amount, uint8 decimals_) internal pure returns (uint256) {
        return Phi.mulDiv(amount, Phi.WAD, 10 ** decimals_);
    }

    function _fromWad(uint256 wad, uint8 decimals_) internal pure returns (uint256) {
        return Phi.mulDiv(wad, 10 ** decimals_, Phi.WAD);
    }

    /// _fromWad clamped to uint64 — a Core-wei amount can exceed 2⁶⁴ for a micro-priced
    /// asset held in the tens of thousands of USD, and a raw truncating cast would wrap
    /// mod 2⁶⁴ and starve the sync planner into a permanent no-progress state (V3-ACCT-2).
    /// The engine is delta-measured and re-derives each crank, so clamping the sizing to
    /// the uint64 ceiling just chunks the move across cranks — H3-safe.
    function _fromWad64(uint256 wad, uint8 decimals_) internal pure returns (uint64) {
        uint256 v = _fromWad(wad, decimals_);
        return v > type(uint64).max ? type(uint64).max : uint64(v);
    }

    function _usd6ToWei(uint64 amount6) internal view returns (uint64) {
        return amount6 * uint64(10 ** (_usdc.coreWeiDecimals - CoreTypes.PERP_USD_DECIMALS));
    }

    function _weiToUsd6(uint64 weiAmount) internal view returns (uint64) {
        return weiAmount / uint64(10 ** (_usdc.coreWeiDecimals - CoreTypes.PERP_USD_DECIMALS));
    }

    /// The two Core-spot USDC sub-buckets label the SAME token: `coreUsdcRotatedWei` counts as
    /// strategy value, `coreUsdcMarginWei` as perp collateral. Reclassifying moves value between
    /// the strategy and margin sides of NAV with NO Core transaction (the sum, and thus the
    /// actual Core balance, is unchanged). This is what lets a short be funded by selling spot
    /// (V6-M-2): the fall's sale lands USDC in `rotated`, the short needs it in `margin`; the
    /// recovery needs the reverse to buy spot back. Callers MUST follow it with the intent that
    /// consumes the reclassified funds in the SAME step, so the crank reports progress (A13).
    function _reclassifyUsdc(bool toMargin, uint64 needWei) internal {
        if (toMargin) {
            uint64 m = _min64(needWei, coreUsdcRotatedWei);
            coreUsdcRotatedWei -= m;
            coreUsdcMarginWei += m;
        } else {
            uint64 m = _min64(needWei, coreUsdcMarginWei);
            coreUsdcMarginWei -= m;
            coreUsdcRotatedWei += m;
        }
    }

    /// EVM-side counterpart of `_reclassifyUsdc`. Steady-state custody is EVM, so a short's
    /// funding proceeds are typically repatriated to `usdcRotatedEvm` before the perp step runs;
    /// this reclassifies them to `usdcMarginEvm` so the margin fund path (`_startFund`) can carry
    /// them back to Core as collateral. Same-token bookkeeping; NAV-neutral (V6-M-2).
    function _reclassifyUsdcEvm(bool toMargin, uint256 amount) internal {
        if (toMargin) {
            uint256 m = Phi.min(amount, usdcRotatedEvm);
            usdcRotatedEvm -= m;
            usdcMarginEvm += m;
        } else {
            uint256 m = Phi.min(amount, usdcMarginEvm);
            usdcMarginEvm -= m;
            usdcRotatedEvm += m;
        }
    }

    function _livePxWad() internal view returns (uint256) {
        return CoreReader.spotPxWad(_dir);
    }

    /// This vault's own Core spot balance for `token` — the RELIABLE, self-moved balance
    /// (HAZARDS A2). Every completion proof reads through here.
    function _spotBal(uint64 token) internal view returns (uint64) {
        return CoreReader.spotBalance(address(this), token);
    }

    /// This vault's own perp withdrawable — PnL-driven, used only for sizing/reconcile,
    /// never as a completion counter (HAZARDS A2).
    function _wd() internal view returns (uint64) {
        return CoreReader.withdrawable(address(this));
    }

    /// Quantize a WAD limit price to a valid HyperCore order price in the 1e8 writer
    /// convention (SPEC §7: "prices rounded to venue price rules"). The venue REJECTS an
    /// order whose price has more than 5 significant figures (integer prices exempt) or more
    /// than `maxDecimals − szDecimals` decimal places (`maxDecimals` = 8 spot, 6 perp); an
    /// un-quantized price freezes the vault (rejected order ⇒ zero delta ⇒ resend-forever,
    /// H3). Rounds a BUY limit DOWN and a SELL limit UP so the executed price can never leave
    /// the slippage envelope.
    function _quantizePx8(uint256 pxWad, bool roundUp, uint8 szDec, bool isSpot)
        internal
        pure
        returns (uint64)
    {
        uint256 px8 = pxWad / 1e10; // 1e8 writer convention
        if (px8 == 0) return 0;
        uint256 maxDec = isSpot ? 8 : 6;
        uint256 dcap = maxDec > szDec ? maxDec - szDec : 0; // decimal places px may carry
        uint256 step = 10 ** (8 - dcap); // px8 must be a multiple of this (dcap ≤ 8)
        // 5-significant-figure rule, unless px is a whole integer (px8 a multiple of 1e8).
        if (px8 % 1e8 != 0) {
            uint256 digits;
            for (uint256 t = px8; t != 0; t /= 10) {
                digits++;
            }
            uint256 sigStep = digits > 5 ? 10 ** (digits - 5) : 1;
            if (sigStep > step) step = sigStep;
        }
        uint256 q = (px8 / step) * step; // rounded DOWN to the coarsest valid grid
        if (roundUp && q != px8) q += step; // SELL: round UP so we never sit below the floor
        // Clamp before the narrowing cast (V8-I-7): above ~$1.8e11 the quantized price
        // exceeds the uint64 ceiling and a raw cast would silently truncate mod 2^64.
        return q > type(uint64).max ? type(uint64).max : uint64(q);
    }

    /// Read-convention perp px (6 − szDecimals decimals) — used for PnL notional math.
    function _pxWadToPerpRaw(uint256 pxWad) internal view returns (uint64) {
        return uint64(Phi.mulDiv(pxWad, 10 ** (6 - _dir.perpSzDecimals), Phi.WAD));
    }

    /// Lots → writer size (1e8 fixed). Exact (lots are the venue granularity), but the
    /// 1e8 field is uint64, so an extreme single-order size would overflow. Clamp the
    /// LOTS instead of reverting: the engine is delta-measured and re-derives every crank,
    /// so a clamped order just chunks the move across cranks — a reduce-only flatten still
    /// reaches raw zero (A10) over multiple steps. Returns the clamped size (never zero
    /// when lots > 0). Reachability: the ceiling (~1.8e15 / scale lots) is only hit on the
    /// SPOT side by a micro-priced asset held in the tens of millions of USD; a PERP
    /// position that large is impossible under the margin·maxLev/φ reserve, and the
    /// clamped notional (min price × ceiling) is always far above the venue $10 minimum,
    /// so a clamped chunk never becomes an unfillable no-op.
    function _spotLotsToSz8(uint64 lots) internal view returns (uint64) {
        return _lotsToSz8(lots, _dir.spotSzDecimals);
    }

    function _perpLotsToSz8(uint64 lots) internal view returns (uint64) {
        return _lotsToSz8(lots, _dir.perpSzDecimals);
    }

    function _lotsToSz8(uint64 lots, uint8 szDecimals) private pure returns (uint64) {
        uint64 scale = uint64(10 ** (8 - szDecimals));
        uint64 maxLots = type(uint64).max / scale;
        return (lots > maxLots ? maxLots : lots) * scale;
    }

    function _dirWeiPerLot() internal view returns (uint64) {
        return uint64(10 ** (_dir.coreWeiDecimals - _dir.spotSzDecimals));
    }

    // ================================================================= valuation

    /// @notice Strategy value (WAD USD) — directional + rotated capital at `pxWad`;
    ///         owner margin is EXCLUDED so it never increases strategy notional (B3).
    function _strategyValueWad(uint256 pxWad) internal view returns (uint256) {
        uint256 dirTokensWad =
            _toWad(dirEvm, _dir.evmDecimals) + _toWad(coreDirWei, _dir.coreWeiDecimals);
        uint256 usdcWad = _toWad(usdcRotatedEvm, _usdc.evmDecimals)
            + _toWad(coreUsdcRotatedWei, _usdc.coreWeiDecimals);
        return Phi.wmul(dirTokensWad, pxWad) + usdcWad;
    }

    function _marginValueWad() internal view returns (uint256) {
        return _toWad(usdcMarginEvm, _usdc.evmDecimals)
            + _toWad(coreUsdcMarginWei, _usdc.coreWeiDecimals)
            + _toWad(perpMargin6, CoreTypes.PERP_USD_DECIMALS);
    }

    /// @notice NAV over RECORDED values only — unrealized PnL and unverified surplus never
    ///         enter (B3). Every value-locking or valuation caller (settle, exit-finalize,
    ///         the sync/exit planners) runs ONLY at an idle engine, so every in-flight
    ///         leg has already credited its bucket and this sum is exact — no in-flight
    ///         special-casing (a mid-flight valuation would otherwise mis-account either
    ///         the returning principal or a coincident real loss).
    function _navWad(uint256 pxWad) internal view returns (uint256) {
        return _strategyValueWad(pxWad) + _marginValueWad();
    }

    /// @notice Reconcile realized Core loss BEFORE any valuation (B2): when strictly flat,
    ///         recorded perp principal is written down to the actual withdrawable. Called
    ///         at the head of settle, exit valuation AND sync planning — ALL of which run
    ///         only at an idle engine (settle and the recovery paths require idle; the
    ///         planners run only from an idle crank; the FromPerp zero-resend clears the
    ///         intent before calling). At idle the withdrawable moves only for REAL
    ///         reasons (an order's realized PnL / liquidation), never for an in-flight
    ///         transfer of our own — so the write-down is always a genuine loss
    ///         (TEST_PLAN §2.8). Spot-only vaults have no perp principal and never touch
    ///         the perp precompiles here.
    function _reconcile() internal {
        if (_dir.perpMarket == CoreTypes.NO_MARKET) return; // spot-only: no perp principal
        if (_position().szi != 0) return; // A10 strict flatness
        uint64 wd = _wd();
        if (wd < perpMargin6) {
            uint64 loss = perpMargin6 - wd;
            perpMargin6 = wd;
            perpStopWad = 0; // the position closed adversely (e.g. a venue liquidation) — the
            // frozen stop is stale; the next open re-derives from the live price.
            emit LossReconciled(loss);
        }
    }

    /// @notice Perp position of this vault, guarded for spot-only descriptors: the
    ///         accepted NO_MARKET sentinel MUST never reach the position precompile (a
    ///         truncated/invalid asset id read could revert and brick every lifecycle
    ///         path). A perp-less vault is permanently, strictly flat.
    function _position() internal view returns (CoreTypes.Position memory pos) {
        if (_dir.perpMarket == CoreTypes.NO_MARKET) return pos;
        return CoreReader.position(address(this), _dir.perpMarket);
    }

    // ================================================================= intent creation

    function _requireIdle() internal view {
        if (intent.kind != IntentKind.None) revert IntentPending();
    }

    function _clearIntent() internal {
        delete intent;
    }

    function _snapshotBase(IntentKind kind, Purpose purpose, uint64 amount) internal {
        intent.kind = kind;
        intent.purpose = purpose;
        intent.amount = amount;
        intent.createdAt = uint40(block.timestamp);
        emit IntentCreated(kind, purpose, amount);
    }

    /// EVM→Core funding. The ERC20 leaves accounting NOW (remove-then-send, SPEC §7); the
    /// Core credit is polled (A8) with first-credit activation-fee tolerance (A9).
    /// @return created true iff an intent was actually snapshotted. A sub-wei amount that
    ///         floors to zero creates nothing — the caller must NOT treat that as planner
    ///         progress, or the perp-sizing leg is starved and the crank spins (M-1).
    function _startFund(bool dirToken, Purpose purpose, uint256 evmAmount)
        internal
        returns (bool created)
    {
        CoreTypes.AssetDescriptor memory d = dirToken ? _dir : _usdc;
        uint64 weiAmount = DescriptorLib.evmToCore(d, evmAmount);
        if (weiAmount == 0) return false;
        // Core-balance headroom cap (V4-ENG-1): a Core spot balance is uint64, so the
        // credit (spotBal + weiAmount) must never exceed 2^64−1. evmToCore above caps the
        // chunk at uint64.max, but after a clamped chunk a sub-lot residue r remains on
        // Core, and funding uint64.max again makes the credit r + uint64.max
        // unrepresentable — a revert locally, a dropped credit on the live venue (the A8
        // poll-forever wedge); the engine's own `coreDirWei += credited` would overflow
        // too. Cap by the LIVE spot balance (covers unaccounted surplus as well). Zero
        // headroom means the Core side is full and must be SOLD down first, so skipping
        // the fund cannot deadlock the rotation.
        uint64 headroom = type(uint64).max - _spotBal(d.coreToken);
        if (weiAmount > headroom) weiAmount = headroom;
        if (weiAmount == 0) return false;
        // A9 self-wedge guard: on a fresh (unactivated) Core account the first credit loses
        // the activation fee. A first fund the fee could consume ENTIRELY (weiAmount ≤ the
        // allowance) would credit zero and then poll forever — completion needs a measured
        // delta and A8 forbids resend/abandon. Refuse it (create no intent); the planner
        // then simply holds (H3 delayed liveness) until the amount grows past the allowance
        // or a larger fund activates the account. The live fee MUST be ≤ the allowance
        // (funded gate §5.3) so a fund above the allowance always credits non-zero.
        if (!CoreReader.coreUserExists(address(this)) && weiAmount <= _activationAllowanceWei(d)) {
            return false;
        }
        // Normalize to a whole-wei EVM amount so nothing is stranded by flooring.
        evmAmount = DescriptorLib.coreToEvm(d, weiAmount);
        if (dirToken) {
            dirEvm -= evmAmount;
        } else if (purpose == Purpose.Margin) {
            usdcMarginEvm -= evmAmount;
        } else {
            usdcRotatedEvm -= evmAmount;
        }
        _snapshotBase(dirToken ? IntentKind.FundDir : IntentKind.FundUsdc, purpose, weiAmount);
        intent.snapSrcWei = _spotBal(d.coreToken);
        intent.firstCredit = !CoreReader.coreUserExists(address(this));
        // PIN the activation allowance at creation (audit L-4). A `Fund` leg polls forever
        // by design (A8: no resend, no abandon), and the allowance is denominated in TOKENS
        // — `$5 / px`. Re-deriving it at the live price on every poll meant a price RISE
        // shrank the allowance, lifting the completion threshold above a credit whose fee
        // was already deducted at the older, lower price: the leg could then never complete
        // and the vault would stall permanently. `snapAux` is unused by the funding legs.
        intent.snapAux = intent.firstCredit ? _activationAllowanceWei(d) : 0;
        d.evmToken.safeTransfer(CoreTypes.systemAddress(d.coreToken), evmAmount);
        return true;
    }

    /// One IOC spot order. Input must already sit on Core spot as recorded principal.
    /// @return created true iff an order was actually snapshotted; a spend/size below one
    ///         lot floors to zero and creates nothing (caller must not count it — M-1).
    function _startSpotOrder(bool isBuy, uint64 inputWei) internal returns (bool created) {
        uint256 pxWad = _livePxWad();
        if (pxWad == 0) return false; // spot feed down: hold, never revert-loop (H3)
        uint64 sz;
        uint256 limitWad;
        if (isBuy) {
            // Spend USDC for dir: sz sized so sz·limitPx ≤ spend.
            limitWad = Phi.mulDiv(pxWad, 10_000 + slippageBps, 10_000);
            uint256 spendUsdWad = _toWad(inputWei, _usdc.coreWeiDecimals);
            uint256 tokensWad = Phi.mulDiv(spendUsdWad, Phi.WAD, limitWad);
            sz = uint64(Phi.mulDiv(tokensWad, 10 ** _dir.spotSzDecimals, Phi.WAD));
        } else {
            sz = inputWei / _dirWeiPerLot();
            limitWad = Phi.mulDiv(pxWad, 10_000 - slippageBps, 10_000);
        }
        if (sz == 0) return false; // zero-size orders are never sent (SPEC §7)
        // Post-flooring minimum-notional hold (V8-M-4): when one lot is worth more than
        // (diff − $10), the floored order lands below the venue's $10 minimum and the
        // live venue rejects it (resend wedge, H3). Re-check the EMITTED order's own
        // notional at its limit price and hold — same shape as the planner's hold band.
        if (Phi.mulDiv(uint256(sz), limitWad, 10 ** _dir.spotSzDecimals) < MIN_ORDER_USD_WAD) {
            return false;
        }
        _snapshotBase(IntentKind.SpotOrder, Purpose.Generic, inputWei);
        intent.isBuy = isBuy;
        intent.orderSz = sz;
        intent.pxWad = pxWad;
        // Reliable-balance snapshots of BOTH legs (A2).
        intent.snapSrcWei = _spotBal(isBuy ? _usdc.coreToken : _dir.coreToken);
        intent.snapAux = _spotBal(isBuy ? _dir.coreToken : _usdc.coreToken);
        // Writer fields in fixed-1e8 units (px quantized to venue price rules, size in lots).
        CoreWriterLib.iocOrder(
            CoreTypes.SPOT_ASSET_OFFSET + _dir.spotMarket,
            isBuy,
            _quantizePx8(limitWad, !isBuy, _dir.spotSzDecimals, true),
            _spotLotsToSz8(sz),
            false
        );
        return true;
    }

    /// @dev The EVM balance of `token` in excess of the buckets this vault already records
    ///      for it — the RELIABLE receipt measure for a Core→EVM leg (A2).
    ///
    ///      A Core→EVM delivery is the only inflow that raises this WITHOUT simultaneously
    ///      raising a recorded bucket, so it, not the raw balance, is the "destination
    ///      received the full amount" A2 demands. Keying on the raw balance is the same
    ///      defect audit C-2 fixed on the Core-spot destination ("an increase of the output
    ///      proves nothing"), left standing on the EVM destination: ANY concurrent inflow —
    ///      the owner's own `deposit`, which is reachable while an intent is pending, or a
    ///      third-party transfer — satisfied the receipt and cleared the intent while the
    ///      venue was still inside its debit-then-deliver window (A7). The value was then on
    ///      neither side with no pending marker, so at an IDLE engine the recorded books
    ///      exceeded the real assets (invariants 3/4/5/6/17) and every valuation taken in
    ///      that window — settle's NAV, the fee it charges, the pool weight it mints, exit's
    ///      gross — was overstated by the in-flight amount.
    ///
    ///      `deferredPayoutTotal` IS subtracted, on the same grounds as `opsRecoverEvm`:
    ///      a deferred payout is value the vault physically holds but OWES its recorded
    ///      recipient, so it is accounted, never "unaccounted". An earlier revision left it
    ///      in, on the claim that it "changes only inside settle / exit-finalize, both of
    ///      which require an idle engine". That was FALSE in one direction: `claimDeferred`
    ///      is permissionless and carries no idle gate, so it lowered the EVM balance WITHOUT
    ///      lowering the subtrahend, shrinking this measure under a live leg. A claim of `A`
    ///      mid-flight left a `ReturnDir`/`ReturnUsdc` permanently short of `evmNeeded` while
    ///      `decreased` kept the resend branch shut — an intent that can neither complete nor
    ///      resend, which `emergencyClearRecovery` refuses (it takes `Recover*` kinds only),
    ///      freezing every idle-gated entrypoint with no admin to unstick it. An honest keeper
    ///      reaches `crankVault` then `retryDeferred` in ONE transaction, so this needed no
    ///      attacker (AUDIT-2026-07-29 F3).
    ///
    ///      With it subtracted the measure is invariant to the whole deferred mechanism: a
    ///      claim lowers `bal` and `deferredPayoutTotal` by the same `A` and cancels exactly (a
    ///      failed transfer reverts, rolling both back together), and payouts are DEFERRED only
    ///      inside settle / exit-finalize, which do require an idle engine — so the subtrahend
    ///      cannot rise under a live leg either.
    ///
    ///      Liveness (A3/A7) is unchanged: the resend gate is still exactly `!decreased`,
    ///      and the only path that could drain this quantity out from under a live leg,
    ///      `opsRecoverEvm`, already requires an idle engine for both accounted tokens.
    function _unaccountedEvm(address token, bool isDir) internal view returns (uint256) {
        uint256 bal = IERC20(token).balanceOf(address(this));
        uint256 booked =
            deferredPayoutTotal[token] + (isDir ? dirEvm : usdcRotatedEvm + usdcMarginEvm);
        return bal > booked ? bal - booked : 0;
    }

    /// Core spot → EVM return of recorded principal.
    function _startReturn(bool dirToken, Purpose purpose, uint64 weiAmount) internal {
        if (weiAmount == 0) return;
        CoreTypes.AssetDescriptor memory d = dirToken ? _dir : _usdc;
        _snapshotBase(dirToken ? IntentKind.ReturnDir : IntentKind.ReturnUsdc, purpose, weiAmount);
        intent.snapSrcWei = _spotBal(d.coreToken);
        intent.snapEvm = _unaccountedEvm(d.evmToken, dirToken);
        CoreWriterLib.spotSend(CoreTypes.systemAddress(d.coreToken), d.coreToken, weiAmount);
    }

    /// Margin spot → perp.
    /// @return created true iff an intent was snapshotted; a zero amount creates nothing (M-1).
    function _startToPerp(uint64 amount6) internal returns (bool created) {
        if (amount6 == 0) return false;
        _snapshotBase(IntentKind.ToPerp, Purpose.Margin, amount6);
        intent.snapSrcWei = _spotBal(_usdc.coreToken);
        CoreWriterLib.usdClassTransfer(amount6, true);
        return true;
    }

    /// Perp → spot: margin return (principal) or harvest-claim settlement.
    /// Margin return REQUIRES strict flatness (A10) — enforced by callers.
    function _startFromPerp(Purpose purpose, uint64 amount6) internal {
        if (purpose == Purpose.Harvest) {
            // A4: settle min(claim, available-now); the claim leaves vault state NOW and
            // lives only inside this intent — nothing can gate on it (A5).
            uint64 claim = pendingHarvest6;
            pendingHarvest6 = 0;
            uint64 wd = _wd();
            uint64 avail = wd > perpMargin6 ? wd - perpMargin6 : 0;
            amount6 = claim < avail ? claim : avail;
            if (amount6 == 0) {
                // Nothing settleable now: the residual is abandoned into recoverable
                // surplus, never a blocking phantom (A4).
                emit HarvestSettled(0, claim);
                return;
            }
            _snapshotBase(IntentKind.FromPerp, Purpose.Harvest, amount6);
            intent.claim6 = claim;
        } else {
            if (amount6 == 0) return;
            _snapshotBase(IntentKind.FromPerp, purpose, amount6);
        }
        intent.snapSrcWei = _spotBal(_usdc.coreToken);
        CoreWriterLib.usdClassTransfer(amount6, false);
    }

    /// One IOC perp order. Reductions are reduce-only and never cross zero; a full close
    /// targets exact zero (A10). Non-reduce opens carry the $10 minimum (SPEC §7).
    /// @return emitted true iff an IOC order was actually sent. A dead mark feed or a zero size
    ///         emits nothing and returns false, so a planner never reports progress on a no-op
    ///         (A13 / audit L-6): the caller holds and the keeper's bounded loop stops spinning.
    function _startPerpOrder(bool isBuy, uint64 szLots, bool reduceOnly) internal returns (bool) {
        if (szLots == 0) return false;
        CoreTypes.Position memory pos = _position();
        uint256 markWad = CoreReader.perpPxWad(_dir, true);
        if (markWad == 0) return false; // perp feed down: hold, never emit a px-0 order (V8-L-1)
        uint256 limitWad = isBuy
            ? Phi.mulDiv(markWad, 10_000 + PERP_ENVELOPE_BPS, 10_000)
            : Phi.mulDiv(markWad, 10_000 - PERP_ENVELOPE_BPS, 10_000);
        _snapshotBase(IntentKind.PerpOrder, Purpose.Generic, szLots);
        intent.isBuy = isBuy;
        intent.orderSz = szLots;
        intent.snapAux = uint64(Phi.abs(pos.szi));
        intent.pxWad = markWad;
        if (reduceOnly) {
            // Snapshot the positive mark PnL for the harvest bound (SPEC §7).
            intent.claim6 = _positivePnl6(pos, markWad);
        }
        // Writer fields in fixed-1e8 units (px quantized to venue price rules, size in lots).
        CoreWriterLib.iocOrder(
            _dir.perpMarket,
            isBuy,
            _quantizePx8(limitWad, !isBuy, _dir.perpSzDecimals, false),
            _perpLotsToSz8(szLots),
            reduceOnly
        );
        return true;
    }

    function _positivePnl6(CoreTypes.Position memory pos, uint256 markWad)
        internal
        view
        returns (uint64)
    {
        if (pos.szi == 0) return 0;
        // notional now (1e6) = |szi| lots · mark; lots·rawPx carries 6 decimals.
        uint256 ntlNow = uint256(Phi.abs(pos.szi)) * _pxWadToPerpRaw(markWad);
        int256 pnl = pos.szi > 0
            ? int256(ntlNow) - int256(uint256(pos.entryNtl))
            : int256(uint256(pos.entryNtl)) - int256(ntlNow);
        return pnl > 0 ? uint64(uint256(pnl)) : 0;
    }

    // ================================================================= verification

    /// @notice Advance the pending intent: complete on proof, resend on the exact
    ///         complement after timeout. Returns true if any state changed.
    function _verifyIntent() internal returns (bool) {
        IntentKind kind = intent.kind;
        if (kind == IntentKind.None) return false;
        if (kind == IntentKind.FundDir || kind == IntentKind.FundUsdc) {
            return _verifyFund(kind);
        }
        if (kind == IntentKind.SpotOrder) return _verifySpotOrder();
        if (kind == IntentKind.ReturnDir || kind == IntentKind.ReturnUsdc) {
            return _verifyReturn(kind);
        }
        if (kind == IntentKind.ToPerp) return _verifyToPerp();
        if (kind == IntentKind.FromPerp) return _verifyFromPerp();
        if (kind == IntentKind.PerpOrder) return _verifyPerpOrder();
        return _verifyRecovery(kind);
    }

    function _verifyFund(IntentKind kind) internal returns (bool) {
        bool isDir = kind == IntentKind.FundDir;
        CoreTypes.AssetDescriptor memory d = isDir ? _dir : _usdc;
        uint64 cur = _spotBal(d.coreToken);
        uint64 delta = cur > intent.snapSrcWei ? cur - intent.snapSrcWei : 0;
        uint64 threshold = intent.amount;
        if (intent.firstCredit) {
            // Tolerate the activation fee on the first credit (A9), but always require a
            // measured non-zero credit before completing.
            uint64 allowance = intent.snapAux; // pinned at creation (L-4), never re-derived
            threshold = threshold > allowance + 1 ? threshold - allowance : 1;
        }
        if (delta < threshold) return false; // keep polling (A8): no resend, no dead zone
        uint64 credited = delta < intent.amount ? delta : intent.amount; // cap (A11)
        if (isDir) {
            coreDirWei += credited;
        } else if (intent.purpose == Purpose.Margin) {
            coreUsdcMarginWei += credited;
        } else {
            coreUsdcRotatedWei += credited;
        }
        emit IntentCompleted(kind, intent.purpose, credited);
        _clearIntent();
        return true;
    }

    function _activationAllowanceWei(CoreTypes.AssetDescriptor memory d)
        internal
        view
        returns (uint64)
    {
        uint256 pxWad = d.fixedUsd ? Phi.WAD : _livePxWad();
        if (pxWad == 0) return 0;
        uint256 tokensWad = Phi.mulDiv(ACTIVATION_FEE_USD_WAD, Phi.WAD, pxWad);
        return uint64(_fromWad(tokensWad, d.coreWeiDecimals));
    }

    function _verifySpotOrder() internal returns (bool) {
        (uint64 inToken, uint64 outToken) =
            intent.isBuy ? (_usdc.coreToken, _dir.coreToken) : (_dir.coreToken, _usdc.coreToken);
        uint64 curIn = _spotBal(inToken);
        uint64 curOut = _spotBal(outToken);
        uint64 inDelta = intent.snapSrcWei > curIn ? intent.snapSrcWei - curIn : 0;
        uint64 outDelta = curOut > intent.snapAux ? curOut - intent.snapAux : 0;
        // A2: only a self-caused DECREASE of the INPUT proves the IOC executed. An increase
        // of the output proves nothing — anyone may transfer into a Core spot balance, so
        // gating on `outDelta` let a 1-wei donation clear a still-live order before its
        // timeout, with zero accounting, leaving the later fill entirely unaccounted
        // (audit C-2). `outDelta` survives below only as the measured credit, capped.
        //
        // Clearing on timeout stays safe in every `inDelta == 0` case, because
        // `inDelta == 0` means `curIn >= snapSrcWei`: the input bucket's ledger is never
        // above the real balance. A genuine fill whose debit is masked by a concurrent
        // top-up is exactly compensated (spend + top-up net to >= 0), so books still match
        // assets and the received output is simply unaccounted, owner-recoverable surplus
        // (A11) — the safe direction. Books can never exceed assets here.
        if (inDelta == 0) {
            if (block.timestamp < intent.createdAt + RESEND_TIMEOUT) return false;
            // IOC observed no measured input debit: nothing to account; planner may issue
            // a fresh order.
            emit IntentCleared(IntentKind.SpotOrder);
            _clearIntent();
            return true;
        }
        // Measure actual deltas; credit output capped by measured input × snapshot price
        // (A11/SPEC §7) — favorable overfill stays unaccounted, recoverable surplus.
        uint64 credit;
        if (intent.isBuy) {
            uint256 spentUsdWad = _toWad(inDelta, _usdc.coreWeiDecimals);
            uint256 capTokensWad = Phi.mulDiv(spentUsdWad, Phi.WAD, intent.pxWad);
            uint64 capWei = uint64(_fromWad(capTokensWad, _dir.coreWeiDecimals));
            credit = outDelta < capWei ? outDelta : capWei;
            coreUsdcRotatedWei -= _min64(inDelta, coreUsdcRotatedWei);
            coreDirWei += credit;
        } else {
            uint256 soldTokensWad = _toWad(inDelta, _dir.coreWeiDecimals);
            uint256 capUsdWad = Phi.wmul(soldTokensWad, intent.pxWad);
            uint64 capWei = uint64(_fromWad(capUsdWad, _usdc.coreWeiDecimals));
            credit = outDelta < capWei ? outDelta : capWei;
            coreDirWei -= _min64(inDelta, coreDirWei);
            coreUsdcRotatedWei += credit;
        }
        emit SpotTraded(intent.isBuy, inDelta, outDelta, credit);
        _clearIntent();
        return true;
    }

    function _verifyReturn(IntentKind kind) internal returns (bool) {
        bool isDir = kind == IntentKind.ReturnDir;
        CoreTypes.AssetDescriptor memory d = isDir ? _dir : _usdc;
        uint64 cur = _spotBal(d.coreToken);
        bool decreased = cur < intent.snapSrcWei;
        uint256 evmNeeded = DescriptorLib.coreToEvm(d, intent.amount);
        // A2: the receipt is the growth of the UNACCOUNTED EVM balance, never the raw
        // balance — see `_unaccountedEvm`.
        uint256 un = _unaccountedEvm(d.evmToken, isDir);
        uint256 received = un > intent.snapEvm ? un - intent.snapEvm : 0;
        if (decreased && received >= evmNeeded) {
            if (isDir) {
                coreDirWei -= _min64(intent.amount, coreDirWei);
                dirEvm += evmNeeded;
            } else if (intent.purpose == Purpose.Margin) {
                coreUsdcMarginWei -= _min64(intent.amount, coreUsdcMarginWei);
                usdcMarginEvm += evmNeeded;
            } else {
                coreUsdcRotatedWei -= _min64(intent.amount, coreUsdcRotatedWei);
                usdcRotatedEvm += evmNeeded;
            }
            emit IntentCompleted(kind, intent.purpose, intent.amount);
            _clearIntent();
            return true;
        }
        // A7: once the source decreased the leg executed — wait for delivery, NEVER resend.
        if (!decreased && block.timestamp >= intent.createdAt + RESEND_TIMEOUT) {
            uint64 amount = intent.amount <= cur ? intent.amount : cur; // defensive re-clamp
            // A zero re-clamp is terminal, not defensive (audit M-1): a zero-amount
            // spotSend can never decrease the source, so `decreased` stays false forever
            // while this resend branch stays true forever — the intent never clears and
            // every idle-gated entrypoint (settle, exit finalize, recovery) dies with it,
            // permanently, with no admin to unstick it. Reaching here with `cur == 0`
            // implies `snapSrcWei == 0` (otherwise `cur < snapSrcWei` and `decreased` would
            // be true), so nothing was ever on Core to return and clearing owes no debit.
            // A12: a timeout may schedule, never wedge.
            if (amount == 0) {
                emit IntentCleared(kind);
                _clearIntent();
                return true;
            }
            intent.amount = amount;
            intent.createdAt = uint40(block.timestamp); // one live action at a time
            CoreWriterLib.spotSend(CoreTypes.systemAddress(d.coreToken), d.coreToken, amount);
            emit IntentResent(kind, amount);
            return true;
        }
        return false;
    }

    function _verifyToPerp() internal returns (bool) {
        uint64 cur = _spotBal(_usdc.coreToken);
        if (cur < intent.snapSrcWei) {
            // Net-decrease proves the intra-Core transfer executed (atomic — funded gate).
            uint64 weiAmt = _usd6ToWei(intent.amount);
            coreUsdcMarginWei -= _min64(weiAmt, coreUsdcMarginWei);
            perpMargin6 += intent.amount;
            emit IntentCompleted(IntentKind.ToPerp, Purpose.Margin, intent.amount);
            _clearIntent();
            return true;
        }
        if (block.timestamp >= intent.createdAt + RESEND_TIMEOUT) {
            // Exact complement: no net-decrease observed (A3). A ≥-amount top-up masking
            // the decrease makes this resend attacker-funded surplus (A11 residual).
            intent.createdAt = uint40(block.timestamp);
            CoreWriterLib.usdClassTransfer(intent.amount, true);
            emit IntentResent(IntentKind.ToPerp, intent.amount);
            return true;
        }
        return false;
    }

    function _verifyFromPerp() internal returns (bool) {
        uint64 cur = _spotBal(_usdc.coreToken);
        uint64 weiNeeded = _usd6ToWei(intent.amount);
        // uint256 add so an (unreachable) near-uint64-max snapshot can never overflow-
        // revert the completion check — the worst case must stay delayed liveness (H3).
        if (uint256(cur) >= uint256(intent.snapSrcWei) + weiNeeded) {
            // Destination proof: spot net-increase reaching the full amount (A2).
            if (intent.purpose == Purpose.Harvest) {
                coreUsdcRotatedWei += weiNeeded;
                emit HarvestSettled(intent.amount, intent.claim6 - intent.amount);
            } else {
                perpMargin6 -= _min64(intent.amount, perpMargin6);
                coreUsdcMarginWei += weiNeeded;
                emit MarginReturned(intent.amount);
            }
            emit IntentCompleted(IntentKind.FromPerp, intent.purpose, intent.amount);
            _clearIntent();
            return true;
        }
        if (block.timestamp >= intent.createdAt + RESEND_TIMEOUT) {
            // Exact complement + A4 re-clamp to what is available NOW. The perp
            // withdrawable sizes the clamp but never acts as the completion counter (A2).
            uint64 wd = _wd();
            uint64 newAmount;
            if (intent.purpose == Purpose.Harvest) {
                uint64 avail = wd > perpMargin6 ? wd - perpMargin6 : 0;
                newAmount = intent.amount < avail ? intent.amount : avail;
                if (newAmount == 0) {
                    // Claim fully abandoned into recoverable surplus — never a phantom (A4).
                    emit HarvestSettled(0, intent.claim6);
                    _clearIntent();
                    return true;
                }
            } else {
                newAmount = intent.amount < wd ? intent.amount : wd;
                if (newAmount == 0) {
                    // Flat principal no longer withdrawable: realize the loss, self-heal.
                    // Clear first — reconcile only acts on an idle engine.
                    emit IntentCleared(IntentKind.FromPerp);
                    _clearIntent();
                    _reconcile();
                    return true;
                }
            }
            intent.amount = newAmount;
            intent.createdAt = uint40(block.timestamp);
            CoreWriterLib.usdClassTransfer(newAmount, false);
            emit IntentResent(IntentKind.FromPerp, newAmount);
            return true;
        }
        return false;
    }

    function _verifyPerpOrder() internal returns (bool) {
        CoreTypes.Position memory pos = _position();
        uint64 absNow = uint64(Phi.abs(pos.szi));
        if (absNow == intent.snapAux) {
            if (block.timestamp < intent.createdAt + RESEND_TIMEOUT) return false;
            emit IntentCleared(IntentKind.PerpOrder); // no fill; planner re-derives
            _clearIntent();
            return true;
        }
        // Position moved (fill — or liquidation, measured identically).
        if (absNow < intent.snapAux && intent.claim6 > 0) {
            // Harvest bound: min(surplus above principal, snapshotted +PnL, +PnL × the
            // fraction actually reduced) — SPEC §7.
            uint64 wd = _wd();
            uint64 surplus = wd > perpMargin6 ? wd - perpMargin6 : 0;
            uint256 fracWad = Phi.mulDiv(intent.snapAux - absNow, Phi.WAD, intent.snapAux);
            uint64 pnlFrac = uint64(Phi.wmul(intent.claim6, fracWad));
            uint64 add = _min64(surplus, pnlFrac);
            if (add > 0) {
                pendingHarvest6 += add;
                emit HarvestRecorded(add);
            }
        }
        emit IntentCompleted(IntentKind.PerpOrder, Purpose.Generic, intent.orderSz);
        _clearIntent();
        return true;
    }

    function _verifyRecovery(IntentKind kind) internal returns (bool) {
        if (kind == IntentKind.RecoverPerpPhase1) {
            uint64 cur = _spotBal(_usdc.coreToken);
            uint64 weiNeeded = _usd6ToWei(intent.amount);
            // uint256 add: no overflow-revert on an extreme snapshot (defense; H3).
            if (uint256(cur) >= uint256(intent.snapSrcWei) + weiNeeded) {
                // Surplus now sits on Core spot (still unaccounted); phase 2 sends it out.
                uint64 amount = intent.amount;
                _clearIntent();
                _startRecoverySpot(IntentKind.RecoverPerpPhase2, _usd6ToWei(amount));
                return true;
            }
            if (block.timestamp >= intent.createdAt + RESEND_TIMEOUT) {
                uint64 wd = _wd();
                uint64 avail = wd > perpMargin6 ? wd - perpMargin6 : 0;
                uint64 newAmount = intent.amount < avail ? intent.amount : avail;
                if (newAmount == 0) {
                    emit IntentCleared(kind); // nothing left; re-recoverable later (A6)
                    _clearIntent();
                    return true;
                }
                intent.amount = newAmount;
                intent.createdAt = uint40(block.timestamp);
                CoreWriterLib.usdClassTransfer(newAmount, false);
                emit IntentResent(kind, newAmount);
                return true;
            }
            return false;
        }
        // RecoverSpotDir / RecoverSpotUsdc / RecoverPerpPhase2: Core spot → EVM → owner.
        CoreTypes.AssetDescriptor memory d = kind == IntentKind.RecoverSpotDir ? _dir : _usdc;
        uint64 cur2 = _spotBal(d.coreToken);
        bool decreased = cur2 < intent.snapSrcWei;
        uint256 evmNeeded = DescriptorLib.coreToEvm(d, intent.amount);
        // Same A2 receipt rule as `_verifyReturn`, and it matters more here: this branch
        // pays `evmNeeded` straight OUT to the owner, so a spoofed receipt would move
        // accounted tokens against surplus that has not landed yet.
        uint256 un = _unaccountedEvm(d.evmToken, kind == IntentKind.RecoverSpotDir);
        uint256 received = un > intent.snapEvm ? un - intent.snapEvm : 0;
        if (decreased && received >= evmNeeded) {
            // Bounded surplus straight to the owner — no accounting callback (B6).
            d.evmToken.safeTransfer(owner, evmNeeded);
            emit SurplusRecovered(kind, intent.amount, owner);
            _clearIntent();
            return true;
        }
        if (!decreased && block.timestamp >= intent.createdAt + RESEND_TIMEOUT) {
            uint64 amount = intent.amount <= cur2 ? intent.amount : cur2;
            if (amount == 0) {
                emit IntentCleared(kind);
                _clearIntent();
                return true;
            }
            intent.amount = amount;
            intent.createdAt = uint40(block.timestamp);
            CoreWriterLib.spotSend(CoreTypes.systemAddress(d.coreToken), d.coreToken, amount);
            emit IntentResent(kind, amount);
            return true;
        }
        return false;
    }

    function _startRecoverySpot(IntentKind kind, uint64 weiAmount) internal {
        CoreTypes.AssetDescriptor memory d = kind == IntentKind.RecoverSpotDir ? _dir : _usdc;
        _snapshotBase(kind, Purpose.Generic, weiAmount);
        intent.snapSrcWei = _spotBal(d.coreToken);
        intent.snapEvm = _unaccountedEvm(d.evmToken, kind == IntentKind.RecoverSpotDir);
        CoreWriterLib.spotSend(CoreTypes.systemAddress(d.coreToken), d.coreToken, weiAmount);
    }

    // ================================================================= planner

    function _currentTarget() internal view returns (int256) {
        uint256 t = IHalvingOracle(oracle).timeSinceHalving();
        return Calendar.targetAt(t, growthTarget, fallTarget);
    }

    /// @notice One sync step toward the time-derived target (SPEC §5.4). Priorities:
    ///         wrong-sign reduce → harvest settle → reconcile → spot rotation → margin →
    ///         perp sizing. A derivative sign change therefore always passes through a
    ///         verified zero (invariant 9), and no step is gated by the harvest claim (A5).
    function _planSyncStep() internal returns (bool) {
        (int256 spotF, int256 perpF) = Calendar.decompose(_currentTarget());
        CoreTypes.Position memory pos = _position();

        // 1. Wrong-sign (or should-be-zero) perp: reduce to exact zero first.
        if (pos.szi != 0 && (perpF == 0 || (pos.szi > 0) != (perpF > 0))) {
            // Hold (return false) if the mark feed is down: cannot flatten, and must NOT fall
            // through to spot/perp sizing while a wrong-sign perp is still open.
            return _startPerpOrder(pos.szi < 0, uint64(Phi.abs(pos.szi)), true);
        }
        // 2. Harvest claim: settle min(claim, available), clear.
        if (pendingHarvest6 > 0) {
            _startFromPerp(Purpose.Harvest, 0);
            return true; // even a zero-settle cleared state
        }
        // 3. Reconcile before any sizing valuation (B2).
        _reconcile();

        uint256 pxWad = _livePxWad();
        uint256 v = _strategyValueWad(pxWad);

        // 4. Spot rotation toward clamp(n,0,1).
        if (v > 0 && _planSpotStep(spotF, pxWad, v)) return true;

        // 5–6. Margin and perp sizing toward n − spot.
        return _planPerpStep(perpF, pos, v);
    }

    function _planSpotStep(int256 spotF, uint256 pxWad, uint256 v) internal returns (bool) {
        uint256 dirTokensWad =
            _toWad(dirEvm, _dir.evmDecimals) + _toWad(coreDirWei, _dir.coreWeiDecimals);
        uint256 dirValWad = Phi.wmul(dirTokensWad, pxWad);
        uint256 targetValWad = Phi.wmul(v, uint256(spotF));
        uint256 band = Phi.max(Phi.bps(v, TOLERANCE_BPS), MIN_ORDER_USD_WAD);

        if (dirValWad > targetValWad + band) {
            uint256 sellUsdWad = dirValWad - targetValWad;
            uint256 sellTokensWad = Phi.mulDiv(sellUsdWad, Phi.WAD, pxWad);
            uint64 sellWei = _fromWad64(sellTokensWad, _dir.coreWeiDecimals); // clamp, not wrap
            // Sell what already sits on Core, IF at least one whole lot is sellable there;
            // a sub-lot residual on Core would floor to a no-op, so fall through to move
            // more EVM dir onto Core instead of stalling behind the dust (V3-ACCT-2: the
            // clamp can leave EVM dir with only sub-lot Core dust — the rotation must keep
            // converging, H3). _startSpotOrder returns false without an intent on a no-op.
            if (coreDirWei > 0 && _startSpotOrder(false, _min64(sellWei, coreDirWei))) {
                return true;
            }
            if (dirEvm > 0) {
                return _startFund(
                    true, Purpose.Generic, Phi.min(DescriptorLib.coreToEvm(_dir, sellWei), dirEvm)
                );
            }
            return false; // only sub-lot dust remains; effectively in band
        }
        if (targetValWad > dirValWad + band) {
            uint256 spendUsdWad = targetValWad - dirValWad;
            uint64 spendWei = _fromWad64(spendUsdWad, _usdc.coreWeiDecimals); // clamp, not wrap
            // Buy spot from margin USDC too (V6-M-2 reverse): after a short closes, its margin
            // returns to the margin sub-bucket; reclassify what rotation still lacks so the
            // recovery buys BTC back. Followed immediately by the buy order below (progress).
            if (coreUsdcRotatedWei < spendWei && coreUsdcMarginWei > 0) {
                _reclassifyUsdc(false, spendWei - coreUsdcRotatedWei);
            }
            if (
                coreUsdcRotatedWei > 0
                    && _startSpotOrder(true, _min64(spendWei, coreUsdcRotatedWei))
            ) {
                return true;
            }
            // EVM-side reverse: a closed short's margin is repatriated to `usdcMarginEvm`;
            // reclassify it to rotation so the recovery can fund a Core buy (V6-M-2).
            uint256 spendEvm = DescriptorLib.coreToEvm(_usdc, spendWei);
            if (usdcRotatedEvm < spendEvm && usdcMarginEvm > 0) {
                _reclassifyUsdcEvm(false, spendEvm - usdcRotatedEvm);
            }
            if (usdcRotatedEvm > 0) {
                return _startFund(false, Purpose.Generic, Phi.min(spendEvm, usdcRotatedEvm));
            }
            return false; // nothing to buy with (or only sub-lot Core dust)
        }
        // In band: repatriate residual strategy principal — steady-state custody is EVM.
        if (coreUsdcRotatedWei > 0) {
            _startReturn(false, Purpose.Generic, coreUsdcRotatedWei);
            return true;
        }
        if (coreDirWei > 0) {
            _startReturn(true, Purpose.Generic, coreDirWei);
            return true;
        }
        return false;
    }

    /// @dev Fund perp margin toward `need6` from strategy USDC (the V6-M-2 reclassify path:
    ///      rotated→margin on both Core and EVM sides, then ToPerp / Fund). Same-token,
    ///      NAV-neutral reclassify followed IN THE SAME STEP by the intent that consumes it
    ///      (A13). Returns true iff an intent was created; a margin-constrained or sub-unit
    ///      top-up returns false so the caller sizes against the margin already present (M-1).
    function _fundPerpMargin(uint64 need6) internal returns (bool) {
        if (perpMargin6 >= need6) return false;
        uint64 deficit6 = need6 - perpMargin6;
        uint64 deficitWei = _usd6ToWei(deficit6);
        if (coreUsdcMarginWei < deficitWei && coreUsdcRotatedWei > 0) {
            _reclassifyUsdc(true, deficitWei - coreUsdcMarginWei);
        }
        if (coreUsdcMarginWei > 0 && _startToPerp(_min64(_weiToUsd6(coreUsdcMarginWei), deficit6)))
        {
            return true;
        }
        uint256 deficitEvm =
            _fromWad(_toWad(deficit6, CoreTypes.PERP_USD_DECIMALS), _usdc.evmDecimals);
        if (usdcMarginEvm < deficitEvm && usdcRotatedEvm > 0) {
            _reclassifyUsdcEvm(true, deficitEvm - usdcMarginEvm);
        }
        if (
            usdcMarginEvm > 0
                && _startFund(false, Purpose.Margin, Phi.min(deficitEvm, usdcMarginEvm))
        ) {
            return true;
        }
        return false;
    }

    /// @dev The target perp margin (WAD) to deploy and, for a leveraged long, the structural
    ///      stop. A leveraged long (Pro Max, g > 1) deploys the WHOLE strategy as margin ramped
    ///      by the calendar (`navWad·perpF/g`) with the venue liquidation placed at `stopWad`;
    ///      shorts / g ≤ 1 keep the flat-φ reserve (`notional·φ/maxLev`). Refusal / sub-min ⇒ 0.
    ///      Split out to bound `_planPerpStep`'s stack frame.
    function _perpTargetMargin(int256 perpF, uint256 v, uint256 pxWad, int64 szi)
        internal
        returns (uint256 marginNeedWad, uint256 stopWad, bool structural)
    {
        bool long = perpF > 0;
        uint256 g = uint256(Phi.abs(long ? growthTarget : fallTarget));
        // A perp LONG exists only for a leveraged product (Pro Max, g > 1 — Pro/B4/Mini hold
        // spot); a perp SHORT exists for Pro (flat, pinned to C) and Pro Max (2-anchor). Both are
        // margin-control structural. `pool != 0` guards the bare engine harness (flat-φ fallback).
        structural = pool != address(0) && pxWad != 0 && (long ? g > Phi.WAD : perpF < 0);
        if (structural) {
            // The frozen stop is (re-)derived at the CURRENT price every idle crank WHILE FLAT
            // (szi == 0), and held UNCHANGED once the position is live (szi != 0). Freezing only
            // across the live span is what stops a price move or an anchor flip re-trading a HELD
            // position (C1/C4); re-deriving while flat is what guarantees a full exit, a no-loss
            // venue close (ADL/forced-deleverage), or a multi-crank async funding gap always opens
            // against a FRESH stop — no stale value survives a flatten (kills the exit/close
            // re-lever class the fan-out flagged). A refusal (long p ≤ stop / short p ≥ stop ⇒ s 0
            // or on the wrong side) freezes nothing ⇒ marginNeed 0 ⇒ hold the un-leveraged USDC (C5).
            if (szi == 0) {
                uint256 s = long ? _longStopWad(pxWad) : _shortStopWad(pxWad);
                perpStopWad = (s != 0 && (long ? pxWad > s : s > pxWad)) ? s : 0;
                perpStopLong = long;
            }
            stopWad = perpStopWad;
            // `g` is read LIVE while the stop is FROZEN, so a policy change to a zero-side
            // pair while a position is held would divide by zero and make the
            // permissionless `crank()` revert until the owner intervened — a liveness
            // break, not a value bug (audit L-3). No target scale ⇒ no margin need ⇒ the
            // planner unwinds through its normal zero-target path.
            if (stopWad != 0 && g != 0) {
                marginNeedWad = Phi.mulDiv(_navWad(pxWad), Phi.abs(perpF), g);
            }
        } else {
            // Non-structural (flat-φ engine harness / a g ≤ 1 leg with no pool): drop any frozen
            // stop while flat so it can never leak into a later structural open on this side.
            if (szi == 0) perpStopWad = 0;
            uint256 ntl = Phi.wmul(v, Phi.abs(perpF));
            if (ntl >= MIN_ORDER_USD_WAD) {
                marginNeedWad = Phi.mulDiv(ntl, Phi.PHI, uint256(_dir.perpMaxLeverage) * Phi.WAD);
            }
        }
    }

    /// @dev The stop a NEW slice is sized against: the structural stop at the LIVE price, not the
    ///      one frozen when the position opened. No flat/held special case is needed — when flat,
    ///      `_perpTargetMargin` has just frozen this same derivation at this same price, so the
    ///      two coincide by construction. A refusal at this price falls back to the frozen stop,
    ///      which sizes the add no larger than the held lots' own rule — never larger.
    function _sliceStopWad(uint256 pxWad, uint256 frozen) internal view returns (uint256) {
        uint256 s = perpStopLong ? _longStopWad(pxWad) : _shortStopWad(pxWad);
        return s == 0 ? frozen : s;
    }

    /// @dev Structural target size (lots). TWO stops, and the split is the whole point:
    ///      `heldStopWad` is the FROZEN stop the existing `absNow` lots were opened against — they
    ///      are never re-priced, which is what stops a price move or an anchor flip re-trading a
    ///      held position (C1/C4). `sliceStopWad` is the structural stop derived at the CURRENT
    ///      price, and the ADD is sized against it at the live `mark`: `szi_inc = Δm/|mark −
    ///      sliceStop|`, so every increment lands its OWN liquidation on the rule's stop for the
    ///      price it actually fills at (STRUCTURAL-STATE-MACHINE §6). The combined liquidation is
    ///      then the margin-weighted average of the two, which is correct and expected — a top-up
    ///      at a better price SHOULD move the blended stop. Sizing the increment against the
    ///      frozen stop instead is what produced the A29 over-lever: after an adverse move the
    ///      frozen stop sits far closer than the rule allows at the new price (measured 9.0× where
    ///      the rule gives φ), because since A26 the post-pivot stop DEPENDS on the entry price.
    ///      A reduce/hold sizes at the (unchanged) avg entry against the frozen stop. The whole
    ///      position is finally capped at the venue max leverage (SPEC §7b): an unclamped
    ///      structural size near an anchor implies L→∞ (rejected order / liquidation not at the
    ///      stop); the clamp de-levers (liquidation FURTHER than the stop — the safe way).
    function _szTargetStructural(
        uint256 heldStopWad,
        uint256 sliceStopWad,
        uint256 marginNeedWad,
        uint256 avgEntryWad,
        uint256 markWad,
        uint64 absNow
    ) internal view returns (uint64) {
        bool long = perpStopLong;
        uint256 denomEntry = long
            ? (avgEntryWad > heldStopWad ? avgEntryWad - heldStopWad : 0)
            : (heldStopWad > avgEntryWad ? heldStopWad - avgEntryWad : 0);
        uint256 denomMark = long
            ? (markWad > sliceStopWad ? markWad - sliceStopWad : 0)
            : (sliceStopWad > markWad ? sliceStopWad - markWad : 0);
        if (denomMark == 0) return absNow; // mark at/through the stop: no stop-pinned slice to add
        uint256 dec = 10 ** _dir.perpSzDecimals;
        uint256 effMarginWad =
            Phi.min(marginNeedWad, _toWad(perpMargin6, CoreTypes.PERP_USD_DECIMALS));
        uint256 backingWad = denomEntry == 0 ? 0 : Phi.mulDiv(absNow, denomEntry, dec);
        uint256 szTarget; // in lots; kept in uint256 so a tiny denomMark can't overflow pre-clamp
        if (effMarginWad > backingWad) {
            // ADD (or fresh open, absNow 0): size the increment at the mark.
            szTarget = uint256(absNow) + Phi.mulDiv(effMarginWad - backingWad, dec, denomMark);
        } else if (denomEntry != 0) {
            // REDUCE / hold: proportional at the avg entry keeps the remaining liquidation at stop.
            szTarget = Phi.mulDiv(effMarginWad, dec, denomEntry);
        } else {
            return absNow;
        }
        // Cap at the venue max leverage BEFORE narrowing (maxSz ≈ margin·maxLev/mark is bounded).
        // The clamp only limits NEW exposure (V8-L-4): after a clamped open a mark rise shrinks
        // maxSz below the HELD size — floored at absNow so the clamp can never reduce a held
        // position. Reductions remain the marginNeed path's job (szTarget < absNow above).
        uint256 maxSz = Phi.mulDiv(effMarginWad * uint256(_dir.perpMaxLeverage), dec, markWad);
        if (maxSz < absNow) maxSz = absNow;
        return uint64(szTarget > maxSz ? maxSz : szTarget);
    }

    /// @dev Flat-φ size (lots): notional (`v·|perpF|`, capped by `margin·maxLev/φ`) at the live mark.
    function _szTargetFlat(uint256 markWad, uint256 v, int256 perpF)
        internal
        view
        returns (uint64)
    {
        uint256 capWad = Phi.mulDiv(
            _toWad(perpMargin6, CoreTypes.PERP_USD_DECIMALS),
            uint256(_dir.perpMaxLeverage) * Phi.WAD,
            Phi.PHI
        );
        uint256 effTargetWad = Phi.min(Phi.wmul(v, Phi.abs(perpF)), capWad);
        return uint64(
            Phi.mulDiv(
                Phi.mulDiv(effTargetWad, Phi.WAD, markWad), 10 ** _dir.perpSzDecimals, Phi.WAD
            )
        );
    }

    function _planPerpStep(int256 perpF, CoreTypes.Position memory pos, uint256 v)
        internal
        returns (bool)
    {
        // Spot-only descriptor (accepted NO_MARKET sentinel): a perp component of the
        // target is inexpressible — never touch perp precompiles or margin machinery.
        // The vault supports spot products (Mini/B4); a perp-bearing policy degrades to
        // its spot component (documented, ARCHITECTURE.md).
        if (_dir.perpMarket == CoreTypes.NO_MARKET) return false;
        uint256 pxWad = _livePxWad();
        // A dead spot feed is NOT "this leg is not structural" (audit H-2). Folding
        // `pxWad != 0` into the `structural` predicate downstream sent a HELD, frozen-stop
        // position onto the flat-φ rule computed from a price-suppressed strategy value,
        // which sizes far below the live position and made the planner emit a reduce-only
        // order closing most of it. Holding must also happen HERE, before
        // `_perpTargetMargin`: making that function report `structural` with
        // `marginNeedWad == 0` instead would fall into the zero-margin branch below and
        // RETURN the margin of a live leveraged position, de-collateralizing it toward
        // liquidation — strictly worse than the bug. With no price there is nothing sound
        // to size, so hold: no order, no margin move, no stop rewrite. Every other
        // zero-price path in the engine holds too, and the worst case is delayed liveness.
        if (pxWad == 0) return false;

        // A leveraged LONG (Pro Max, base g > 1) is sized by MARGIN CONTROL against the new
        // structural stop (STRUCTURAL-STATE-MACHINE.md §6) — NO engine-side frozen L: the venue's
        // own entry is the frozen reference, so a HELD position is never re-adjusted (a price move
        // or a halving anchor-flip can't re-lever it — C1/C4), and an exit/liquidation → szi 0
        // re-derives from flat (nothing stale to clear). Shorts are margin-control structural
        // too (Pro flat pinned to C / Pro Max 2-anchor); only a pool-less engine harness falls
        // back to the flat-φ path — `pool != 0` guards it (no anchor source).
        (uint256 marginNeedWad, uint256 stopWad, bool structural) =
            _perpTargetMargin(perpF, v, pxWad, pos.szi);

        if (marginNeedWad == 0) {
            // No perp target: return margin — only at strict raw zero (A10). The returned perp
            // margin IS strategy capital (SPEC §5, post-V6-M-2) → reclassify it to the ROTATION
            // bucket (NAV-neutral) and repatriate as strategy so the NEXT leg reads a non-zero
            // strategyValue and sizes, instead of stranding in the vestigial owner reserve.
            if (pos.szi == 0 && perpMargin6 > 0) {
                _startFromPerp(Purpose.Margin, perpMargin6);
                return true;
            }
            if (coreUsdcMarginWei > 0) {
                _reclassifyUsdc(false, coreUsdcMarginWei);
                _startReturn(false, Purpose.Generic, coreUsdcRotatedWei);
                return true;
            }
            // The EVM-side counterpart (audit M-2). Only the CORE margin bucket was
            // reclassified here, so margin created on the EVM side by an exit — or left
            // there by a margin return — stayed invisible to the planner for the whole
            // zero-perp span: `_strategyValueWad` does not count it, so the next leg sized
            // on an understated capital base. Same-token, NAV-neutral bucket move.
            if (usdcMarginEvm > 0) {
                _reclassifyUsdcEvm(false, usdcMarginEvm);
                return true;
            }
            return false;
        }

        uint64 marginNeed6 = uint64(_fromWad(marginNeedWad, CoreTypes.PERP_USD_DECIMALS));
        if (_fundPerpMargin(marginNeed6)) return true;

        uint256 markWad = CoreReader.perpPxWad(_dir, true);
        if (markWad == 0) return false;
        uint64 absNow = uint64(Phi.abs(pos.szi));
        // Held ⇒ the venue avg entry is the frozen reference for the existing lots; fresh ⇒ a new
        // slice fills at the mark. `_szTargetStructural` sizes an ADD at the mark and a reduce/hold
        // at the avg entry, and caps the whole position at the venue max leverage.
        uint64 szTarget = structural
            ? _szTargetStructural(
                stopWad,
                _sliceStopWad(pxWad, stopWad),
                marginNeedWad,
                pos.szi != 0 ? _avgEntryWad(pos) : markWad,
                markWad,
                absNow
            )
            : _szTargetFlat(markWad, v, perpF);

        // Band by the larger of live strategy value and the target margin (a held structural
        // position has strategyValue ≈ 0), so it doesn't collapse to the $10 floor and re-trade.
        uint256 bandUsd =
            Phi.max(Phi.bps(Phi.max(v, marginNeedWad), TOLERANCE_BPS), MIN_ORDER_USD_WAD);
        uint256 diffUsdWad = Phi.mulDiv(
            uint256(szTarget > absNow ? szTarget - absNow : absNow - szTarget) * markWad,
            1,
            10 ** _dir.perpSzDecimals
        );
        if (diffUsdWad <= bandUsd) return false;
        bool targetLong = perpF > 0;
        if (szTarget > absNow) {
            return _startPerpOrder(targetLong, szTarget - absNow, false);
        }
        // Shrink toward target: reduce-only, opposite side.
        return _startPerpOrder(!targetLong, absNow - szTarget, true);
    }

    /// @dev The structural stop (WAD) for a leveraged LONG at price `pxWad`, selected by the
    ///      calendar regime (STRUCTURAL-STATE-MACHINE.md §3): the recovery DCA window
    ///      (`OpeningGrowth`, anchored to the previous confirmed bottom `floor`); the
    ///      post-halving volume-add window (`[0, W)`, anchored to this cycle's confirmed low
    ///      `cap`); else the flat-φ growth rise (`stop = p/φ²`). Returns 0 to refuse (an entry
    ///      at/below the stop, or an unconfirmed anchor). Reached only from the planner.
    ///      Density gate (V8-M-1): `B4Pool.anchors()` WITHHOLDS an under-sampled `cap` as 0,
    ///      which the `cap_ != 0` gates below then treat exactly like an absent anchor —
    ///      the L-halving/L-post regimes skip and the long degrades to the fail-safe flat-φ
    ///      rise instead of pinning the fixed MinStop to a sparse low.
    function _longStopWad(uint256 pxWad) internal view returns (uint256) {
        (uint256 floor_, uint256 cap_) = IB4PoolAnchors(pool).anchors(_dirAssetIndex);
        uint256 t = IHalvingOracle(oracle).timeSinceHalving();
        Calendar.Zone zone = Calendar.zoneAt(t);
        if (zone == Calendar.Zone.OpeningGrowth) {
            return StructuralLeverage.longStop(pxWad, floor_, 0); // L-win: B unknown, live p, anchor Pb
        }
        if (t < Calendar.W && floor_ != 0) {
            // L-halving: anchor the 62-min, live p_day (audit H-4).
            // STRUCTURAL-STATE-MACHINE §3 is normative here: `stop_day = p_day − (p_day − B)/φ`
            // with `B` = the 62-min, worked as [p=3000, B=850 → 1671] (row PM5). The 62-min is
            // what the halving flip promotes into `floor`; `cap` in `[0, W)` holds the
            // still-forming minimum of the CURRENT post-halving window. Passing `cap` put a
            // near-price anchor in the delta slot: `p − cap` is small by construction (same
            // window as the live price) while `p − floor` is large (previous cycle), and since
            // `L = p/(p − stop)` with `stop = p − (p − anchor)/φ`, the near anchor drives
            // leverage to the venue clamp. The density gate did not catch it — it only
            // confirms that the window's own minimum was sampled enough, not that the
            // minimum is a structural bottom.
            // `floor` needs no density check: it is only ever promoted from a confirmed
            // window, so a non-zero floor is confirmed by construction.
            return StructuralLeverage.longStop(pxWad, floor_, 0);
        }
        if (zone == Calendar.Zone.TerminalGrowth && cap_ != 0) {
            // L-post: this cycle's low `B = cap_` is confirmed ⇒ `clamp(p/φ², MinStop, B)`
            // with `MinStop = B − (B − Pb)/φ`. The CAP at `B` is the safety: the venue
            // liquidation can never sit above a level the market already printed and held, so a
            // retest of the cycle low cannot close a position the structural stop was designed to
            // survive. The floor at `MinStop` is the second anchor's lift near the bottom, and
            // between them the long runs at its base `φ`. (Entry-DEPENDENT since 2026-08-01 — it
            // was a single fixed `MinStop` before, which made the `φ` band unreachable.)
            return StructuralLeverage.longStop(pxWad, floor_, cap_);
        }
        return StructuralLeverage.longStop(pxWad, 0, 0); // L-rise: flat φ (p/φ²) — documented interim
    }

    /// @dev The structural stop (WAD) for a leveraged SHORT at `pxWad`. Pro (base 1×): a flat
    ///      `g×` short floored at the confirmed peak `C`. Pro Max (g > 1): the 2-anchor structural
    ///      short (`prevPeak`, `C`), which degrades to flat φ at genesis. Returns 0 to refuse.
    ///
    ///      The confirmed peak `C` is fed ONLY in the post-pivot Fall regime and ONLY when it is
    ///      THIS cycle's peak (`peakTag == epoch + 1`); everywhere else `C = 0`, so the S-win
    ///      (OpeningFall, peak still forming) uses the live price `p` per the spec window rule, and
    ///      a SKIPPED/stale peak window (peakTag from a prior cycle) never anchors the short to a
    ///      systematically-too-low prior peak — which would over-lever it (the anti-conservative
    ///      direction, unlike the mirror low ratchet whose stale value is fail-safe). This is the
    ///      short mirror of `_longStopWad`'s zone gate; the venue-max clamp in `_szTargetStructural`
    ///      backstops the diminishing-cycle window tail.
    ///      Density gate (V8-M-1/V8-M-2): `B4Pool.peaks()` WITHHOLDS an under-sampled `peakC`
    ///      as 0 — a sparse window or a single wick is treated exactly like "this cycle's peak
    ///      unknown", so the short degrades to the clamp-backed window extrapolation off the
    ///      (promotion-gated, hence confirmed) `prevPeak` instead of pinning the fixed maxStop
    ///      inside the price range the market already proved.
    function _shortStopWad(uint256 pxWad) internal view returns (uint256) {
        (uint256 prevPeak, uint256 peakC, uint256 peakTag) =
            IB4PoolAnchors(pool).peaks(_dirAssetIndex);
        uint256 t = IHalvingOracle(oracle).timeSinceHalving();
        uint256 c = (peakTag == IHalvingOracle(oracle).epoch() + 1
                && Calendar.zoneAt(t) == Calendar.Zone.Fall)
            ? peakC
            : 0;
        uint256 g = uint256(Phi.abs(fallTarget));
        if (g <= Phi.WAD) return StructuralLeverage.shortFlatStop(pxWad, g, c);
        return StructuralLeverage.shortStructStop(pxWad, prevPeak, c);
    }

    /// @dev The venue's average entry price (WAD, USD per directional unit) of a non-flat perp:
    ///      `entryNtl` (1e6 USD absolute) over `|szi|` (lots), lifted to WAD. This is the
    ///      venue's own frozen reference — a held position's margin-control sizing anchors to it,
    ///      so no engine-side entry freeze is needed.
    function _avgEntryWad(CoreTypes.Position memory pos) internal view returns (uint256) {
        uint256 absSzi = Phi.abs(pos.szi);
        if (absSzi == 0) return 0;
        return Phi.mulDiv(
            uint256(pos.entryNtl) * (10 ** _dir.perpSzDecimals),
            Phi.WAD,
            absSzi * (10 ** CoreTypes.PERP_USD_DECIMALS)
        );
    }

    function _min64(uint64 a, uint64 b) internal pure returns (uint64) {
        return a < b ? a : b;
    }
}
