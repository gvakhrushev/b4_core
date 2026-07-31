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

    function test_PMs2_promax_short_post_deep_pinned_to_C() public {
        // doc: the deep entry is PINNED TO C — the liquidation may never sit inside the peak the
        // market already printed. p*phi = 3236 < C = 4000, so the floor binds and the stop is C.
        assertEq(
            StructuralLeverage.shortStructStop(usd(2000), usd(1000), usd(4000)),
            usd(4000),
            "PMs2 stop = C (pinned)"
        );
        // L = 2000/(4000-2000) = 1.0x exactly. p = C/2 is the 1x crossover, same as Pro's.
        assertEq(
            StructuralLeverage.shortStructLev(usd(2000), usd(1000), usd(4000)),
            1e18,
            "PMs2 L = 1x at p = C/2"
        );
        // Below C/2 the pin forces leverage under 1x — the safety a bounce to the printed peak
        // needs. This is the whole reason the pin exists, so it is asserted, not implied.
        assertLt(
            StructuralLeverage.shortStructLev(usd(1500), usd(1000), usd(4000)),
            1e18,
            "deeper than C/2 is deliberately sub-1x"
        );
        // The stop is NOT fixed across entries: a shallow entry is capped by the Pp-boosted
        // maxStop, a deep one is pinned to C, and between them the base phi leverage applies.
        assertGt(
            StructuralLeverage.shortStructStop(usd(5000), usd(1000), usd(4000)),
            StructuralLeverage.shortStructStop(usd(2000), usd(1000), usd(4000)),
            "post-pivot stop MOVES with the entry, between C and maxStop"
        );
    }

    /// The band between the two anchors, which the old fixed-stop rule made unreachable: when
    /// neither bound binds the product runs at its base leverage, exactly phi.
    function test_PMs3_promax_short_post_midband_is_exactly_phi() public {
        // C = 4000, Pp = 1000 => maxStop 5854. p = 3000: p*phi = 4854, inside (4000, 5854).
        assertEq(
            StructuralLeverage.shortStructStop(usd(3000), usd(1000), usd(4000)),
            4854101966249684544000,
            "mid-band stop = p*phi"
        );
        assertApproxEqAbs(
            StructuralLeverage.shortStructLev(usd(3000), usd(1000), usd(4000)),
            1618033988749894848,
            2,
            "mid-band L = phi exactly"
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

    function test_PM4_promax_long_post_high_entry_base_phi() public {
        // Mirror of PMs2/PMs3. p = 2000 with B = 850: p/phi^2 = 764 sits BELOW the printed bottom
        // (safe) and ABOVE the Pb-boosted MinStop 386, so neither bound binds and the long runs at
        // its base leverage, exactly phi.
        assertEq(
            StructuralLeverage.longStop(usd(2000), usd(100), usd(850)),
            763932022500210304000,
            "PM4 stop = p/phi^2 (neither bound binds)"
        );
        assertApproxEqAbs(
            StructuralLeverage.longLev(usd(2000), usd(100), usd(850)),
            1618033988749894848,
            2,
            "PM4 L = phi"
        );
        // PM3's entry (800) is close enough to the bottom that the Pb-boosted MinStop lifts it,
        // so the two entries do NOT share a stop — the post-pivot stop moves with the entry.
        assertLt(
            StructuralLeverage.longStop(usd(800), usd(100), usd(850)),
            StructuralLeverage.longStop(usd(2000), usd(100), usd(850)),
            "post-pivot stop MOVES with the entry, between MinStop and B"
        );
        // The mirror of the short's C-pin: a very high entry is capped at the printed bottom, so
        // a retest of that bottom cannot liquidate it.
        assertEq(
            StructuralLeverage.longStop(usd(9000), usd(100), usd(850)),
            usd(850),
            "high entry is capped at the printed bottom B"
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
