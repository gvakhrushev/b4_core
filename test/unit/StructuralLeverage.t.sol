// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StructuralLeverage} from "src/libraries/StructuralLeverage.sol";
import {Phi} from "src/libraries/Phi.sol";

/// @notice The structural-leverage math, pinned against real Bitcoin-cycle numbers. Every
///         case is the protocol's own function, so the historical demo cannot diverge from
///         what would be deployed.
contract StructuralLeverageTest is Test {
    uint256 constant WAD = 1e18;
    uint256 constant G = Phi.PHI; // Pro Max base leverage

    function _L(uint256 p, uint256 f, uint256 c) internal pure returns (uint256) {
        return StructuralLeverage.leverageWad(p * WAD, G, f * WAD, c * WAD);
    }

    // Assert leverage ≈ expected within 0.5%.
    function _approx(uint256 got, uint256 wantHundredths, string memory m) internal pure {
        uint256 want = wantHundredths * WAD / 100;
        assertApproxEqRel(got, want, 0.005e18, m);
    }

    // ------------------------------------------------------- genesis / degenerate

    /// floor == 0 (no window closed yet) ⇒ exactly the flat base leverage φ. No special path.
    function test_genesis_is_flat_phi() public pure {
        assertApproxEqRel(_L(5000, 0, 0), Phi.PHI, 0.001e18, "genesis Pro Max opens at phi");
    }

    /// p ≤ floor ⇒ refuse (0). A fall to the absolute prior low warrants no leverage.
    function test_refuse_at_or_below_floor() public pure {
        assertEq(_L(3504, 3504, 8790), 0, "p == floor refused");
        assertEq(_L(3000, 3504, 8790), 0, "p < floor refused");
    }

    // ------------------------------------------------------- the cap is load-bearing

    /// Segment-1 entries (floor = 2015 low 222, cap = 2019 low 3504). WITHOUT the cap a
    /// φ-long liquidates in the March-2020 crash (intraday low 3850); WITH the cap the stop
    /// is pinned to 3504 and it survives. This is the whole point of the ceiling.
    function test_covid_survival_cap_binds() public pure {
        uint256 june2019 = StructuralLeverage.stopWad(13838 * WAD, G, 222 * WAD, 3504 * WAD);
        uint256 feb2020 = StructuralLeverage.stopWad(10360 * WAD, G, 222 * WAD, 3504 * WAD);
        assertEq(june2019 / WAD, 3504, "stop capped to the 2019 bottom");
        assertEq(feb2020 / WAD, 3504, "stop capped to the 2019 bottom");
        // Both stops are below the COVID intraday low of 3850 ⇒ not stopped out.
        assertLt(june2019 / WAD, 3850, "survives COVID");
        assertLt(feb2020 / WAD, 3850, "survives COVID");
        // The uncapped stop would have been above the low ⇒ liquidated.
        uint256 uncapped = StructuralLeverage.stopWad(13838 * WAD, G, 222 * WAD, 0);
        assertGt(uncapped / WAD, 3850, "raw formula would have liquidated in COVID");
        _approx(_L(13838, 222, 3504), 134, "June-2019 L ~ 1.34");
        _approx(_L(10360, 222, 3504), 151, "Feb-2020 L ~ 1.51");
    }

    /// May-2021 (-53%) survival: a late peak entry (Apr-2021, 63044) sits above the cap
    /// (post-halving low 8790), so leverage is pinned low (~1.16) and the summer-2021 low
    /// (28600) never reaches the stop.
    function test_may2021_survival() public pure {
        uint256 stop = StructuralLeverage.stopWad(63044 * WAD, G, 3504 * WAD, 8790 * WAD);
        assertEq(stop / WAD, 8790, "late entry pinned to the post-halving low");
        assertLt(stop / WAD, 28600, "survives May-2021");
        _approx(_L(63044, 3504, 8790), 116, "Apr-2021 L ~ 1.16");
    }

    // ------------------------------------------------------- the post-halving flip

    /// At the 2020 halving the previous cap (3504) becomes the floor and the post-halving
    /// low (8790) becomes the cap. An entry at the halving price gets ~2.70× — leverage
    /// returns because the delta is now measured from a much higher, structurally proven low.
    function test_post_halving_flip_restores_leverage() public pure {
        _approx(_L(8759, 3504, 8790), 270, "at-halving L ~ 2.70");
        uint256 stop = StructuralLeverage.stopWad(8759 * WAD, G, 3504 * WAD, 8790 * WAD);
        assertEq(stop / WAD, 5511, "uncapped: cap (8790) does not bind here");
    }

    // ------------------------------------------------------- cap limits leverage, not entry

    /// A price that fell back BELOW a fresh low still opens — with the φ-formula from the
    /// floor, not a refusal (Feb-2019 dipped to 3359, under the still-forming 3504 low).
    function test_entry_below_fresh_low_opens() public pure {
        uint256 l = _L(3359, 222, 3504);
        assertGt(l, WAD, "opens with leverage, not refused");
        _approx(l, 173, "Feb-2019 dip L ~ 1.73");
    }

    /// Monotone: for a fixed (floor, cap), a higher entry price ⇒ lower leverage (the stop
    /// pins to the cap while the delta grows). This is the automatic late-entry de-risking.
    function test_higher_entry_lower_leverage() public pure {
        uint256 prev = type(uint256).max;
        uint16[6] memory ps = [16562, 20000, 30000, 45000, 55000, 65000];
        for (uint256 i = 0; i < ps.length; i++) {
            uint256 l = _L(ps[i], 3504, 16499);
            assertLe(l, prev, "leverage non-increasing in entry price");
            assertGe(l, WAD, "never below 1x");
            prev = l;
        }
    }

    /// Your worked example: p = 20k, floor = 10k, no cap ⇒ 2× from the delta, ×φ from the
    /// product ⇒ 3.236×.
    function test_worked_example_2x_times_phi() public pure {
        _approx(_L(20000, 10000, 0), 324, "20k/10k Pro Max ~ 3.24x");
    }
}
