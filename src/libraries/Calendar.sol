// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Phi} from "./Phi.sol";

/// @title Calendar — deterministic cycle geometry (SPECIFICATION §4).
/// @notice Pure functions of `t = now − halvingTs`. The nominal cycle is 1460 days with
///         pivots P = cycle/φ² and T = cycle/φ and two 20-day transitions, split at zero
///         only for target pairs that differ in sign or have a zero endpoint; strictly
///         same-sign pairs interpolate directly growth→fall with no split (SPEC §4, see
///         targetAt). The calendar rests in the terminal growth regime after T+W until
///         the next real halving fact is accepted (HAZARDS E2) — nothing here depends on
///         the realized interval matching the nominal one, and no wall-clock window ever
///         gates halving acceptance (HAZARDS E1).
///
///         Settlement points (design decision, see ARCHITECTURE.md): the fixed,
///         product-independent instants t = P−H and t = T+H of every epoch. For
///         opposite-sign or zero-endpoint pairs these coincide with the target
///         zero-crossings — the previous regime's derivative exposure has fully unwound
///         through a verified zero there, making "realized profit measured against
///         entry" and the still-wrong-sign perp rejection (SPECIFICATION §8) exact.
///         Same-sign pairs never visit zero and settle at the same instants with their
///         (right-sign) exposure legitimately open; the fee is still taken in kind on
///         interval profit. An interval spans point to point; the interval that begins
///         at T+H crosses the epoch boundary and ends at the next epoch's P−H (E4).
library Calendar {
    uint256 internal constant CYCLE = 1460 days;
    /// Full transition width W (20 days) and its half H (10 days). H fixes the zone
    /// boundaries and settlement points for ALL pairs; it is the split at zero only on
    /// the piecewise (opposite-sign / zero-endpoint) interpolation path.
    uint256 internal constant W = 20 days;
    uint256 internal constant H = 10 days;

    /// growth→fall pivot: cycle/φ² (floor).
    uint256 internal constant P = (CYCLE * Phi.WAD) / Phi.PHI_SQ;
    /// fall→growth pivot: cycle/φ (floor).
    uint256 internal constant T = (CYCLE * Phi.WAD) / Phi.PHI;

    /// Free-exit window after each accepted halving fact (design decision — the spec
    /// requires "a fixed window"; we use the transition width W).
    uint256 internal constant POST_FACT_FREE_EXIT = W;

    /// One-hour checkpoint-price snapshot window at each settlement point (SPEC §6/§8).
    uint256 internal constant SNAPSHOT_WINDOW = 1 hours;
    /// Report window after the settlement point (design decision; liveness-only).
    uint256 internal constant REPORT_WINDOW = 2 days;

    enum Zone {
        Growth, // [0, P−W)
        ClosingGrowth, // [P−W, P−H): growth target → 0
        OpeningFall, // [P−H, P): 0 → fall target (deposits closed)
        Fall, // [P, T)
        ClosingFall, // [T, T+H): fall target → 0
        OpeningGrowth, // [T+H, T+W): 0 → growth target (deposits closed)
        TerminalGrowth // [T+W, next accepted fact)
    }

    function zoneAt(uint256 t) internal pure returns (Zone) {
        if (t < P - W) return Zone.Growth;
        if (t < P - H) return Zone.ClosingGrowth;
        if (t < P) return Zone.OpeningFall;
        if (t < T) return Zone.Fall;
        if (t < T + H) return Zone.ClosingFall;
        if (t < T + W) return Zone.OpeningGrowth;
        return Zone.TerminalGrowth;
    }

    /// @notice Current signed target, linearly interpolated (WAD).
    /// @dev The normative requirement is that a derivative SIGN CHANGE always passes
    ///      through a verified zero (WHITEPAPER §4). When growth and fall targets have
    ///      strictly the same sign there is no sign change: the target interpolates
    ///      directly across the full transition (Mini (1,1) therefore stays constant and
    ///      never trades — REQUIREMENTS §2 "markets used: none after deposit"). Pairs
    ///      with opposite signs, or a zero endpoint, take the piecewise path split at
    ///      zero exactly at the settlement points (SPEC §4). See ARCHITECTURE.md.
    function targetAt(uint256 t, int256 growth, int256 fall) internal pure returns (int256) {
        if (t < P - W) return growth;
        bool sameSign = (growth > 0 && fall > 0) || (growth < 0 && fall < 0);
        if (sameSign) {
            if (t < P) return growth + (fall - growth) * int256(t - (P - W)) / int256(W);
            if (t < T) return fall;
            if (t < T + W) return fall + (growth - fall) * int256(t - T) / int256(W);
            return growth;
        }
        if (t < P - H) return growth * int256(P - H - t) / int256(H);
        if (t < P) return fall * int256(t - (P - H)) / int256(H);
        if (t < T) return fall;
        if (t < T + H) return fall * int256(T + H - t) / int256(H);
        if (t < T + W) return growth * int256(t - (T + H)) / int256(H);
        return growth;
    }

    /// @notice spot = clamp(n, 0, 1); perp = n − spot (SPECIFICATION §3).
    function decompose(int256 n) internal pure returns (int256 spot, int256 perp) {
        spot = n;
        if (spot < 0) spot = 0;
        if (spot > int256(Phi.WAD)) spot = int256(Phi.WAD);
        perp = n - spot;
    }

    /// @notice Deposits are closed in the two 0→… sub-windows (SPECIFICATION §4).
    function depositOpen(uint256 t) internal pure returns (bool) {
        Zone z = zoneAt(t);
        return z != Zone.OpeningFall && z != Zone.OpeningGrowth;
    }

    /// @notice Free exits cover all four transition zones plus a fixed window after each
    ///         accepted fact (SPECIFICATION §4). `t` is time since the latest fact, so
    ///         the post-fact window is simply t < POST_FACT_FREE_EXIT.
    function freeExit(uint256 t) internal pure returns (bool) {
        if (t < POST_FACT_FREE_EXIT) return true;
        Zone z = zoneAt(t);
        return z == Zone.ClosingGrowth || z == Zone.OpeningFall || z == Zone.ClosingFall
            || z == Zone.OpeningGrowth;
    }

    /// @notice Settlement points of the epoch anchored at `halvingTs`: the two fixed
    ///         instants t = P−H and t = T+H (the target zero-crossings for opposite-sign
    ///         or zero-endpoint pairs). Returns the earliest point strictly after
    ///         `after`, or 0 if the epoch has none left. Points of a superseded epoch
    ///         that were never reached are skipped by construction: the caller only ever
    ///         asks about the current epoch, and `after` (the last materialized point)
    ///         is monotonic.
    function nextSettlementPoint(uint256 halvingTs, uint256 after_)
        internal
        pure
        returns (uint256)
    {
        uint256 p1 = halvingTs + (P - H);
        uint256 p2 = halvingTs + (T + H);
        if (p1 > after_) return p1;
        if (p2 > after_) return p2;
        return 0;
    }
}
