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
import {IERC20} from "../interfaces/IERC20.sol";
import {IHalvingOracle} from "../interfaces/IHalvingOracle.sol";

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

    /// CoreWriter order fields are fixed-point 1e8 (human value × 10⁸) — a DIFFERENT
    /// convention from the szDecimals-scaled precompile reads. Live confirmation is a
    /// funded gate (SECURITY_MODEL §5.4–5).
    function _pxWadTo8(uint256 pxWad) internal pure returns (uint64) {
        return uint64(pxWad / 1e10);
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
        d.evmToken.safeTransfer(CoreTypes.systemAddress(d.coreToken), evmAmount);
        return true;
    }

    /// One IOC spot order. Input must already sit on Core spot as recorded principal.
    /// @return created true iff an order was actually snapshotted; a spend/size below one
    ///         lot floors to zero and creates nothing (caller must not count it — M-1).
    function _startSpotOrder(bool isBuy, uint64 inputWei) internal returns (bool created) {
        uint256 pxWad = _livePxWad();
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
        _snapshotBase(IntentKind.SpotOrder, Purpose.Generic, inputWei);
        intent.isBuy = isBuy;
        intent.orderSz = sz;
        intent.pxWad = pxWad;
        // Reliable-balance snapshots of BOTH legs (A2).
        intent.snapSrcWei = _spotBal(isBuy ? _usdc.coreToken : _dir.coreToken);
        intent.snapAux = _spotBal(isBuy ? _dir.coreToken : _usdc.coreToken);
        // Writer fields in fixed-1e8 units (px, size) — NOT the read/lot conventions.
        CoreWriterLib.iocOrder(
            CoreTypes.SPOT_ASSET_OFFSET + _dir.spotMarket,
            isBuy,
            _pxWadTo8(limitWad),
            _spotLotsToSz8(sz),
            false
        );
        return true;
    }

    /// Core spot → EVM return of recorded principal.
    function _startReturn(bool dirToken, Purpose purpose, uint64 weiAmount) internal {
        if (weiAmount == 0) return;
        CoreTypes.AssetDescriptor memory d = dirToken ? _dir : _usdc;
        _snapshotBase(dirToken ? IntentKind.ReturnDir : IntentKind.ReturnUsdc, purpose, weiAmount);
        intent.snapSrcWei = _spotBal(d.coreToken);
        intent.snapEvm = IERC20(d.evmToken).balanceOf(address(this));
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
    function _startPerpOrder(bool isBuy, uint64 szLots, bool reduceOnly) internal {
        if (szLots == 0) return;
        CoreTypes.Position memory pos = _position();
        uint256 markWad = CoreReader.perpPxWad(_dir, true);
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
        // Writer fields in fixed-1e8 units (px, size) — NOT the read/lot conventions.
        CoreWriterLib.iocOrder(
            _dir.perpMarket, isBuy, _pxWadTo8(limitWad), _perpLotsToSz8(szLots), reduceOnly
        );
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
            uint64 allowance = _activationAllowanceWei(d);
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
        if (inDelta == 0 && outDelta == 0) {
            if (block.timestamp < intent.createdAt + RESEND_TIMEOUT) return false;
            // IOC observed no fill: nothing to account; planner may issue a fresh order.
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
        uint256 evmBal = IERC20(d.evmToken).balanceOf(address(this));
        uint256 received = evmBal > intent.snapEvm ? evmBal - intent.snapEvm : 0;
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
        uint256 evmBal = IERC20(d.evmToken).balanceOf(address(this));
        uint256 received = evmBal > intent.snapEvm ? evmBal - intent.snapEvm : 0;
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
        intent.snapEvm = IERC20(d.evmToken).balanceOf(address(this));
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
            _startPerpOrder(pos.szi < 0, uint64(Phi.abs(pos.szi)), true);
            return true;
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
            if (
                coreUsdcRotatedWei > 0
                    && _startSpotOrder(true, _min64(spendWei, coreUsdcRotatedWei))
            ) {
                return true;
            }
            if (usdcRotatedEvm > 0) {
                return _startFund(
                    false,
                    Purpose.Generic,
                    Phi.min(DescriptorLib.coreToEvm(_usdc, spendWei), usdcRotatedEvm)
                );
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

    function _planPerpStep(int256 perpF, CoreTypes.Position memory pos, uint256 v)
        internal
        returns (bool)
    {
        // Spot-only descriptor (accepted NO_MARKET sentinel): a perp component of the
        // target is inexpressible — never touch perp precompiles or margin machinery.
        // The vault supports spot products (Mini/B4); a perp-bearing policy degrades to
        // its spot component (documented, ARCHITECTURE.md).
        if (_dir.perpMarket == CoreTypes.NO_MARKET) return false;

        uint256 notionalTargetWad = Phi.wmul(v, Phi.abs(perpF));
        if (notionalTargetWad < MIN_ORDER_USD_WAD) notionalTargetWad = 0;

        if (notionalTargetWad == 0) {
            // No perp target: return margin — only at strict raw zero (A10).
            if (pos.szi == 0 && perpMargin6 > 0) {
                _startFromPerp(Purpose.Margin, perpMargin6);
                return true;
            }
            if (coreUsdcMarginWei > 0) {
                _startReturn(false, Purpose.Margin, coreUsdcMarginWei);
                return true;
            }
            return false;
        }

        // Safety reserve: notional ≤ margin·maxLev/φ ⇔ margin ≥ notional·φ/maxLev.
        uint256 marginNeedWad =
            Phi.mulDiv(notionalTargetWad, Phi.PHI, uint256(_dir.perpMaxLeverage) * Phi.WAD);
        uint64 marginNeed6 = uint64(_fromWad(marginNeedWad, CoreTypes.PERP_USD_DECIMALS));
        if (perpMargin6 < marginNeed6) {
            uint64 deficit6 = marginNeed6 - perpMargin6;
            // Only report progress if a top-up intent was actually created; a sub-unit
            // amount that rounds to a no-op must fall through and size the perp against the
            // margin already present, never spin the crank (M-1).
            if (
                coreUsdcMarginWei > 0
                    && _startToPerp(_min64(_weiToUsd6(coreUsdcMarginWei), deficit6))
            ) {
                return true;
            }
            uint256 deficitEvm =
                _fromWad(_toWad(deficit6, CoreTypes.PERP_USD_DECIMALS), _usdc.evmDecimals);
            if (
                usdcMarginEvm > 0
                    && _startFund(false, Purpose.Margin, Phi.min(deficitEvm, usdcMarginEvm))
            ) {
                return true;
            }
            // Margin-constrained or sub-unit top-up: fall through; notional capped by account.
        }

        uint256 notionalCapWad = Phi.mulDiv(
            _toWad(perpMargin6, CoreTypes.PERP_USD_DECIMALS),
            uint256(_dir.perpMaxLeverage) * Phi.WAD,
            Phi.PHI
        );
        uint256 effTargetWad = Phi.min(notionalTargetWad, notionalCapWad);
        uint256 markWad = CoreReader.perpPxWad(_dir, true);
        if (markWad == 0) return false;
        uint64 szTarget = uint64(
            Phi.mulDiv(
                Phi.mulDiv(effTargetWad, Phi.WAD, markWad), 10 ** _dir.perpSzDecimals, Phi.WAD
            )
        );
        uint64 absNow = uint64(Phi.abs(pos.szi));
        uint256 bandUsd = Phi.max(Phi.bps(v, TOLERANCE_BPS), MIN_ORDER_USD_WAD);
        uint256 diffUsdWad = Phi.mulDiv(
            uint256(szTarget > absNow ? szTarget - absNow : absNow - szTarget) * markWad,
            1,
            10 ** _dir.perpSzDecimals
        );
        if (diffUsdWad <= bandUsd) return false;
        bool targetLong = perpF > 0;
        if (szTarget > absNow) {
            _startPerpOrder(targetLong, szTarget - absNow, false);
        } else {
            // Shrink toward target: reduce-only, opposite side.
            _startPerpOrder(!targetLong, absNow - szTarget, true);
        }
        return true;
    }

    function _min64(uint64 a, uint64 b) internal pure returns (uint64) {
        return a < b ? a : b;
    }
}
