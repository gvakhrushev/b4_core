// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {EngineHarness} from "../utils/EngineHarness.sol";
import {B4VaultStorage} from "src/core/B4VaultStorage.sol";
import {Phi} from "src/libraries/Phi.sol";
import {StructuralLeverage} from "src/libraries/StructuralLeverage.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";

/// @notice Engine-level regressions for structural leverage sizing (SPECIFICATION §7b):
///         the perp leg is amplified by the structural leverage, and — the core fix — a
///         position is sized once and HELD, so a pure price move no longer re-trades it.
contract StructuralSizingTest is VaultTestBase {
    EngineHarness g;
    MockToken cbtc;
    uint32 constant MKT = 6;
    uint32 constant PERP = 4;
    uint64 constant CORE = 2;

    function setUp() public {
        setUpProtocol(); // genesis t = 0 (growth zone)
        // A perp-bearing directional at $100k.
        cbtc = new MockToken();
        hub.registerToken(CORE, address(cbtc), 8, 2, 8, "CBTC");
        hub.registerSpotMarket(MKT, CORE, USDC_CORE);
        hub.registerPerpMarket(PERP, 4, 40, false);
        hub.setSpotPx(MKT, uint64(100_000 * 1e6)); // (8−2)=6 px decimals ⇒ $100k
        hub.setMarkPx(PERP, uint64(100_000 * 1e2)); // (6−4)=2 px decimals
        hub.setOraclePx(PERP, uint64(100_000 * 1e2));

        g = new EngineHarness();
        g.setup(_dir(), usdcDescriptor(), address(oracle));
        g.setTargets(int256(Phi.PHI), -int256(Phi.PHI)); // Pro Max
        hub.setUserExists(address(g), true);
        hub.setPosition(address(g), PERP, 0, 0); // flat
        hub.setWithdrawable(address(g), 0);
        // Manual venue execution: orders do NOT auto-fill, so the position stays exactly
        // where a test sets it and an order's size equals the full sizing target.
        hub.setAuto(false, true, true);
    }

    function _dir() internal view returns (CoreTypes.AssetDescriptor memory) {
        return CoreTypes.AssetDescriptor({
            evmToken: address(cbtc),
            evmDecimals: 8,
            coreToken: CORE,
            spotMarket: MKT,
            perpMarket: PERP,
            coreWeiDecimals: 8,
            spotSzDecimals: 2,
            perpSzDecimals: 4,
            perpMaxLeverage: 40,
            fixedUsd: false
        });
    }

    /// 10 BTC ($1M) directional on EVM (steady-state custody) + ample perp margin already
    /// posted, flat, growth regime (n = φ ⇒ spot 1, perp φ−1). Dir on EVM and margin already
    /// in the perp so the planner reaches the perp SIZING step directly (no spot repatriation,
    /// no margin top-up leg first).
    function _fund() internal {
        // dirEvm, rotEvm, marEvm, coreDir, coreRot, coreMar, perp6
        g.setBuckets(10e8, 0, 0, 0, 0, 0, 1_000_000e6);
        hub.setWithdrawable(address(g), 1_000_000e6); // matches recorded perp margin
    }

    // --------------------------------------------- structural leverage moves the SIZE

    /// With genesis anchors (0,0) the perp leg is the flat base (φ−1)·spot; with anchors that
    /// give a higher structural leverage, the SAME state sizes a strictly larger perp — the
    /// leverage moves the size, not just the margin.
    function test_structural_leverage_enlarges_perp() public {
        _fund();

        // Flat anchors → flat φ.
        g.setAnchors(0, 0);
        assertTrue(g.planSync());
        assertEq(uint8(g.intentKind()), uint8(B4VaultStorage.IntentKind.PerpOrder));
        uint64 flatSize = g.intentAmount();
        g.clearIntentForTest();

        // Structural anchors: floor 40k, cap 90k at a $100k entry ⇒ L ≈ 2.28× (> φ).
        uint256 lev = StructuralLeverage.leverageWad(100_000e18, Phi.PHI, 40_000e18, 90_000e18);
        assertGt(lev, Phi.PHI, "structural L exceeds phi here");
        g.setAnchors(40_000e18, 90_000e18);
        assertTrue(g.planSync());
        assertEq(uint8(g.intentKind()), uint8(B4VaultStorage.IntentKind.PerpOrder));
        uint64 structSize = g.intentAmount();

        assertGt(structSize, flatSize, "structural leverage sizes a bigger perp");
        // The ratio tracks (L−1)/(φ−1).
        assertApproxEqRel(
            uint256(structSize) * 1e18 / flatSize,
            (lev - Phi.WAD) * 1e18 / (Phi.PHI - Phi.WAD),
            0.02e18,
            "size scales by (L-1)/(phi-1)"
        );
    }

    // --------------------------------------------- sized once, then HELD

    /// The core fix: after the perp is sized, a pure price move does NOT re-trade it. The
    /// old NAV-relative sizing recomputed the target against the live price every crank and
    /// would resize on any move; the frozen sizing price makes the size invariant to price.
    function test_position_not_resized_on_price_move() public {
        _fund();
        g.setAnchors(0, 0);

        // Size the perp and record the frozen price + size.
        assertTrue(g.planSync());
        assertEq(uint8(g.intentKind()), uint8(B4VaultStorage.IntentKind.PerpOrder));
        uint64 size = g.intentAmount();
        assertEq(g.sizePxWad(), 100_000e18, "sizing price frozen at entry");
        g.clearIntentForTest();

        // Simulate the fill: the position now holds `size`.
        hub.setPosition(address(g), PERP, int64(size), uint64(size));

        // BTC rips +60%. Under the old model this inflates NAV → a bigger perp target → a
        // resize. Under the held model the frozen price keeps the size target put.
        hub.setSpotPx(MKT, uint64(160_000 * 1e6));
        hub.setMarkPx(PERP, uint64(160_000 * 1e2));
        hub.setOraclePx(PERP, uint64(160_000 * 1e2));

        bool progressed = g.planSync();
        // No new perp order: the size is held. (planSync may still do margin/return work,
        // but it must NOT open/resize the perp.)
        assertTrue(
            g.intentKind() != B4VaultStorage.IntentKind.PerpOrder,
            "price move must not resize the held perp"
        );
        assertEq(g.sizePxWad(), 100_000e18, "sizing price stays frozen through the move");
        progressed; // (a margin/return step may legitimately progress; the perp is untouched)
    }

    /// The frozen price resets when the position closes to raw zero, so the next open is
    /// sized fresh at the current price (not the stale one).
    function test_size_price_resets_when_flat() public {
        _fund();
        g.setAnchors(0, 0);
        g.planSync();
        assertEq(g.sizePxWad(), 100_000e18);
        g.clearIntentForTest();

        // Position closed back to raw zero, price moved.
        hub.setPosition(address(g), PERP, 0, 0);
        hub.setSpotPx(MKT, uint64(50_000 * 1e6));
        hub.setMarkPx(PERP, uint64(50_000 * 1e2));
        hub.setOraclePx(PERP, uint64(50_000 * 1e2));

        g.planSync(); // sizes fresh
        assertEq(g.sizePxWad(), 50_000e18, "re-captured at the new price after going flat");
    }
}

/// Minimal ERC20 for the directional token (the harness only needs an address + decimals).
contract MockToken {
    uint8 public constant decimals = 8;

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }
}
