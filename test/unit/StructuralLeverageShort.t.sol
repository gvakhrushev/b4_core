// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StructuralLeverage} from "src/libraries/StructuralLeverage.sol";
import {Phi} from "src/libraries/Phi.sol";

/// @notice Pins the SHORT side of the structural mechanism (SPECIFICATION §7b) to the
///         owner-verified numbers. Anchors are the confirmed peak-window maxima:
///         C1 $666, C2 $16,773, C3 $67,774, C4 $115,265 (max close over the 20-day window
///         ending at each cycle's 38.2% pivot, real BTC data).
contract StructuralLeverageShortTest is Test {
    uint256 constant PHI = Phi.PHI;
    uint256 constant WAD = 1e18;

    // Canonical peak anchors (WAD dollars).
    uint256 constant C2 = 16_773e18;
    uint256 constant C3 = 67_774e18;
    uint256 constant C4 = 115_265e18;

    // ------------------------------------------------------------- window regime

    /// Owner's worked window slice: entry $104k, prevPeak $67k →
    /// stop = 104,000 + 37,000·0.618 = $126,867, L ≈ 4.55×.
    function test_window_slice_owner_example() public pure {
        uint256 stop = StructuralLeverage.shortStopWad(104_000e18, PHI, 67_000e18, 0);
        assertApproxEqRel(stop, 126_867e18, 0.001e18, "window stop");
        uint256 l = StructuralLeverage.shortLeverageWad(104_000e18, PHI, 67_000e18, 0);
        assertApproxEqRel(l, 4.548e18, 0.01e18, "window leverage");
    }

    /// Window slices at rising prices place rising stops (each slice sized independently).
    function test_window_slices_monotone() public pure {
        uint256 s1 = StructuralLeverage.shortStopWad(104_000e18, PHI, 67_000e18, 0);
        uint256 s2 = StructuralLeverage.shortStopWad(109_000e18, PHI, 67_000e18, 0);
        uint256 s3 = StructuralLeverage.shortStopWad(114_000e18, PHI, 67_000e18, 0);
        assertLt(s1, s2);
        assertLt(s2, s3);
        assertApproxEqRel(s3, 143_048e18, 0.001e18, "top slice stop (owner: ~143k)");
    }

    // ------------------------------------------------------------- post-pivot regime

    /// Owner's worked post-pivot case: prevPeak $67k, C $115k ⇒ MaxStop ≈ $144.7k;
    /// entry $97k → stop ≈ $126.5k, L ≈ 3.29×.
    function test_post_pivot_owner_example() public pure {
        uint256 stop = StructuralLeverage.shortStopWad(97_000e18, PHI, 67_000e18, 115_000e18);
        assertApproxEqRel(stop, 126_459e18, 0.001e18, "post stop (owner: ~126k)");
        uint256 l = StructuralLeverage.shortLeverageWad(97_000e18, PHI, 67_000e18, 115_000e18);
        assertApproxEqRel(l, 3.293e18, 0.01e18, "post leverage");
    }

    /// Canonical cycle 4 at the pivot price $108,306: L ≈ 4.83×, and the stop clears the
    /// entire realized fall (post-pivot max close $110,530 — the stop is never touched).
    function test_cycle4_pivot_entry_survives_fall() public pure {
        uint256 stop = StructuralLeverage.shortStopWad(108_306e18, PHI, C3, C4);
        assertApproxEqRel(stop, 130_748e18, 0.001e18, "cycle-4 pivot stop");
        assertGt(stop, 110_530e18, "stop clears the realized post-pivot maximum");
        uint256 l = StructuralLeverage.shortLeverageWad(108_306e18, PHI, C3, C4);
        assertApproxEqRel(l, 4.826e18, 0.01e18, "cycle-4 pivot leverage");
    }

    /// Post-pivot leverage DECREASES monotonically with depth — deeper entry, less leverage.
    function test_post_pivot_monotone_decreasing() public pure {
        uint256 prev = type(uint256).max;
        uint256[5] memory entries =
            [uint256(115_000e18), 108_306e18, 97_000e18, 80_000e18, 60_000e18];
        for (uint256 i = 0; i < entries.length; i++) {
            uint256 l = StructuralLeverage.shortLeverageWad(entries[i], PHI, C3, C4);
            assertGt(l, 0);
            assertLt(l, prev, "leverage must fall with entry depth");
            prev = l;
        }
    }

    /// Deep entry pins the stop to the confirmed peak C and sizes BELOW 1× — deliberately.
    /// The sub-1× size with the far stop is the safety, so no 1× floor is applied.
    function test_deep_entry_pins_to_C_sub_1x() public pure {
        uint256 stop = StructuralLeverage.shortStopWad(50_000e18, PHI, C3, C4);
        assertEq(stop, C4, "deep entry pins to the confirmed peak");
        uint256 l = StructuralLeverage.shortLeverageWad(50_000e18, PHI, C3, C4);
        assertLt(l, WAD, "sub-1x by design");
        assertApproxEqRel(l, 0.766e18, 0.01e18);
    }

    /// An entry ABOVE the confirmed peak boosts leverage past the flat base (the mirror of
    /// the long entering below the recorded low).
    function test_entry_above_C_boosts() public pure {
        uint256 l = StructuralLeverage.shortLeverageWad(120_000e18, PHI, C3, C4);
        assertGt(l, PHI, "above-C entry exceeds flat phi");
        assertApproxEqRel(l, 7.888e18, 0.01e18);
    }

    // ------------------------------------------------------------- survival regression

    /// The February-2018 bear rally (+99%: $5,921 → $11,780) LIQUIDATES a flat-φ short
    /// (stop $5,921·φ = $9,580 < $11,780) — the structural stop, pinned above the confirmed
    /// peak region, clears the rally and survives. This is why deep shorts must de-lever.
    function test_bear_rally_2018_flat_phi_dies_structural_survives() public pure {
        uint256 entry = 5_921e18;
        uint256 rallyHigh = 11_780e18;
        // Flat-φ stop sits inside the rally: liquidated.
        uint256 flatStop = Phi.mulDiv(entry, PHI, WAD);
        assertLt(flatStop, rallyHigh, "flat-phi short is liquidated by the rally");
        // Structural stop (anchors C1=$666, C2=$16,773) sits far above it: survives.
        uint256 stop = StructuralLeverage.shortStopWad(entry, PHI, 666e18, C2);
        assertGt(stop, rallyHigh, "structural stop clears the +99% rally");
    }

    // ------------------------------------------------------------- fallbacks & refusals

    /// No previous peak recorded (genesis) → 0 → the caller uses the flat base, exactly as
    /// the long side does before its first window closes.
    function test_genesis_falls_back_flat() public pure {
        assertEq(StructuralLeverage.shortLeverageWad(650e18, PHI, 0, 666e18), 0);
        assertEq(StructuralLeverage.shortLeverageWad(650e18, PHI, 0, 0), 0);
    }

    /// Entry at/above MaxStop is refused; an unconfirmed pair (C ≤ prevPeak) falls back;
    /// a base of 1 (Pro's full short) never uses the structural path.
    function test_refusals() public pure {
        // MaxStop for (C3, C4) ≈ $144,617: an entry there or above is refused.
        assertEq(StructuralLeverage.shortLeverageWad(150_000e18, PHI, C3, C4), 0);
        assertEq(StructuralLeverage.shortLeverageWad(50_000e18, PHI, C4, C3), 0);
        assertEq(StructuralLeverage.shortLeverageWad(50_000e18, WAD, C3, C4), 0);
        // Window entry below the previous peak: no positive delta.
        assertEq(StructuralLeverage.shortLeverageWad(60_000e18, PHI, C3, 0), 0);
    }

    /// stop/leverage consistency: L = p/(stop − p) at arbitrary points, both regimes.
    function test_stop_leverage_consistency() public pure {
        uint256[2] memory ps = [uint256(90_000e18), 108_306e18];
        for (uint256 i = 0; i < ps.length; i++) {
            uint256 stop = StructuralLeverage.shortStopWad(ps[i], PHI, C3, C4);
            uint256 l = StructuralLeverage.shortLeverageWad(ps[i], PHI, C3, C4);
            assertApproxEqRel(l, Phi.mulDiv(ps[i], WAD, stop - ps[i]), 0.0001e18);
        }
    }
}
