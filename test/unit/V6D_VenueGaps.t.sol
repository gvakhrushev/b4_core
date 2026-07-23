// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {EngineHarness} from "../utils/EngineHarness.sol";
import {MockERC20} from "../mocks/MockCore.sol";
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

    /// V6-D-1: a same-sign residual perp position whose notional TARGET floors below the
    /// $10 venue minimum is NEVER closed in sync mode. _planPerpStep clamps the target to
    /// zero, then its zero-target branch only handles the strictly-flat case — a non-zero
    /// position falls through untouched, so the vault rides an exposure its policy says
    /// should be zero, and the recorded margin can never be returned (A10 requires flat).
    function test_residual_perp_position_never_closed_below_min_order() public {
        vm.skip(true); // PENDING pure-perp redesign: scenario tied to old decompose/routing; rework after step-3 sizing (docs/design/PROPOSAL-pure-perp-promax.md)
        h.setTargets(int256(Phi.PHI), 0); // growth: spot 1 + perp (φ−1) ≈ 0.618
        warpTo(Calendar.T + Calendar.W + 1); // growth plateau → target = growth

        // Strategy value $12 (spot side exactly on target so no spot step interferes):
        // 0.00012 BTC @ $100k = $12; notional target = 12 × 0.618 ≈ $7.42 < $10 ⇒ clamped 0.
        h.setBuckets(12_000, 0, 0, 0, 0, 0, 5e6); // perpMargin6 = $5 recorded
        hub.setPosition(address(h), PERP_MKT, 7, 7 * MARK_PX); // 7 lots ≈ $700 residual long

        for (uint256 i = 0; i < 25; i++) {
            assertFalse(h.planSync(), "planner must not act");
            assertEq(uint8(h.intentKind()), 0, "no intent may be created");
        }
        (int64 szi,,) = hub.positions(address(h), PERP_MKT);
        assertEq(szi, 7, "residual position still open after 25 cranks");
        assertEq(h.perpMargin6(), 5e6, "margin locked forever (A10 flatness never reached)");
    }

    /// V6-D-2: the engine enforces the $10 venue minimum only as a no-trade BAND on the
    /// USD diff, never as a floor on the EMITTED order. After lot flooring, a spot order
    /// can be emitted below the venue minimum; MockCoreHub fills it (no min-size rule),
    /// while the live venue rejects it → zero delta → resend-forever wedge (H3).
    function test_spot_order_emitted_below_venue_minimum() public {
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

        assertTrue(h.planSync(), "planner emits a spot buy");
        assertEq(hub.pendingActions(), 1);
        (, bytes memory raw,) = hub.queue(hub.queueHead());
        (uint32 asset,,, uint64 sz8,) = _decodeOrder(raw);
        assertEq(asset, CoreTypes.SPOT_ASSET_OFFSET + 6);
        assertEq(sz8, 1e8, "one lot"); // 1 lot × $6 = $6 notional < $10 venue minimum
        // The mock FILLS the venue-illegal order, hiding the live rejection wedge.
        hub.executeActions();
        assertEq(hub.spotBal(address(h), 2), 1e8, "mock filled a sub-$10 order");
    }

    /// V6-D-3: _startPerpOrder has NO zero-mark guard (unlike _startSpotOrder, which holds
    /// on pxWad == 0). A zero/halted mark read emits a reduce-only order with limitPx 0;
    /// MockCoreHub then "fills" it at px 0 and books the ENTIRE entry notional as a loss.
    /// On the live venue a px-0 order is rejected → the flatten resends forever (H3).
    function test_perp_order_zero_mark_no_guard() public {
        // Spot side HOLDS on a zero price read (the correct asymmetry baseline).
        hub.setSpotPx(SPOT_MKT, 0);
        h.setBuckets(0, 0, 0, 0, 1e8, 0, 0);
        h.startSpotOrder(true, 1e8);
        assertEq(uint8(h.intentKind()), 0, "spot order held on zero px");

        // Perp side FIRES on a zero mark read.
        hub.setMarkPx(PERP_MKT, 0);
        hub.setPosition(address(h), PERP_MKT, 100, 100 * MARK_PX); // entry notional 1e9 (1e6 USD)
        hub.setWithdrawable(address(h), 100 * MARK_PX);
        hub.setAuto(false, true, true);
        h.startPerpOrder(false, 100, true); // reduce-only close of 100 lots

        assertEq(uint8(h.intentKind()), uint8(8), "PerpOrder intent created despite mark == 0");
        (, bytes memory raw,) = hub.queue(hub.queueHead());
        (,, uint64 limitPx,,) = _decodeOrder(raw);
        assertEq(limitPx, 0, "zero-price order emitted to the venue");

        hub.executeActions(); // mock fills at px 0: catastrophic mock-world loss
        assertEq(hub.wd(address(h)), 0, "entire entry notional booked as loss at px 0");
    }
}
