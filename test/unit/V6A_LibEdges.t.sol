// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Phi} from "src/libraries/Phi.sol";
import {StructuralLeverage} from "src/libraries/StructuralLeverage.sol";

/// @title V6-A -- StructuralLeverage pure-math edge cases: long/short asymmetry on g <= WAD,
///        the stopWad/leverageWad divergence at the rounding boundary, the 1-wei
///        discontinuity above the floor, and the unbounded short window regime.
contract V6A_LibEdgesTest is Test {
    uint256 constant G = uint256(Phi.PHI);
    uint256 constant WAD = 1e18;

    /// Long side does NOT guard g <= WAD: a sub-1x product base (g = 0.5) still returns
    /// L >= 1x -- the lib would AMPLIFY a product whose policy is de-levered. The short side
    /// refuses the same input (`g <= Phi.WAD` -> 0). Duplicated-guard drift between the
    /// mirrored implementations.
    function test_long_side_accepts_sub_1x_base_short_side_refuses() public {
        uint256 l = StructuralLeverage.leverageWad(100e18, 0.5e18, 50e18, 0);
        assertEq(l, WAD, "long: g=0.5 still yields 1x (>= g) -- no g<=WAD guard");
        uint256 s = StructuralLeverage.shortStopWad(100e18, 0.5e18, 80e18, 0);
        assertEq(s, 0, "short: g=0.5 refused -- asymmetric guard");
    }

    /// stopWad lacks leverageWad's `stop >= p` branch: with a 1-wei delta, `drop` rounds to
    /// 0 and stopWad returns stop == p (liquidation AT the entry price) while leverageWad
    /// returns WAD (1x). The two functions disagree on the same inputs -- the duplication the
    /// docs say "cannot drift" already has divergent edge semantics.
    function test_stopWad_returns_entry_price_at_rounding_boundary() public {
        uint256 p = 100_000e18;
        uint256 stop = StructuralLeverage.stopWad(p, G, p - 1, 0);
        assertEq(stop, p, "stopWad: liquidation priced AT entry");
        uint256 l = StructuralLeverage.leverageWad(p, G, p - 1, 0);
        assertEq(l, WAD, "leverageWad: same inputs => 1x");
    }

    /// 1-wei discontinuity above the floor: delta = 1 wei -> L = 1x; delta = 2 wei ->
    /// drop rounds to 1, stop = p-1, L = p/1 wei = 1e5 x 1e18. Any redo clamp must handle
    /// outputs differing by 23 orders of magnitude on adjacent inputs.
    function test_one_wei_discontinuity_above_floor() public {
        uint256 p = 100_000e18;
        uint256 l1 = StructuralLeverage.leverageWad(p, G, p - 1, 0);
        uint256 l2 = StructuralLeverage.leverageWad(p, G, p - 2, 0);
        assertEq(l1, WAD, "delta=1 wei: 1x");
        assertEq(l2, p * WAD, "delta=2 wei: 100,000x in WAD terms");
    }

    /// Window-regime short is unbounded as p -> prevPeak (documented caveat) and has the
    /// mirror-image rounding cliff: p = prevPeak+3 wei already yields ~1e20x; p = prevPeak+1
    /// rounds stop-p to 0 and is REFUSED (0 -> flat-base fallback). No clamp exists in the
    /// lib; "venue maxLeverage is the hard ceiling" is enforceable only by the (unwritten)
    /// redo, and the AUDIT-2026-07 redo requirements do not list the clamp.
    function test_short_window_regime_unbounded_with_rounding_cliff() public {
        uint256 prevPeak = 100_000e18;
        uint256 lRefused = StructuralLeverage.shortLeverageWad(prevPeak + 1, G, prevPeak, 0);
        assertEq(lRefused, 0, "p = prevPeak+1: stop-p rounds to 0 => refused");
        uint256 lHuge = StructuralLeverage.shortLeverageWad(prevPeak + 3, G, prevPeak, 0);
        assertGt(lHuge, 1e22, "p = prevPeak+3: >1e4 x leverage, no clamp in the lib");
    }

    /// Refute the phantom-overflow hypothesis at reachable magnitudes: the largest WAD price
    /// a descriptor can produce is uint64-max raw at szDecimals = 8, i.e. ~1.8e37. Even with
    /// a 1-wei stop distance, mulDiv's 512-bit path returns instead of overflowing.
    function test_no_phantom_overflow_at_venue_reachable_prices() public {
        uint256 p = uint256(type(uint64).max) * WAD; // szDecimals = 8 extreme: ~1.8e37
        uint256 l = StructuralLeverage.leverageWad(p, G, p - 1e18, 0);
        assertGt(l, WAD, "no revert at venue-reachable extremes");
    }

    /// leverageWad's WAD floor: L can never sit BETWEEN 0 and 1x for the long (returns WAD
    /// instead). Documented; pinned so the redo notices if it changes.
    function test_long_side_wad_floor_pinned() public {
        uint256 l = StructuralLeverage.leverageWad(100e18, G, 99.9e18, 99.95e18);
        assertGe(l, WAD, "long side never returns sub-1x");
    }
}
