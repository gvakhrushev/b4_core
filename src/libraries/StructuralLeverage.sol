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
    ///         Post-pivot leverage DECREASES monotonically with depth of entry, exceeds the
    ///         flat base only for an entry above `C`, and pins to `C` for deep entries —
    ///         the minimum stop is the confirmed peak, a price the fall already proved it
    ///         cannot regain (verified on every completed cycle: the post-pivot price never
    ///         returned to `C`). A deep short is deliberately sized BELOW 1× — the +99–103%
    ///         bear-market rallies of cycles 1–2 liquidate a flat-`φ` short, while the small
    ///         position with its stop pinned to the far `C` survives. Sub-1× is the safety,
    ///         so `shortLeverageWad` has NO 1× floor (unlike the long).
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
}
