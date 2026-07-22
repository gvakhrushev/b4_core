// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {Phi} from "src/libraries/Phi.sol";

contract CalendarTest is Test {
    int256 constant G = 1e18; // growth target
    int256 constant F = -1_618033988749894848; // fall target (Pro Max)

    function test_geometry_constants() public pure {
        // P + T = cycle (1/φ² + 1/φ = 1), within flooring.
        assertApproxEqAbs(Calendar.P + Calendar.T, Calendar.CYCLE, 2);
        assertLt(Calendar.P, Calendar.T);
        assertGt(Calendar.P, Calendar.W); // P−W well-defined
        // The full transition fits before the shortest realized cycle (~1319d).
        assertLt(Calendar.T + Calendar.W, 1319 days);
    }

    function test_zone_boundaries_exact() public pure {
        uint256 P = Calendar.P;
        uint256 T = Calendar.T;
        uint256 W = Calendar.W;
        uint256 H = Calendar.H;
        assertEq(uint8(Calendar.zoneAt(0)), uint8(Calendar.Zone.Growth));
        assertEq(uint8(Calendar.zoneAt(P - W - 1)), uint8(Calendar.Zone.Growth));
        assertEq(uint8(Calendar.zoneAt(P - W)), uint8(Calendar.Zone.ClosingGrowth));
        assertEq(uint8(Calendar.zoneAt(P - H - 1)), uint8(Calendar.Zone.ClosingGrowth));
        assertEq(uint8(Calendar.zoneAt(P - H)), uint8(Calendar.Zone.OpeningFall));
        assertEq(uint8(Calendar.zoneAt(P - 1)), uint8(Calendar.Zone.OpeningFall));
        assertEq(uint8(Calendar.zoneAt(P)), uint8(Calendar.Zone.Fall));
        assertEq(uint8(Calendar.zoneAt(T - 1)), uint8(Calendar.Zone.Fall));
        assertEq(uint8(Calendar.zoneAt(T)), uint8(Calendar.Zone.ClosingFall));
        assertEq(uint8(Calendar.zoneAt(T + H - 1)), uint8(Calendar.Zone.ClosingFall));
        assertEq(uint8(Calendar.zoneAt(T + H)), uint8(Calendar.Zone.OpeningGrowth));
        assertEq(uint8(Calendar.zoneAt(T + W - 1)), uint8(Calendar.Zone.OpeningGrowth));
        assertEq(uint8(Calendar.zoneAt(T + W)), uint8(Calendar.Zone.TerminalGrowth));
    }

    function test_target_zero_at_crossings() public pure {
        // The derivative sign change passes through a verified zero (WHITEPAPER §4):
        // target is exactly 0 at both settlement points.
        assertEq(Calendar.targetAt(Calendar.P - Calendar.H, G, F), 0);
        assertEq(Calendar.targetAt(Calendar.T + Calendar.H, G, F), 0);
        // Plateaus hit the exact stored targets.
        assertEq(Calendar.targetAt(0, G, F), G);
        assertEq(Calendar.targetAt(Calendar.P, G, F), F);
        assertEq(Calendar.targetAt(Calendar.T - 1, G, F), F);
    }

    /// Same-sign pairs never visit a synthetic zero: Mini (1,1) is constant everywhere
    /// (REQUIREMENTS §2: markets used — none after deposit), and a same-sign custom pair
    /// interpolates directly without a sign change.
    function testFuzz_sameSign_direct_interpolation(uint256 t) public pure {
        t = bound(t, 0, Calendar.T + Calendar.W + 365 days);
        assertEq(Calendar.targetAt(t, 1e18, 1e18), 1e18); // Mini: constant, no trade
        int256 n = Calendar.targetAt(t, 8e17, 3e17);
        assertGe(n, 3e17); // never leaves [min, max] — never crosses zero
        assertLe(n, 8e17);
        int256 m = Calendar.targetAt(t, -8e17, -3e17);
        assertLe(m, -3e17);
        assertGe(m, -8e17);
    }

    /// A zero endpoint (B4-style) still takes the piecewise path: fully unwound exactly
    /// at the settlement points.
    function test_zero_endpoint_piecewise() public pure {
        assertEq(Calendar.targetAt(Calendar.P - Calendar.H, 1e18, 0), 0);
        assertEq(Calendar.targetAt(Calendar.P, 1e18, 0), 0);
        assertEq(Calendar.targetAt(Calendar.T + Calendar.H, 1e18, 0), 0);
        assertEq(Calendar.targetAt(Calendar.T + Calendar.W, 1e18, 0), 1e18);
    }

    /// E2: terminal regime rest — target stays at growth for arbitrarily long t.
    function testFuzz_terminal_rest(uint256 t) public pure {
        t = bound(t, Calendar.T + Calendar.W, 100 * 365 days);
        assertEq(Calendar.targetAt(t, G, F), G);
        assertEq(uint8(Calendar.zoneAt(t)), uint8(Calendar.Zone.TerminalGrowth));
    }

    /// Continuity: one-second steps never jump more than the max slope (|target| ≤ φ over H).
    function testFuzz_interpolation_continuity(uint256 t) public pure {
        t = bound(t, 0, Calendar.T + Calendar.W + 30 days);
        int256 a = Calendar.targetAt(t, G, F);
        int256 b = Calendar.targetAt(t + 1, G, F);
        uint256 maxStep = uint256(Phi.PHI) / Calendar.H + 2;
        assertLe(Phi.abs(b - a), maxStep);
    }

    function test_decompose() public pure {
        (int256 s, int256 p) = Calendar.decompose(int256(Phi.PHI)); // Pro Max growth
        assertEq(s, 1e18);
        assertEq(p, int256(Phi.PHI) - 1e18); // φ−1 perp
        (s, p) = Calendar.decompose(-int256(Phi.PHI)); // Pro Max fall
        assertEq(s, 0);
        assertEq(p, -int256(Phi.PHI));
        (s, p) = Calendar.decompose(0);
        assertEq(s, 0);
        assertEq(p, 0);
        (s, p) = Calendar.decompose(5e17);
        assertEq(s, 5e17);
        assertEq(p, 0);
        (s, p) = Calendar.decompose(-int256(Phi.WAD)); // Pro fall: full 1× short
        assertEq(s, 0);
        assertEq(p, -int256(Phi.WAD));
        (s, p) = Calendar.decompose(-int256(Phi.INV_PHI)); // generic sub-unit short
        assertEq(s, 0);
        assertEq(p, -int256(Phi.INV_PHI));
    }

    function test_deposit_windows() public pure {
        // Closed exactly in the two 0→… sub-windows.
        assertTrue(Calendar.depositOpen(0));
        assertTrue(Calendar.depositOpen(Calendar.P - Calendar.H - 1));
        assertFalse(Calendar.depositOpen(Calendar.P - Calendar.H)); // OpeningFall
        assertFalse(Calendar.depositOpen(Calendar.P - 1));
        assertTrue(Calendar.depositOpen(Calendar.P)); // Fall: open
        assertTrue(Calendar.depositOpen(Calendar.T + Calendar.H - 1)); // ClosingFall: open
        assertFalse(Calendar.depositOpen(Calendar.T + Calendar.H)); // OpeningGrowth
        assertFalse(Calendar.depositOpen(Calendar.T + Calendar.W - 1));
        assertTrue(Calendar.depositOpen(Calendar.T + Calendar.W));
    }

    function test_free_exit_windows() public pure {
        // Post-fact window.
        assertTrue(Calendar.freeExit(0));
        assertTrue(Calendar.freeExit(Calendar.POST_FACT_FREE_EXIT - 1));
        assertFalse(Calendar.freeExit(Calendar.POST_FACT_FREE_EXIT)); // deep growth
        // All four transitions.
        assertTrue(Calendar.freeExit(Calendar.P - Calendar.W));
        assertTrue(Calendar.freeExit(Calendar.P - 1));
        assertFalse(Calendar.freeExit(Calendar.P)); // fall plateau: not free
        assertTrue(Calendar.freeExit(Calendar.T));
        assertTrue(Calendar.freeExit(Calendar.T + Calendar.W - 1));
        assertFalse(Calendar.freeExit(Calendar.T + Calendar.W)); // terminal: not free
    }

    function test_settlement_points() public pure {
        uint256 h = 1_700_000_000;
        uint256 p1 = h + Calendar.P - Calendar.H;
        uint256 p2 = h + Calendar.T + Calendar.H;
        assertEq(Calendar.nextSettlementPoint(h, h), p1);
        assertEq(Calendar.nextSettlementPoint(h, p1 - 1), p1);
        assertEq(Calendar.nextSettlementPoint(h, p1), p2);
        assertEq(Calendar.nextSettlementPoint(h, p2 - 1), p2);
        assertEq(Calendar.nextSettlementPoint(h, p2), 0);
    }

    /// E4-style: fast next epoch — its first point is still strictly after the last
    /// materialized point, so ids never regress even under a barely-monotonic fact.
    function testFuzz_settlement_points_fast_cycle(uint64 h, uint32 dt) public pure {
        uint256 h1 = uint256(h) + 1;
        uint256 h2 = h1 + uint256(dt) + 1; // strictly monotonic
        uint256 lastOld = h1 + Calendar.P - Calendar.H;
        uint256 nextNew = Calendar.nextSettlementPoint(h2, lastOld);
        // Either the new epoch's p1 (> lastOld) or its p2; never 0, never ≤ lastOld.
        assertGt(nextNew, lastOld);
    }
}
