// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {EngineHarness} from "../utils/EngineHarness.sol";
import {MockERC20} from "../mocks/MockCore.sol";
import {B4VaultStorage} from "src/core/B4VaultStorage.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {Phi} from "src/libraries/Phi.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";

/// @notice V6 Scope D PoCs: venue-minimum / residual-position / zero-mark gaps.
///         All findings are engine-vs-venue-rule mismatches that MockCoreHub hides because
///         it enforces NEITHER the $10 minimum order notional NOR price validity.
contract V6DVenueGapsTest is VaultTestBase {
    EngineHarness h;

    function setUp() public {
        setUpProtocol();
        h = new EngineHarness();
        h.setup(ubtcDescriptor(), usdcDescriptor(), address(oracle));
        hub.setUserExists(address(h), true);
    }

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

    /// V6-D-1, TRANSFORMED (V8-L-8 / V6-M-3 closed): a same-sign residual perp position
    /// whose notional floors below the $10 venue minimum can no longer wedge the vault.
    /// The current `_planSyncStep` characterizes the three cases faithfully:
    ///   (1) perpF == 0 (policy target zero): step 1 emits a FULL `|szi|` reduce-only close
    ///       regardless of notional — exact-closing reduce-only orders are exempt from the
    ///       $10 minimum (verified against venue docs, V6) — so even a sub-$10 residual
    ///       closes and its margin returns (to the ROTATION bucket as strategy capital,
    ///       post pure-perp routing), satisfying A10 flatness.
    ///   (2) same-sign residual OFF target by more than the band: reduced normally toward
    ///       the target — "never closed" is false.
    ///   (3) same-sign residual within one band step of the target: a deliberate ON-TARGET
    ///       HOLD (no dust order churn below the venue minimum) — not a wedge: the
    ///       exposure IS the policy target within tolerance, and a later zero-target
    ///       regime closes it via case (1).
    function test_residual_perp_position_below_min_order() public {
        // ---------------------------------------------------------------- (1) zero target
        h.setTargets(int256(Phi.WAD), 0); // growth target 1 → decompose: spot 1, perp 0
        warpTo(Calendar.T + Calendar.W + 1); // growth plateau
        // A SUB-$10 residual long: mark $5,000 ⇒ 7 lots = 0.0007 BTC = $3.50 < $10.
        hub.setMarkPx(PERP_MKT, 5_000e2);
        hub.setOraclePx(PERP_MKT, 5_000e2);
        hub.setPosition(address(h), PERP_MKT, 7, 7 * 5_000e2); // entry at the mark: no PnL
        h.setBuckets(0, 0, 0, 0, 0, 0, 5e6); // $5 recorded margin, wd matches
        hub.setWithdrawable(address(h), 5e6);
        hub.setAuto(false, true, true); // queue the action for inspection

        assertTrue(h.planSync(), "zero target with a residual: the close IS emitted");
        assertEq(
            uint8(h.intentKind()),
            uint8(B4VaultStorage.IntentKind.PerpOrder),
            "close intent created"
        );
        (, bytes memory raw,) = hub.queue(hub.queueHead());
        (uint32 asset, bool isBuy,, uint64 sz, bool reduceOnly) = _decodeOrder(raw);
        assertEq(asset, PERP_MKT);
        assertFalse(isBuy, "sell to close the long");
        assertEq(sz, 7e4, "FULL residual closed (7 lots in 1e8 writer size), no min-order clamp");
        assertTrue(reduceOnly, "exact-closing reduce-only: exempt from the $10 minimum");

        // Fill it and drive the margin all the way home (new routing: back to ROTATION as
        // strategy capital, satisfying A10 — the old test's "margin locked forever" is gone).
        hub.setAuto(true, true, true);
        hub.executeActions();
        for (uint256 i; i < 10 && h.planSync(); i++) {}
        (int64 szi,,) = hub.positions(address(h), PERP_MKT);
        assertEq(szi, 0, "sub-$10 residual closed to raw zero");
        assertEq(h.perpMargin6(), 0, "margin fully returned");
        assertEq(h.coreUsdcMarginWei(), 0);
        assertEq(h.usdcMarginEvm(), 0, "nothing parks in the owner reserve");
        assertEq(h.usdcRotatedEvm(), 5e6, "margin is strategy capital again (rotation bucket)");

        // ------------------------------------------------- (2) same-sign, OFF target: reduced
        hub.setMarkPx(PERP_MKT, MARK_PX); // back to $100k
        hub.setOraclePx(PERP_MKT, MARK_PX);
        h.setTargets(int256(Phi.PHI), 0); // growth target φ → perpF = φ (pure perp long)
        h.setBuckets(0, 12e6, 0, 0, 0, 0, 5e6); // v = $12 rotated ⇒ target ≈ $19.4 ≈ 1 lot
        hub.setPosition(address(h), PERP_MKT, 7, 7 * MARK_PX); // 7 lots held: 6 lots off target
        hub.setWithdrawable(address(h), 5e6);
        hub.setAuto(false, true, true);

        assertTrue(h.planSync(), "off-target residual is reduced, never wedged");
        (, raw,) = hub.queue(hub.queueHead());
        (asset, isBuy,, sz, reduceOnly) = _decodeOrder(raw);
        assertEq(asset, PERP_MKT);
        assertFalse(isBuy);
        assertEq(sz, 6e4, "reduced by exactly the 6 off-target lots");
        assertTrue(reduceOnly);
        hub.setAuto(true, true, true);
        hub.executeActions();
        assertTrue(h.planSync(), "verify the reduce fill");
        (szi,,) = hub.positions(address(h), PERP_MKT);
        assertEq(szi, 1, "position now at the floored target");

        // ------------------------------------------------- (3) same-sign dust: on-target hold
        hub.setPosition(address(h), PERP_MKT, 2, 2 * MARK_PX); // 2 lots vs 1-lot target:
        // diff = 1 lot = $10 ≤ band (max(1% of v, $10)) — a deliberate hold, no dust churn.
        hub.setAuto(false, true, true);
        for (uint256 i; i < 25; i++) {
            assertFalse(h.planSync(), "within-band dust: planner holds (on-target, no wedge)");
            assertEq(uint8(h.intentKind()), 0, "no intent may be created");
            assertEq(hub.pendingActions(), 0, "no dust order may reach the venue");
        }
        (szi,,) = hub.positions(address(h), PERP_MKT);
        assertEq(szi, 2, "on-target dust untouched");
        assertEq(h.perpMargin6(), 5e6, "margin backs an on-target position, not locked");
    }

    /// V6-D-2 (FIXED by V8-M-4): the engine enforced the $10 venue minimum only as a
    /// no-trade BAND on the USD diff, never as a floor on the EMITTED order, so after
    /// lot flooring a sub-minimum order was dispatched (live rejection → H3 wedge).
    /// The engine now re-checks the floored order's notional and HOLDS instead.
    function test_spot_order_below_venue_minimum_held() public {
        // Venue-legal fine asset: szDecimals = 0, px $6 ⇒ one lot = $6 < $10.
        MockERC20 lotok = new MockERC20("LOTOK", 8);
        hub.registerToken(2, address(lotok), 8, 0, 8, "LOTOK");
        hub.registerSpotMarket(6, 2, USDC_CORE);
        hub.setSpotPx(6, 6e8); // $6 in (8 − 0) decimals
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
        h.setTargets(int256(Phi.WAD), 0); // spot-only target 1
        warpTo(Calendar.T + Calendar.W + 1);

        // v = $16.5 ($6 in LOTOK + $10.5 USDC on Core); target − dirVal = $10.5 > $10 band.
        h.setBuckets(1e8, 0, 0, 0, 1_050_000_000, 0, 0); // 1 LOTOK + 10.5 USDC(core)
        hub.coreTopUp(address(h), USDC_CORE, 1_050_000_000); // the mock's actual Core balance
        hub.setAuto(false, true, true); // queue the action for inspection

        // Post-fix: the floored 1-lot ($6.06) order is below the $10 minimum ⇒ held.
        assertFalse(h.planSync(), "dust order must be held, not dispatched");
        assertEq(uint8(h.intentKind()), 0, "no intent may be created");
        assertEq(hub.pendingActions(), 0, "no order may reach the venue");
    }

    /// V6-D-3 (FIXED by V8-L-1): _startPerpOrder had NO zero-mark guard (unlike
    /// _startSpotOrder, which holds on pxWad == 0), so a zero/halted mark read emitted a
    /// reduce-only order with limitPx 0 the live venue rejects (resend wedge, H3). The
    /// guard is now mirrored: both sides HOLD on a zero price read.
    function test_perp_order_zero_mark_held() public {
        // Spot side HOLDS on a zero price read (the correct asymmetry baseline).
        hub.setSpotPx(SPOT_MKT, 0);
        h.setBuckets(0, 0, 0, 0, 1e8, 0, 0);
        h.startSpotOrder(true, 1e8);
        assertEq(uint8(h.intentKind()), 0, "spot order held on zero px");

        // Perp side now holds identically: no intent, no px-0 order reaches the venue.
        hub.setMarkPx(PERP_MKT, 0);
        hub.setPosition(address(h), PERP_MKT, 100, 100 * MARK_PX); // entry notional 1e9 (1e6 USD)
        hub.setWithdrawable(address(h), 100 * MARK_PX);
        hub.setAuto(false, true, true);
        h.startPerpOrder(false, 100, true); // reduce-only close of 100 lots

        assertEq(uint8(h.intentKind()), 0, "perp order held on zero mark");
        assertEq(hub.pendingActions(), 0, "no zero-price order may reach the venue");
    }
}
