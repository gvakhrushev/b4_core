// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StructuralLeverage} from "src/libraries/StructuralLeverage.sol";
import {Phi} from "src/libraries/Phi.sol";

/// @notice V8 Scope-B audit PoCs for the §7b StructuralLeverage rewrite.
///         (1) EXACT pins for every STRUCTURAL-STATE-MACHINE §4 row — incl. PM5/PM6/PM7,
///         which StructuralAB.t.sol leaves unpinned. (2) The 1% AB tolerance is ~3x wider
///         than the widest owner-rounding (0.136%, PM3): a systematic +0.4% theta error
///         passes every phi-bearing pin. (3) The long/short mirror is EXACT, not 1e12.
///         (4) Phi.wmul is 512-bit: no phantom overflow. (5) INV_PHI truncation direction
///         and magnitude. (6) Refusal guards at the anchor crossings.
contract V8B_StructuralAuditTest is Test {
    uint256 constant WAD = 1e18;
    uint256 constant INV_PHI = 618033988749894848;
    uint256 constant PHI = 1_618033988749894848;
    uint256 constant TOL = 1e16; // the AB suite's 1%

    function usd(uint256 x) internal pure returns (uint256) {
        return x * WAD;
    }

    // ---------------------------------------------------------------- (1) exact pins

    /// Every §4 row, asserted at the exact WAD value the library produces (recomputed
    /// independently from the doc's formulas). These pins cannot pass under ANY formula
    /// drift — unlike the 1% AB assertions.
    function test_exact_pins_all_AB_rows() public {
        // P1/P2/P3 — Pro flat short (g = 1), max(2p, C).
        assertEq(StructuralLeverage.shortFlatStop(usd(4000), WAD, 0), usd(8000), "P1 stop");
        assertEq(StructuralLeverage.shortFlatLev(usd(4000), WAD, 0), WAD, "P1 L");
        assertEq(StructuralLeverage.shortFlatStop(usd(5000), WAD, usd(4200)), usd(10000), "P2 stop");
        assertEq(StructuralLeverage.shortFlatLev(usd(5000), WAD, usd(4200)), WAD, "P2 L");
        assertEq(StructuralLeverage.shortFlatStop(usd(2000), WAD, usd(4200)), usd(4200), "P3 stop");
        assertEq(
            StructuralLeverage.shortFlatLev(usd(2000), WAD, usd(4200)), 909090909090909090, "P3 L"
        );
        // PM1 — Pro Max short window: p + (p-Pp)/phi.
        assertEq(
            StructuralLeverage.shortStructStop(usd(4000), usd(1000), 0),
            5854101966249684544000,
            "PM1 stop"
        );
        assertEq(
            StructuralLeverage.shortStructLev(usd(4000), usd(1000), 0), 2157378651666526464, "PM1 L"
        );
        // PMs1 — shallow entry: capped by the Pp-boosted maxStop.
        assertEq(
            StructuralLeverage.shortStructStop(usd(5000), usd(1000), usd(4000)),
            5854101966249684544000,
            "PMs1 stop"
        );
        assertEq(
            StructuralLeverage.shortStructLev(usd(5000), usd(1000), usd(4000)),
            5854101966249684548,
            "PMs1 L"
        );
        // PMs2 — deep entry: pinned to C so the liquidation is never inside the printed peak.
        assertEq(
            StructuralLeverage.shortStructStop(usd(2000), usd(1000), usd(4000)),
            usd(4000),
            "PMs2 stop"
        );
        assertEq(StructuralLeverage.shortStructLev(usd(2000), usd(1000), usd(4000)), 1e18, "PMs2 L");
        // PM2 — Pro Max long window: p - (p-Pb)/phi.
        assertEq(
            StructuralLeverage.longStop(usd(1000), usd(100), 0), 443769410125094636800, "PM2 stop"
        );
        assertEq(StructuralLeverage.longLev(usd(1000), usd(100), 0), 1797815543055438720, "PM2 L");
        // PM3 — entry near the printed bottom: lifted by the Pb-boosted MinStop.
        assertEq(
            StructuralLeverage.longStop(usd(800), usd(100), usd(850)),
            386474508437578864000,
            "PM3 stop"
        );
        assertEq(
            StructuralLeverage.longLev(usd(800), usd(100), usd(850)), 1934584484688874467, "PM3 L"
        );
        // PM4 — mid-band entry: neither bound binds, so the long runs at its base phi.
        assertEq(
            StructuralLeverage.longStop(usd(2000), usd(100), usd(850)),
            763932022500210304000,
            "PM4 stop"
        );
        assertApproxEqAbs(
            StructuralLeverage.longLev(usd(2000), usd(100), usd(850)),
            1618033988749894848,
            2,
            "PM4 L"
        );
        // PM5 — L-halving day-1 slice, the EXACT call the engine makes (longStop(p, cap_, 0)).
        // UNPINNED in StructuralAB.t.sol — pinned here: doc 1671, exact 1671.2269...
        assertEq(
            StructuralLeverage.longStop(usd(3000), usd(850), 0),
            1671226924187726076800,
            "PM5 slice stop"
        );
        // PM7 — L-rise flat phi, the EXACT engine call (longStop(p, 0, 0)): stop = p/phi^2.
        // UNPINNED in StructuralAB.t.sol — pinned here: doc 2674, exact 2673.7621...
        assertEq(
            StructuralLeverage.longStop(usd(7000), 0, 0), 2673762078750736064000, "PM7 p/phi^2"
        );
    }

    /// PM6 documents the interim honestly: the ratchet floor (doc expects 1664) is NOT
    /// wired — the engine's L-rise returns flat-phi 1527.86. This pin LOCKS the interim
    /// value so a future ratchet PR must update it deliberately.
    function test_PM6_ratchet_floor_documented_interim() public {
        uint256 riseStop = StructuralLeverage.longStop(usd(4000), 0, 0);
        assertEq(riseStop, 1527864045000420608000, "interim flat-phi");
        assertTrue(riseStop != usd(1664), "ratchet floor not wired (doc SS5, honest)");
    }

    // ----------------------------------------------------- (2) the 1% pins are loose

    /// A replica of the §7b formulas with a systematic +0.4% theta error
    /// (theta' = INV_PHI * 1.004). The widest owner-rounding the tolerance must absorb is
    /// 0.136% (PM3); the pins pass a coefficient error 3x larger — they CANNOT catch a
    /// real drift of this size. CONFIRMED test weakness (cf. V5 F2 mirror-test class).
    function test_AB_tolerance_passes_wrong_theta() public {
        uint256 theta2 = INV_PHI * 1004 / 1000; // +0.4%
        // PM1 stop / L (window short)
        uint256 s = usd(4000) + Phi.wmul(usd(3000), theta2);
        assertApproxEqRel(s, usd(5854), TOL, "PM1 stop passes with theta+0.4%");
        assertApproxEqRel(Phi.mulDiv(usd(4000), WAD, s - usd(4000)), 2.157e18, TOL, "PM1 L passes");
        // PMs1 / PMs2 (fixed maxStop short)
        assertApproxEqRel(Phi.mulDiv(usd(5000), WAD, s - usd(5000)), 5.855e18, TOL, "PMs1 L passes");
        uint256 sDeep = usd(4000) + Phi.wmul(usd(3000), theta2);
        assertApproxEqRel(
            Phi.mulDiv(usd(2000), WAD, sDeep - usd(2000)), 0.519e18, TOL, "PMs2 L passes"
        );
        // PM2 (window long)
        uint256 l2 = usd(1000) - Phi.wmul(usd(900), theta2);
        assertApproxEqRel(l2, usd(444), TOL, "PM2 stop passes with theta+0.4%");
        assertApproxEqRel(Phi.mulDiv(usd(1000), WAD, usd(1000) - l2), 1.798e18, TOL, "PM2 L passes");
        // PM3 / PM4 (fixed MinStop long) — PM3 carries the widest owner-rounding (0.136%)
        uint256 l3 = usd(850) - Phi.wmul(usd(750), theta2);
        assertApproxEqRel(l3, usd(387), TOL, "PM3 stop passes with theta+0.4%");
        assertApproxEqRel(Phi.mulDiv(usd(800), WAD, usd(800) - l3), 1.937e18, TOL, "PM3 L passes");
        assertApproxEqRel(Phi.mulDiv(usd(2000), WAD, usd(2000) - l3), 1.24e18, TOL, "PM4 L passes");
    }

    // -------------------------------------------------------- (3) the mirror is EXACT

    /// longStop / shortStructStop compute the SAME wmul(a - anchor, INV_PHI) distance —
    /// mirrored outputs are bit-identical, not 1e12-close (stronger than the AB mirror test).
    function testFuzz_mirror_is_exact(uint256 anchor, uint256 delta) public {
        anchor = bound(anchor, 0, 1e26);
        delta = bound(delta, 1, 1e26);
        uint256 p = anchor + delta;
        uint256 sDist = StructuralLeverage.shortStructStop(p, anchor, 0) - p;
        uint256 lDist = p - StructuralLeverage.longStop(p, anchor, 0);
        assertEq(sDist, lDist, "mirror distances bit-identical");
        // Post-pivot mirror, INCLUDING the refusal. When the delta rounds to zero the bound
        // collapses onto the entry, and a stop at the entry price is not a stop — both sides must
        // refuse, and they must refuse TOGETHER or the mirror is broken in the one place it is
        // least visible. (Found by this fuzzer: the short refused, the long did not, and the
        // subtraction below underflowed.)
        uint256 sRaw = StructuralLeverage.shortStructStop(p, anchor, p);
        uint256 lRaw = StructuralLeverage.longStop(p, anchor, p);
        assertEq(sRaw == 0, lRaw == 0, "refusal is mirrored");
        if (sRaw != 0) {
            assertEq(sRaw - p, p - lRaw, "post-pivot mirror bit-identical");
        }
    }

    // ------------------------------------------------- (4) wmul: no phantom overflow

    /// Phi.wmul delegates to the 512-bit mulDiv: a * INV_PHI / WAD cannot wrap for any
    /// a < ~1.87e77 (result < 2^256). 1e40 is ~2^133 — 44 orders beyond any WAD price.
    function test_wmul_no_phantom_overflow() public {
        assertEq(Phi.wmul(1e40, INV_PHI), 6180339887498948480000000000000000000000);
        assertEq(StructuralLeverage.longStop(1e30, 0, 0), 1e30 - Phi.wmul(1e30, INV_PHI));
        assertEq(StructuralLeverage.shortStructStop(1e30, 0, 0), 1e30 + Phi.wmul(1e30, INV_PHI));
    }

    // --------------------------------------------- (5) INV_PHI truncation: direction

    /// INV_PHI is 1/phi truncated DOWN to WAD, so the wmul drop is never LARGER than the
    /// exact-phi drop: a LONG stop lands HIGHER (closer to entry = the riskier direction),
    /// a SHORT stop lands LOWER (closer to entry = riskier too). Magnitude at a 100k-USD
    /// delta: ~2.8e4 wei of WAD = 2.8e-14 USD — economically nil.
    function test_inv_phi_truncation_direction_and_magnitude() public {
        uint256 x = 100_000e18; // BTC-cycle-scale delta (a - anchor)
        uint256 dropTrunc = Phi.wmul(x, INV_PHI);
        uint256 dropExact = Phi.mulDiv(x, WAD, PHI); // x / phi with UNtruncated phi
        assertLe(dropTrunc, dropExact, "truncation shrinks the drop (stop closer to entry)");
        assertLt(dropExact - dropTrunc, 30_000, "error < 3e4 wei WAD = 3e-14 USD: negligible");
    }

    // -------------------------------------------------------- (6) guards / crossings

    function test_refusal_guards_symmetric() public {
        // a <= anchor refuses on BOTH sides.
        assertEq(StructuralLeverage.longStop(usd(100), usd(100), 0), 0);
        assertEq(StructuralLeverage.shortStructStop(usd(100), usd(100), 0), 0);
        // A31. Post-pivot, `extreme <= prevExtreme` means the promoted delta anchor is wrong (a
        // poisoned or stale prior cycle), not that there is nothing to size. Refusing there held
        // the product flat for the WHOLE regime — hundreds of days — over one bad anchor. Both
        // sides now DEGRADE to the one-anchor rule instead: the base g-stop, still bounded by the
        // printed extreme, which is exactly Pro's short. Symmetric, and neither side refuses.
        assertEq(
            StructuralLeverage.shortStructStop(usd(100), usd(50), usd(50)),
            161803398874989484800,
            "short degrades to max(p*phi, C), not a refusal"
        );
        assertEq(
            StructuralLeverage.longStop(usd(100), usd(50), usd(50)),
            38196601125010515200,
            "long degrades to p/phi^2 (the B cap does not bind at this entry)"
        );
        // The pin still holds through the degradation: the short's liquidation is not inside `C`,
        // the long's is not above `B`. Losing the boost is the cost of losing the delta anchor;
        // losing the guarantee would not be acceptable.
        assertGe(
            StructuralLeverage.shortStructStop(usd(60), usd(50), usd(50)), usd(50), "still pinned"
        );
        assertLe(
            StructuralLeverage.longStop(usd(200), usd(50), usd(50)), usd(50), "still capped at B"
        );
        assertEq(
            StructuralLeverage.shortStructStop(usd(50), usd(100), 0), 0, "window still refuses"
        );
        // longLev refuses p <= stop; shortStructLev refuses stop <= p — symmetric outcomes.
        assertEq(StructuralLeverage.longLev(usd(386), usd(100), usd(850)), 0, "entry below MinStop");
        assertEq(
            StructuralLeverage.longLev(386474508437578864000, usd(100), usd(850)),
            0,
            "entry AT MinStop"
        );
        assertEq(
            StructuralLeverage.shortStructLev(usd(5855), usd(1000), usd(4000)),
            0,
            "entry above maxStop"
        );
        assertEq(
            StructuralLeverage.shortStructLev(5854101966249684544000, usd(1000), usd(4000)),
            0,
            "entry AT maxStop"
        );
        // g == 0 guarded.
        assertEq(StructuralLeverage.shortFlatStop(usd(4000), 0, 0), 0);
        assertEq(StructuralLeverage.shortFlatLev(usd(4000), 0, 0), 0);
    }

    /// shortFlatStop with 0 < g < 1 is UNGUARDED and explodes the stop: p*(1+1/g) = 3p at
    /// g = 0.5. No src caller passes g < 1 (engine: g = |fallTarget| in {1, phi}), and the
    /// direction de-levers (safe) — but the lib silently prices a sub-1x product instead of
    /// refusing (asymmetric with shortStopWad's `g <= WAD` refusal two functions above).
    function test_shortFlatStop_sub1_g_unguarded() public {
        assertEq(StructuralLeverage.shortFlatStop(usd(4000), 0.5e18, 0), usd(12000));
        assertEq(StructuralLeverage.shortFlatLev(usd(4000), 0.5e18, 0), 0.5e18);
    }
}
