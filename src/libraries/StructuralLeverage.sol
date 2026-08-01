// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Phi} from "./Phi.sol";

/// @title StructuralLeverage — leverage bounded by the cycle's confirmed structural low.
/// @notice A leveraged long is sized so its liquidation sits at a *structurally justified*
///         price, not at an arbitrary multiple. For an entry at price `p` with product base
///         leverage `g` (WAD; `φ` for Pro Max), a delta anchor `floor` (the previous
///         confirmed structural low) and a ceiling `cap` (the most recent confirmed
///         structural low):
///
///             stop = min( p − (p − floor)/g ,  cap )
///             L    = p / (p − stop)
///
///         The uncapped stop sits at a `1/φ`-of-delta distance below `p` when `g = φ`, i.e.
///         38.2% of the delta `(p − floor)` above the floor — the same golden ratio as the
///         calendar pivots, and the reason `L = g·p/(p − floor)` holds in the uncapped case.
///         `cap` only ever *lowers* the stop (further from `p`), which *reduces* leverage:
///         it is the last confirmed low, so a position can never be sized to liquidate above
///         a level the market has already proven and held. Real-data check: without the cap
///         a φ-leverage long opened in 2019–2020 liquidates in the March-2020 crash; with the
///         cap pinned to the 2019 bottom it survives (`StructuralLeverage.t.sol`).
///
///         **`cap` limits maximum leverage, not the right to enter.** Any `p > floor` opens.
///         A price that has fallen back toward the floor simply gets a deeper stop and a
///         higher — structurally justified — leverage. Only `p ≤ floor` is refused: a fall to
///         the absolute prior low is a Bitcoin-existential event that warrants no leverage.
///
///         `floor == 0` (genesis, before any window has closed) degrades to the flat base:
///         `stop = p·(1 − 1/g)`, `L = g`. So Pro Max opens at exactly `φ`, matching the
///         pre-mechanism behaviour, with no special-case path.
///
///         Pure and unit-agnostic (`p`, `floor`, `cap`, `stop` share one unit). The engine
///         and the historical demo call the SAME function, so the two cannot drift.
library StructuralLeverage {
    /// @notice Effective leverage (WAD) for a long entered at `p`, product base `g` (WAD),
    ///         delta anchor `floor`, ceiling `cap` (pass `cap == 0` for "no ceiling yet").
    /// @dev Returns 0 iff `p <= floor` — the caller MUST treat 0 as "refuse a leveraged
    ///      open" (fall back to the un-leveraged spot leg). Never returns below `WAD` for a
    ///      valid entry: the minimum meaningful leverage is 1× (spot only).
    function leverageWad(uint256 p, uint256 g, uint256 floor_, uint256 cap_)
        internal
        pure
        returns (uint256)
    {
        if (p <= floor_ || g == 0) return 0; // no positive delta: refuse leverage
        // Uncapped structural stop: p − (p − floor)/g.
        uint256 drop = Phi.mulDiv(p - floor_, Phi.WAD, g); // (p − floor)/g
        uint256 stop = drop >= p ? 0 : p - drop; // guard: never below 0
        // The ceiling only ever pulls the stop DOWN (further from p ⇒ lower leverage).
        if (cap_ != 0 && stop > cap_) stop = cap_;
        if (stop >= p) return Phi.WAD; // degenerate: 1× (spot only)
        uint256 l = Phi.mulDiv(p, Phi.WAD, p - stop);
        return l < Phi.WAD ? Phi.WAD : l;
    }

    /// @notice The stop (liquidation) price the leverage above implies, in the same unit as
    ///         `p`. Exposed for accounting/valuation and for tests. Returns 0 when a
    ///         leveraged open is refused (`p <= floor`).
    function stopWad(uint256 p, uint256 g, uint256 floor_, uint256 cap_)
        internal
        pure
        returns (uint256)
    {
        if (p <= floor_ || g == 0) return 0;
        uint256 drop = Phi.mulDiv(p - floor_, Phi.WAD, g);
        uint256 stop = drop >= p ? 0 : p - drop;
        if (cap_ != 0 && stop > cap_) stop = cap_;
        return stop;
    }

    // ---------------------------------------------------------------- short side (top)

    /// @notice The SHORT stop — the exact mirror of the long, anchored to the cycle's
    ///         confirmed structural HIGHS (min↔max, −↔+, floor↔prevPeak, cap↔peakC).
    ///         `θ = g − 1` (0.618 for `g = φ`). Two regimes, because this cycle's peak `C`
    ///         is unknown until the 20-day window ending at the 38.2% pivot closes:
    ///
    ///         Window (`peakC == 0`, DCA slices):  stop = p + (p − prevPeak)·θ
    ///         After the pivot (`peakC` known):    maxStop = C + (C − prevPeak)·θ
    ///                                             stop = max( p + (maxStop − p)·θ ,  C )
    ///
    ///         Post-pivot leverage DECREASES monotonically with depth of entry and pins to
    ///         `C` for deep entries — the minimum stop is the confirmed peak, a price the fall
    ///         already proved it cannot regain (verified on every completed cycle: the
    ///         post-pivot price never returned to `C`). It exceeds the flat base `g` for every
    ///         entry above `maxStop/2` — which sits BELOW `C` — because `g·(g−1) = 1` puts the
    ///         `L = g` crossover exactly at `maxStop/2`; near `C` the leverage is well above
    ///         `g` (e.g. cycle-4 pivot entry ≈ 4.8×). The venue `maxLeverage` is the hard
    ///         ceiling on top. A deep short is deliberately sized BELOW 1× — the +99–103%
    ///         bear-market rallies of cycles 1–2 liquidate a flat-`φ` short, while the small
    ///         position with its stop pinned to the far `C` survives. Sub-1× is the safety,
    ///         so `shortLeverageWad` has NO 1× floor (unlike the long).
    ///
    ///         WINDOW-REGIME CAVEAT: with `peakC == 0` the stop is `p + (p − prevPeak)·θ`, an
    ///         EXTRAPOLATION from the *previous* cycle's peak, not a bound confirmed for this
    ///         cycle. If this cycle tops close to `prevPeak` (a diminishing-returns cycle) the
    ///         leverage grows large (unbounded as `p → prevPeak`); all completed cycles topped
    ///         ≥ 1.53× the prior peak. The §7b engine (`B4VaultEngine._szTargetStructural`) caps
    ///         every structural size at the venue `maxLeverage`, so this tail de-levers rather than
    ///         over-levers or emits a venue-impossible order.
    ///
    ///         Returns 0 (caller falls back to the flat base `g`) when the structure is not
    ///         confirmed: no previous peak recorded (genesis), a `peakC` not above
    ///         `prevPeak`, a window entry with no positive delta (`p <= prevPeak`), or a
    ///         post-pivot entry at/above `maxStop`.
    function shortStopWad(uint256 p, uint256 g, uint256 prevPeak, uint256 peakC)
        internal
        pure
        returns (uint256)
    {
        if (g <= Phi.WAD || prevPeak == 0 || p == 0) return 0; // flat-base fallback
        uint256 theta = g - Phi.WAD; // θ = g − 1  (1/φ for g = φ)
        if (peakC == 0) {
            // Window regime: C not yet confirmed; anchor is the previous confirmed peak.
            if (p <= prevPeak) return 0; // no positive delta: flat-base fallback
            return p + Phi.mulDiv(p - prevPeak, theta, Phi.WAD);
        }
        if (peakC <= prevPeak) return 0; // unconfirmed pair: flat-base fallback
        uint256 maxStop = peakC + Phi.mulDiv(peakC - prevPeak, theta, Phi.WAD);
        if (p >= maxStop) return 0; // refuse: entry at/above the maximum stop
        uint256 stop = p + Phi.mulDiv(maxStop - p, theta, Phi.WAD);
        return stop < peakC ? peakC : stop; // pin: never below the confirmed peak
    }

    /// @notice Effective SHORT leverage (WAD): `L = p / (stop − p)`. NO 1× floor — a deep
    ///         entry is deliberately sized below 1× (see `shortStopWad`). Returns 0 when the
    ///         stop is refused/unconfirmed — the caller falls back to the flat base `g`.
    function shortLeverageWad(uint256 p, uint256 g, uint256 prevPeak, uint256 peakC)
        internal
        pure
        returns (uint256)
    {
        uint256 stop = shortStopWad(p, g, prevPeak, peakC);
        if (stop == 0 || stop <= p) return 0;
        return Phi.mulDiv(p, Phi.WAD, stop - p);
    }

    // ================================================================= §7b state machine
    // The corrected sizing per docs/design/STRUCTURAL-STATE-MACHINE.md. ONE fixed stop:
    // `stop = extreme ∓ 0.618·(extreme − prevExtreme)`. Two regimes — window (extreme not
    // confirmed ⇒ each DCA slice uses its own price `p` as the extreme estimate) and post-pivot
    // (extreme confirmed ⇒ the stop is FIXED for every entry, only the leverage varies). Long
    // and short are exact mirrors. Leverage always divides by the ENTRY price. `INV_PHI = 1/φ`.

    /// @notice Structural stop for a leveraged LONG (Pro Max). `Pb` = previous cycle bottom;
    ///         `B` = this cycle's confirmed 62-window low, or 0 in the window regime.
    ///
    ///         WINDOW (`B == 0`): the extreme is not yet printed, so each DCA slice uses its own
    ///         price as the low estimate — `stop = p − (p − Pb)/φ`.
    ///
    ///         POST-PIVOT (`B` confirmed): the base is the product's own `g`-leverage stop,
    ///         `p·(1 − 1/φ) = p/φ²`, bounded on BOTH sides by the two anchors:
    ///           * capped at `B` — the liquidation may never sit ABOVE the printed bottom, or a
    ///             routine retest of that bottom closes the position. This is what de-levers a
    ///             HIGH entry (the mirror of a short entered deep into the fall);
    ///           * floored at `MinStop = B − (B − Pb)/φ` — the previous cycle's bottom is the
    ///             second anchor, and it is what LIFTS leverage above the flat base near the low.
    ///
    ///         So `φ` is the base and the anchors bend it either way, which is the whole point of
    ///         the second anchor. An earlier revision pinned the post-pivot stop to a single fixed
    ///         `MinStop` for every entry; that made the flat-`φ` band unreachable and, on the short
    ///         side, put liquidation inside the printed extreme. Returns 0 on no positive delta.
    function longStop(uint256 p, uint256 Pb, uint256 B) internal pure returns (uint256) {
        uint256 a = B == 0 ? p : B; // window: p is the low estimate; post: the confirmed low
        if (a <= Pb) return 0;
        uint256 minStop = a - Phi.wmul(a - Pb, Phi.INV_PHI); // a − 0.618·(a − Pb)
        if (B == 0) return minStop; // window: the per-slice stop IS this
        if (p <= minStop) return 0; // refusal: a long stop at/above its own entry
        uint256 flat = p - Phi.wmul(p, Phi.INV_PHI); // p·(1 − 1/φ) = p/φ²
        if (flat > B) flat = B; // never above the printed bottom
        return flat < minStop ? minStop : flat; // Pb-boosted floor
    }

    /// @notice Effective LONG leverage `L = p/(p − stop)`. 0 when the entry sits at/below the
    ///         stop (existential low — no leverage). No 1× floor: a high entry de-levers.
    function longLev(uint256 p, uint256 Pb, uint256 B) internal pure returns (uint256) {
        uint256 s = longStop(p, Pb, B);
        if (s == 0 || p <= s) return 0;
        return Phi.mulDiv(p, Phi.WAD, p - s);
    }

    /// @notice Structural stop for a leveraged SHORT (Pro Max) — the exact mirror of `longStop`.
    ///         `Pp` = previous cycle peak; `C` = this cycle's confirmed peak, or 0 in the window.
    ///
    ///         WINDOW (`C == 0`): per-slice, `stop = p + (p − Pp)/φ`.
    ///
    ///         POST-PIVOT (`C` confirmed): base is the `g`-leverage stop `p·(1 + 1/φ) = p·φ`,
    ///         bounded by the two anchors:
    ///           * floored at `C` — the liquidation may NEVER sit below the printed peak. This is
    ///             the case that matters: entering near `T`, after a 60-70 % fall with the reversal
    ///             close, a flat-`φ` short at `p` liquidates at `p·φ`, which is INSIDE the peak the
    ///             market already printed, and the 30-60 % bounces that occur there would close it.
    ///             Pinning to `C` forces leverage down instead — through 1× at `p = C/2` and
    ///             deliberately sub-1× below that;
    ///           * capped at `maxStop = C + (C − Pp)/φ` — the second anchor, which pulls the stop
    ///             CLOSER for a shallow entry near the peak and so BOOSTS leverage well above `φ`.
    ///
    ///         Identical in shape to `shortFlatStop` (Pro, `g = 1` ⇒ `max(2p, C)`); Pro Max only
    ///         adds the `Pp` cap. Both products therefore converge on the same C-pin, at different
    ///         speeds — Pro's stop tracks `2p` down to it, Pro Max's tracks `p·φ`.
    function shortStructStop(uint256 p, uint256 Pp, uint256 C) internal pure returns (uint256) {
        uint256 a = C == 0 ? p : C;
        if (a <= Pp) return 0;
        uint256 maxStop = a + Phi.wmul(a - Pp, Phi.INV_PHI);
        if (C == 0) return maxStop; // window: the per-slice stop IS this
        // A stale or too-low `C` drags `maxStop` down with it, and it can land at or below the
        // live price — a short stop BELOW the entry is not a conservative stop, it is a
        // liquidation already crossed. Refuse rather than emit it (the same refusal
        // `shortStopWad` has always carried). NOTE the actual consequence: the engine does NOT
        // size at the flat base on a 0 — `_perpTargetMargin` leaves `marginNeedWad` at 0 and the
        // vault holds settlement token with NO exposure until the price or the anchor moves. That
        // is the safe reading of "the structure refuses"; it is also recoverable, not a wedge.
        if (p >= maxStop) return 0;
        uint256 flat = Phi.wmul(p, Phi.PHI); // p·φ = p·(1 + 1/φ)
        if (flat < C) flat = C; // never inside the printed peak
        return flat > maxStop ? maxStop : flat; // Pp-boosted cap
    }

    /// @notice Effective SHORT leverage `L = p/(stop − p)` (Pro Max). Sub-1× deep — the safety.
    function shortStructLev(uint256 p, uint256 Pp, uint256 C) internal pure returns (uint256) {
        uint256 s = shortStructStop(p, Pp, C);
        if (s <= p) return 0;
        return Phi.mulDiv(p, Phi.WAD, s - p);
    }

    /// @notice Flat SHORT stop for the base product (Pro, `g = 1`): `stop = max(p·(1+1/g), C)`
    ///         — a `g×` short liquidation, floored at the confirmed peak `C` so a deep short
    ///         survives the bounce to the printed peak. Pass `C = 0` in the window regime.
    function shortFlatStop(uint256 p, uint256 g, uint256 C) internal pure returns (uint256) {
        if (g == 0) return 0;
        uint256 flat = p + Phi.mulDiv(p, Phi.WAD, g); // p·(1 + 1/g)
        return flat > C ? flat : C;
    }

    /// @notice Effective flat-SHORT leverage `L = p/(stop − p)` (Pro).
    function shortFlatLev(uint256 p, uint256 g, uint256 C) internal pure returns (uint256) {
        uint256 s = shortFlatStop(p, g, C);
        if (s <= p) return 0;
        return Phi.mulDiv(p, Phi.WAD, s - p);
    }
}
