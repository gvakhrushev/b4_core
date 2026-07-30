// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {EngineHarness} from "../utils/EngineHarness.sol";
import {MockERC20} from "../mocks/MockCore.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {B4VaultStorage} from "src/core/B4VaultStorage.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {Phi} from "src/libraries/Phi.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";

/// @notice V9 engine-fix regressions from AUDIT-V8:
///         V8-M-4 spot order below the $10 venue minimum after lot flooring (hold);
///         V8-L-1 zero-mark guard mirrored into _startPerpOrder (exit flatten path);
///         V8-L-4 the venue-maxLev clamp must not shrink a HELD position;
///         V8-I-3 PIN: a sub-$10 PARTIAL reduce is held by the existing band;
///         V8-I-7 clamp before the uint64 narrowing cast in _quantizePx8.
contract V9EngineTest is VaultTestBase {
    EngineHarness h;

    function setUp() public {
        setUpProtocol();
        h = new EngineHarness();
        h.setup(ubtcDescriptor(), usdcDescriptor(), address(oracle));
        hub.setUserExists(address(h), true);
    }

    // ------------------------------------------------------------------ helpers

    function _decodeOrder(bytes memory raw)
        internal
        pure
        returns (uint32 asset, bool isBuy, uint64 limitPx, uint64 sz, bool reduceOnly)
    {
        bytes memory args = new bytes(raw.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = raw[i + 4];
        }
        (asset, isBuy, limitPx, sz, reduceOnly,,) =
            abi.decode(args, (uint32, bool, uint64, uint64, bool, uint8, uint128));
    }

    function _readPos(address who) internal view returns (CoreTypes.Position memory) {
        (bool ok, bytes memory ret) =
            CoreTypes.PRECOMPILE_POSITION.staticcall(abi.encode(who, uint16(PERP_MKT)));
        require(ok, "read pos");
        return abi.decode(ret, (CoreTypes.Position));
    }

    function _setPx(uint256 usd) internal {
        hub.setSpotPx(SPOT_MKT, uint64(usd * 1e4));
        hub.setMarkPx(PERP_MKT, uint64(usd * 1e2));
        hub.setOraclePx(PERP_MKT, uint64(usd * 1e2));
    }

    /// Dense daily anchor samples so the V9 density gate confirms the window's anchor.
    /// @dev Seed `floor` — the 62-min the halving flip promotes, which is the anchor the
    ///      L-halving regime uses (STRUCTURAL-STATE-MACHINE §3). Seeding `cap` in the
    ///      post-halving window instead was audit finding H-4.
    function _seedFloorViaHalvingFlip(uint256 px) internal {
        _sampleDaily(GENESIS_TS + Calendar.T + 1 days, 11, px);
        uint256 hts = GENESIS_TS + Calendar.T + Calendar.W + 30 days;
        vm.warp(hts);
        acceptHalving(GENESIS_HEIGHT + 210_000, uint32(hts));
        vm.warp(hts + 1 days);
        _setPx(px);
        pool.sampleAnchor(1);
        (uint256 floor_,) = pool.anchors(1);
        assertEq(floor_, px * 1e18, "62-min promoted into floor");
    }

    function _sampleDaily(uint256 t0abs, uint256 n, uint256 px) internal {
        for (uint256 k = 0; k < n; k++) {
            vm.warp(t0abs + k * 1 days);
            _setPx(px);
            pool.sampleAnchor(1);
        }
    }

    /// A venue-legal fine asset whose single lot is worth $6 (< the $10 minimum order):
    /// szDecimals 0, px $6. Re-setups the harness on it (spot-only descriptor).
    function _setupLotok() internal {
        MockERC20 lotok = new MockERC20("LOTOK", 8);
        hub.registerToken(2, address(lotok), 8, 0, 8, "LOTOK");
        hub.registerSpotMarket(6, 2, USDC_CORE);
        hub.setSpotPx(6, 6e8); // $6 in (8 − 0) px decimals
        CoreTypes.AssetDescriptor memory d = CoreTypes.AssetDescriptor({
            evmToken: address(lotok),
            evmDecimals: 8,
            coreToken: 2,
            spotMarket: 6,
            perpMarket: CoreTypes.NO_MARKET,
            coreWeiDecimals: 8,
            spotSzDecimals: 0,
            perpSzDecimals: 0,
            perpMaxLeverage: 0,
            fixedUsd: false
        });
        h.setup(d, usdcDescriptor(), address(oracle));
        hub.setUserExists(address(h), true);
        warpTo(Calendar.T + Calendar.W + 1); // terminal growth: target == growth
    }

    // ------------------------------------------------------------------ V8-M-4

    /// Audit PoC (V6-D-2 shape): a $10.50 spot BUY diff floors to a 1-lot order worth
    /// $6.06 at the limit price — below the $10 venue minimum. The engine must HOLD
    /// (snapshot no intent, emit nothing) and leave the funds for the next crank.
    function test_V9_M4_spot_buy_below_min_after_lot_floor_held() public {
        _setupLotok();
        h.setTargets(int256(Phi.WAD), 0); // spot-only target 1
        // v = $16.5 ($6 LOTOK + $10.5 USDC on Core): target − dirVal = $10.5 > $10 band,
        // but spend/limit floors to 1 lot: 10.5 / 6.06 = 1.73 → 1 lot = $6.06 < $10.
        h.setBuckets(1e8, 0, 0, 0, 1_050_000_000, 0, 0);
        hub.coreTopUp(address(h), USDC_CORE, 1_050_000_000);
        hub.setAuto(false, true, true); // queue venue actions for inspection

        assertFalse(h.planSync(), "dust order must be held, not dispatched");
        assertEq(uint8(h.intentKind()), uint8(B4VaultStorage.IntentKind.None), "no intent");
        assertEq(hub.pendingActions(), 0, "no order may reach the venue");
    }

    /// Sell side of V8-M-4: a $10.50 sell diff on the $6/lot asset floors to a 1-lot
    /// sell worth $5.94 at the limit price — sub-minimum; must hold as well.
    function test_V9_M4_spot_sell_below_min_after_lot_floor_held() public {
        _setupLotok();
        h.setTargets(0, 0); // zero target: sell everything
        // 1.75 LOTOK on Core = $10.5 > $10 band; floors to 1 lot = $5.94 < $10.
        h.setBuckets(0, 0, 0, 175_000_000, 0, 0, 0);
        hub.coreTopUp(address(h), 2, 175_000_000);
        hub.setAuto(false, true, true);

        assertFalse(h.planSync(), "dust sell must be held, not dispatched");
        assertEq(uint8(h.intentKind()), uint8(B4VaultStorage.IntentKind.None), "no intent");
        assertEq(hub.pendingActions(), 0, "no order may reach the venue");
    }

    // ------------------------------------------------------------------ V8-L-1

    /// The exit flatten calls _startPerpOrder directly with no planner-side mark check.
    /// A halted mark (px = 0) must HOLD the reduce-only order instead of emitting a
    /// limitPx == 0 IOC the live venue rejects (resend wedge mid-exit).
    function test_V9_L1_perp_order_held_at_zero_mark() public {
        hub.setMarkPx(PERP_MKT, 0); // mark feed outage mid-exit
        hub.setPosition(address(h), PERP_MKT, 100, 100 * MARK_PX);
        hub.setAuto(false, true, true);

        h.startPerpOrder(false, 100, true); // reduce-only close of 100 lots
        assertEq(
            uint8(h.intentKind()), uint8(B4VaultStorage.IntentKind.None), "no intent at a zero mark"
        );
        assertEq(hub.pendingActions(), 0, "no zero-price order may reach the venue");

        // Control: the guard only blocks a zero mark — a live mark emits normally.
        hub.setMarkPx(PERP_MKT, MARK_PX);
        h.startPerpOrder(false, 100, true);
        assertEq(
            uint8(h.intentKind()),
            uint8(B4VaultStorage.IntentKind.PerpOrder),
            "PerpOrder intent at a live mark"
        );
        assertEq(hub.pendingActions(), 1);
        (, bytes memory raw,) = hub.queue(hub.queueHead());
        (,, uint64 limitPx,,) = _decodeOrder(raw);
        assertGt(limitPx, 0, "live-mark order carries a real limit price");
    }

    // ------------------------------------------------------------------ V8-L-4

    /// After a venue-maxLev-clamped open, a mark rise shrinks maxSz = margin·maxLev/mark
    /// BELOW the held size. The clamp only limits NEW exposure: it must not reduce the
    /// HELD position (reduction is the marginNeed path's job only).
    function test_V9_L4_maxlev_clamp_does_not_shrink_held_position() public {
        // Clamped-open setup (mirrors V8A): the L-halving anchor is `floor` (the promoted
        // 62-min), not the current window's running low — audit H-4. Seeded at 99k so the
        // open at 100k still yields raw leverage ~161x and exercises the venue clamp.
        _seedFloorViaHalvingFlip(99_000);

        _setPx(100_000);
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 0, 120_000e6);
        crankUntilIdle(v, 60);

        CoreTypes.Position memory p0 = _readPos(address(v));
        assertGt(p0.szi, 0, "clamped long open");
        uint256 levWad = Phi.mulDiv(uint256(p0.entryNtl), Phi.WAD, v.perpMargin6());
        assertApproxEqRel(levWad, 40e18, 0.001e18, "open clamped at venue max leverage");

        // Mark doubles: maxSz halves to ~half the HELD size — the clamp must not trade.
        _setPx(200_000);
        crankUntilIdle(v, 40);

        assertEq(_readPos(address(v)).szi, p0.szi, "clamp must not shrink a held position");
    }

    // ------------------------------------------------------------------ V8-I-3 (pin)

    /// PIN of existing behavior (must pass before AND after the fix round): a PARTIAL
    /// perp reduce whose notional is below the $10 venue minimum is caught by the hold
    /// band (diff ≤ max(bps, MIN_ORDER) ⇒ no order), so no dust reduce-only order can
    /// wedge on the live venue's minimum. Setup: 1 lot = $9 at a 90k mark; the flat-φ
    /// target sits exactly 1 lot below the held 100 lots ($9 diff < $10 band).
    function test_V9_I3_sub_min_partial_reduce_held_by_band() public {
        h.setTargets(2e18, 0); // pure perp long (n = 2 ⇒ spot 0, perp 2)
        warpTo(Calendar.T + Calendar.W + 1); // target == growth
        _setPx(90_000); // 1 lot = 0.0001 BTC = $9 < $10

        // v = $445.50 ⇒ perp notional target 2·v = $891 ⇒ szTarget = 99 lots, one lot
        // below the held 100. marginNeed ≈ $36.04 < the $40 seeded, so no funding leg.
        h.setBuckets(0, 445_500_000, 0, 0, 0, 0, 40_000_000);
        hub.setPosition(address(h), PERP_MKT, 100, 100 * 9e6);
        hub.setAuto(false, true, true);

        assertFalse(h.planSync(), "sub-$10 partial reduce must be held by the band");
        assertEq(uint8(h.intentKind()), uint8(B4VaultStorage.IntentKind.None), "no dust reduce");
        (int64 szi,,) = hub.positions(address(h), PERP_MKT);
        assertEq(szi, 100, "position untouched");
    }

    // ------------------------------------------------------------------ V8-I-7

    /// _quantizePx8 narrows the quantized price with a truncating uint64 cast; above
    /// ~$1.8e11 the cast wraps mod 2^64 into a garbage limit price. The clamp must
    /// saturate at uint64.max instead (order still emitted, never a silent wrap).
    function test_V9_I7_quantize_px8_clamps_above_uint64() public {
        hub.setSpotPx(SPOT_MKT, uint64(2e15)); // $2e11 in (8 − 4) px decimals
        h.setBuckets(0, 0, 0, 1e4, 0, 0, 0); // 1 lot of UBTC on Core
        hub.setAuto(false, true, true);

        h.startSpotOrder(false, 1e4); // sell 1 lot: limit px = 0.99 × $2e11 = $1.98e11
        assertEq(
            uint8(h.intentKind()), uint8(B4VaultStorage.IntentKind.SpotOrder), "order still emitted"
        );
        (, bytes memory raw,) = hub.queue(hub.queueHead());
        (,, uint64 limitPx,,) = _decodeOrder(raw);
        assertEq(limitPx, type(uint64).max, "clamped at the ceiling, not truncated");
    }
}
