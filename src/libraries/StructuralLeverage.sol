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
}
