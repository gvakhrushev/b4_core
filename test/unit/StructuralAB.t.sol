// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StructuralLeverage} from "src/libraries/StructuralLeverage.sol";

/// @notice AB acceptance tests — the owner's worked numbers (docs/design/STRUCTURAL-STATE-MACHINE.md §4).
///         Pure math: the library is "correct" for a row when it reproduces the number. The DCA /
///         halving-add / engine wiring is exercised separately.
///         V8-L-6: every §4 row is pinned at the EXACT WAD value the library produces — the
///         floor fixed-point semantics (Phi.mulDiv / wmul with INV_PHI = 618033988749894848)
///         are deterministic, so each expectation was recomputed independently from the §2/§3
///         formulas and asserted with zero tolerance. The previous 1% tolerance was ~7x the
///         widest owner-rounding (0.136%, PM3) and passed a systematic +0.4% theta error on
///         every phi-bearing pin; exact pins cannot pass under ANY formula drift. PM5/PM6/PM7
///         are added: PM5/PM7 are the exact `B4VaultEngine._longStopWad` calls for L-halving
///         (`longStop(p, B, 0)`) and L-rise (`longStop(p, 0, 0)`); PM6 locks the documented
///         interim (the L-rise ratchet floor is not wired, §5 "Remaining refinements").
contract StructuralABTest is Test {
    uint256 constant WAD = 1e18;
    uint256 constant G1 = 1e18; // Pro base g = 1

    function usd(uint256 x) internal pure returns (uint256) {
        return x * WAD;
    }

    // ---------- Pro short: flat 2p floored at C (one anchor) ----------
    function test_P1_pro_short_window_flat_2p() public {
        // doc: stop 8000, L 1x — both exact (integer arithmetic, no rounding).
        assertEq(StructuralLeverage.shortFlatStop(usd(4000), G1, 0), usd(8000), "P1 stop=2p");
        assertEq(StructuralLeverage.shortFlatLev(usd(4000), G1, 0), WAD, "P1 L=1x");
    }

    function test_P2_pro_short_post_above_C() public {
        // doc: stop 10000 (2p > C), L 1x — exact.
        assertEq(
            StructuralLeverage.shortFlatStop(usd(5000), G1, usd(4200)), usd(10000), "P2 stop=2p"
        );
        assertEq(StructuralLeverage.shortFlatLev(usd(5000), G1, usd(4200)), WAD, "P2 L=1x");
    }

    function test_P3_pro_short_post_pinned_to_C() public {
        // doc: stop 4200 (pinned to C), L 0.91 — exact L = floor(2000/2200 * 1e18).
        assertEq(StructuralLeverage.shortFlatStop(usd(2000), G1, usd(4200)), usd(4200), "P3 stop=C");
        assertEq(
            StructuralLeverage.shortFlatLev(usd(2000), G1, usd(4200)),
            909090909090909090,
            "P3 L=0.(90) exact"
        );
    }

    // ---------- Pro Max short: structural (Pp, C) ----------
    function test_PM1_promax_short_window() public {
        // doc: stop 5854 = p + (p-Pp)/phi — exact 5854.101966249684544 (the /phi drop is
        // floor(3000 * INV_PHI) = 1854.101966249684544 exactly).
        assertEq(
            StructuralLeverage.shortStructStop(usd(4000), usd(1000), 0),
            5854101966249684544000,
            "PM1 stop exact"
        );
        // doc: L 2.16 — exact floor(4000e18 / 1854.101966...e18 * 1e18).
        assertEq(
            StructuralLeverage.shortStructLev(usd(4000), usd(1000), 0),
            2157378651666526464,
            "PM1 L exact"
        );
    }

    function test_PMs1_promax_short_post_shallow() public {
        // doc: fixed maxStop 5854, L 5.85x — same fixed stop as PM1 (anchor is C now).
        assertEq(
            StructuralLeverage.shortStructStop(usd(5000), usd(1000), usd(4000)),
            5854101966249684544000,
            "PMs1 stop exact"
        );
        assertEq(
            StructuralLeverage.shortStructLev(usd(5000), usd(1000), usd(4000)),
            5854101966249684548,
            "PMs1 L exact"
        );
    }

    function test_PMs2_promax_short_post_deep_sub1x() public {
        // doc: SAME fixed maxStop, sub-1x deep — L 0.52.
        assertEq(
            StructuralLeverage.shortStructStop(usd(2000), usd(1000), usd(4000)),
            5854101966249684544000,
            "PMs2 stop exact"
        );
        assertEq(
            StructuralLeverage.shortStructLev(usd(2000), usd(1000), usd(4000)),
            518927630227215371,
            "PMs2 L exact"
        );
        assertEq(
            StructuralLeverage.shortStructStop(usd(5000), usd(1000), usd(4000)),
            StructuralLeverage.shortStructStop(usd(2000), usd(1000), usd(4000)),
            "post-pivot stop is FIXED, independent of entry"
        );
    }

    // ---------- Pro Max long: structural (Pb, B) — the mirror ----------
    function test_PM2_promax_long_window() public {
        // doc: stop 444 = p - (p-Pb)/phi — exact 443.7694101250946368 (drop
        // floor(900 * INV_PHI) = 556.2305898749053632 exactly).
        assertEq(
            StructuralLeverage.longStop(usd(1000), usd(100), 0),
            443769410125094636800,
            "PM2 stop exact"
        );
        // doc: L 1.80 (> phi) — exact floor(1000e18 / 556.2305...e18 * 1e18).
        assertEq(
            StructuralLeverage.longLev(usd(1000), usd(100), 0), 1797815543055438720, "PM2 L exact"
        );
    }

    function test_PM3_promax_long_post_below_B() public {
        // doc: fixed MinStop 387 = B - (B-Pb)/phi — exact 386.474508437578864 (drop
        // floor(750 * INV_PHI) = 463.525491562421136). Widest owner-rounding row: 0.136%.
        assertEq(
            StructuralLeverage.longStop(usd(800), usd(100), usd(850)),
            386474508437578864000,
            "PM3 MinStop exact"
        );
        // doc: L 1.94 — exact.
        assertEq(
            StructuralLeverage.longLev(usd(800), usd(100), usd(850)),
            1934584484688874467,
            "PM3 L exact"
        );
    }

    function test_PM4_promax_long_post_high_entry_same_stop() public {
        // doc: SAME fixed MinStop 387, lower L 1.24.
        assertEq(
            StructuralLeverage.longStop(usd(2000), usd(100), usd(850)),
            386474508437578864000,
            "PM4 MinStop exact"
        );
        assertEq(
            StructuralLeverage.longLev(usd(2000), usd(100), usd(850)),
            1239521786583827047,
            "PM4 L exact"
        );
        assertEq(
            StructuralLeverage.longStop(usd(800), usd(100), usd(850)),
            StructuralLeverage.longStop(usd(2000), usd(100), usd(850)),
            "post-pivot stop is FIXED, independent of entry"
        );
    }

    // ---------- PM5: Pro Max long, L-halving day-1 slice (V8-L-6: previously unpinned) ----------
    function test_PM5_promax_long_halving_day1_slice() public {
        // doc: stop 1671 = p_day - (p_day - B)/phi with the 62-min B = 850 as the delta
        // anchor — the EXACT call `_longStopWad` makes in the [0, W) halving window
        // (`longStop(pxWad, cap_, 0)`). Exact 1671.2269241877269768 (drop
        // floor(2150 * INV_PHI) = 1328.7730758122739232).
        assertEq(
            StructuralLeverage.longStop(usd(3000), usd(850), 0),
            1671226924187726076800,
            "PM5 slice stop exact"
        );
    }

    // ---------- PM6: Pro Max long, L-rise ratchet floor (V8-L-6: previously unpinned) ----------
    function test_PM6_promax_long_rise_ratchet_floor_documented_interim() public {
        // doc: stop = max(p/phi^2, ratchetFloor=1664) = 1664 — but the L-rise ratchet floor
        // is NOT wired (STRUCTURAL-STATE-MACHINE.md §5 "Remaining refinements": the growth
        // rise uses flat p/phi^2 without max(., halvingStop)). The exact current value is
        // pinned so a future ratchet PR must update this row deliberately.
        uint256 riseStop = StructuralLeverage.longStop(usd(4000), 0, 0); // the _longStopWad L-rise call
        assertEq(riseStop, 1527864045000420608000, "PM6 interim flat-phi exact (doc 1527.86)");
        assertTrue(riseStop != usd(1664), "PM6 ratchet floor not wired (doc SS5, honest interim)");
    }

    // ---------- PM7: Pro Max long, L-rise flat phi (V8-L-6: previously unpinned) ----------
    function test_PM7_promax_long_rise_flat_phi() public {
        // doc: stop 2674 = p/phi^2 (no floor in play) — the EXACT `_longStopWad` L-rise
        // call (`longStop(pxWad, 0, 0)`). Exact 2673.762078750736064 (drop
        // floor(7000 * INV_PHI) = 4326.237921249263936).
        assertEq(
            StructuralLeverage.longStop(usd(7000), 0, 0),
            2673762078750736064000,
            "PM7 p/phi^2 exact"
        );
    }

    // ---------- mirror invariant: the long reflects the short about the entry ----------
    function test_mirror_long_reflects_short() public {
        // Both sides compute the SAME wmul(a - anchor, INV_PHI) distance, so mirrored
        // outputs are bit-identical — asserted exactly, not to 1e12.
        uint256 sDist = StructuralLeverage.shortStructStop(usd(4000), usd(1000), 0) - usd(4000);
        uint256 lDist = usd(4000) - StructuralLeverage.longStop(usd(4000), usd(1000), 0);
        assertEq(sDist, lDist, "mirror: equal opposite distances = floor(0.618*(p-anchor))");
    }
}
