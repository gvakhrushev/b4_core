// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {StructuralLeverage} from "src/libraries/StructuralLeverage.sol";
import {Phi} from "src/libraries/Phi.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";

/// @notice Engine-level structural sizing by MARGIN CONTROL (no frozen L) —
///         docs/design/STRUCTURAL-STATE-MACHINE.md §6. The venue's own entry is the frozen
///         reference, so the engine only adds/reduces on a calendar ramp: a held position is
///         never re-traded (a price move or a halving anchor-flip can't re-lever it, C1/C4), and
///         an exit/liquidation → szi 0 re-derives from flat (no stale re-lever — the fan-out bug
///         is now structurally impossible). The pure math is pinned in StructuralAB.t.sol.
contract StructuralSizingTest is VaultTestBase {
    uint256 constant DIR = 1;
    uint256 internal constant PHI = Phi.PHI;

    function setUp() public {
        setUpProtocol();
    }

    function readPos(address who) internal view returns (CoreTypes.Position memory) {
        (bool ok, bytes memory ret) =
            CoreTypes.PRECOMPILE_POSITION.staticcall(abi.encode(who, uint16(PERP_MKT)));
        require(ok, "read pos");
        return abi.decode(ret, (CoreTypes.Position));
    }

    function _setPx(uint256 usd) internal {
        hub.setSpotPx(SPOT_MKT, uint64(usd * 1e4));
        hub.setMarkPx(PERP_MKT, uint64(usd * 1e2));
        hub.setOraclePx(PERP_MKT, uint64(usd * 1e2));
    }

    /// The venue's realized liquidation price (WAD) of the long: `(entryNtl − margin)/szi`.
    function _liqWad(B4Vault v) internal view returns (uint256) {
        CoreTypes.Position memory p = readPos(address(v));
        if (p.szi <= 0) return 0;
        uint256 margin6 = v.perpMargin6();
        if (uint256(p.entryNtl) <= margin6) return 0;
        return
            Phi.mulDiv((uint256(p.entryNtl) - margin6) * 1e4, Phi.WAD, uint256(uint64(p.szi)) * 1e6);
    }

    /// Effective venue leverage: entryNtl / margin.
    function _levWad(B4Vault v) internal view returns (uint256) {
        CoreTypes.Position memory p = readPos(address(v));
        if (v.perpMargin6() == 0) return 0;
        return Phi.mulDiv(uint256(p.entryNtl), Phi.WAD, v.perpMargin6());
    }

    /// Sample the anchor ratchet `n` times, one day apart, starting at the ABSOLUTE time
    /// `t0abs`, at a constant price. 11 daily samples satisfy the V9 density gate
    /// (count ≥ 10 AND span ≥ W/2), so the window's anchor confirms and feeds the engine.
    function _sampleDaily(uint256 t0abs, uint256 n, uint256 px) internal {
        for (uint256 k = 0; k < n; k++) {
            vm.warp(t0abs + k * 1 days);
            _setPx(px);
            pool.sampleAnchor(DIR);
        }
    }

    // ============================================================ whole deposit deployed (C7)

    function test_whole_deposit_deployed_and_nav_conserved() public {
        // $100k spot default. Genesis anchors ⇒ growth-rise regime ⇒ flat-φ stop (p/φ²).
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 0, 120_000e6);
        crankUntilIdle(v, 60);

        assertEq(v.navWad(), 120_000e18, "NAV conserved");
        assertGt(readPos(address(v)).szi, 0, "phi perp long open");
        assertApproxEqAbs(
            uint256(v.perpMargin6()), 120_000e6, 500e6, "whole deposit is the margin (C7)"
        );
        assertApproxEqRel(
            v.strategyValueWad(), 0, 0.02e18, "strategy fully deployed, no idle reserve"
        );
    }

    // ============================================================ liquidation at the stop (C6)

    function test_venue_liquidation_sits_at_structural_stop() public {
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 0, 120_000e6);
        crankUntilIdle(v, 60);

        // Genesis growth-rise stop = entry/φ² (= 38.2% of entry); effective leverage = φ.
        uint256 stop = StructuralLeverage.longStop(100_000e18, 0, 0);
        assertApproxEqRel(_liqWad(v), stop, 0.02e18, "realized liquidation == structural stop");
        assertApproxEqRel(_levWad(v), PHI, 0.02e18, "effective leverage == phi (not maxLev/phi)");
    }

    // ============================================================ held not re-traded (C1/C4)

    function test_held_long_not_retraded_on_price_move_or_anchor_flip() public {
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 0, 120_000e6);
        crankUntilIdle(v, 60);
        int64 sziBefore = readPos(address(v)).szi;
        assertGt(sziBefore, 0);

        // A large price move while HELD: strategyValue ≈ 0 and margin fixed ⇒ marginTarget
        // unchanged ⇒ no add/reduce. The venue entry is the frozen reference, so no re-size.
        _setPx(160_000);
        crankUntilIdle(v, 20);
        assertEq(readPos(address(v)).szi, sziBefore, "no re-trade on a price move");

        // Cross a halving and sample the (jumping) anchor mid-hold: still no re-lever.
        uint256 hts = GENESIS_TS + Calendar.T + Calendar.W + 5 days;
        vm.warp(hts);
        acceptHalving(GENESIS_HEIGHT + 210_000, uint32(hts));
        vm.warp(hts + 2 days);
        _setPx(180_000);
        pool.sampleAnchor(DIR); // low ratchet reseeds — invisible to a held position
        crankUntilIdle(v, 20);
        assertEq(readPos(address(v)).szi, sziBefore, "no re-lever across the halving anchor move");

        // Symmetric downside: a hard DROP toward the stop must not reduce either. NAV is
        // recorded-only (B3, no uPnL), so marginNeed ≈ committed margin on both sides ⇒ stable.
        _setPx(70_000);
        crankUntilIdle(v, 20);
        assertEq(readPos(address(v)).szi, sziBefore, "no reduce on a downward price move");
    }

    // ==================================================== structural short (confirmed peak)

    function test_structural_short_liquidates_at_confirmed_peak() public {
        // Confirm this cycle's peak C = 50k in the peak-window [P−W, P] (genesis prevPeak
        // = 0). Sampled DENSELY — the V9 density gate must confirm the peak before the
        // Fall freshness gate feeds it to the engine.
        _sampleDaily(GENESIS_TS + Calendar.P - Calendar.W + 1 days, 11, 50_000);
        (, uint256 peakC,) = pool.peaks(DIR);
        assertEq(peakC, 50_000e18, "peak confirmed");

        // Fall zone: deposit and open the φ short (pure perp) at 40k — a deep short, sub-1×.
        warpTo(Calendar.P + 30 days);
        _setPx(40_000);
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 0, 120_000e6);
        crankUntilIdle(v, 60);

        CoreTypes.Position memory p = readPos(address(v));
        assertLt(p.szi, 0, "phi short opened (pure perp)");
        // Short liquidation = (entryNtl + margin)/|szi|; the confirmed-peak stop is C + (C−0)/φ.
        uint256 stop = StructuralLeverage.shortStructStop(40_000e18, 0, 50_000e18);
        uint256 liq = Phi.mulDiv(
            (uint256(p.entryNtl) + v.perpMargin6()) * 1e4, Phi.WAD, uint256(uint64(-p.szi)) * 1e6
        );
        assertApproxEqRel(liq, stop, 0.03e18, "short liquidation sits at the structural peak stop");
        // Deep entry (40k < C 50k) ⇒ the whole deposit is margin but the position is sub-1×.
        assertApproxEqAbs(uint256(v.perpMargin6()), 120_000e6, 1_000e6, "whole deposit deployed");
    }

    // ================================================= exit → re-open re-derives (no stale re-lever)

    function test_exit_then_reopen_re_derives_at_current_stop() public {
        // The fan-out's confirmed CRITICAL under the old freeze: a free partial exit left the
        // (entryPx, L) triple stale, so the long re-opened over-levered at the STALE entry. With
        // margin control there is no triple — the re-open sizes at the CURRENT price/stop.
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 0, 120_000e6);
        crankUntilIdle(v, 60);

        _setPx(160_000); // price rises 60% while held (this is where the old bug over-levered)
        vm.prank(user);
        v.initiateExit(5e17); // free window (growth), 50% out
        crankUntilIdle(v, 40);
        assertEq(v.exitShareWad(), 0, "exit finalized");

        // Re-open the kept capital and settle.
        crankUntilIdle(v, 60);
        // The re-opened long liquidates at the CURRENT structural stop (px 160k), leverage ≈ φ —
        // NOT φ·(160/100) = 2.59× at a stale $100k entry. Assert szi>0 first so the leverage/liq
        // checks are never vacuous (audit claims-vs-code:167).
        assertGt(readPos(address(v)).szi, 0, "kept capital re-opened");
        assertApproxEqRel(_levWad(v), PHI, 0.03e18, "re-open leverage == phi (no stale re-lever)");
        assertApproxEqRel(
            _liqWad(v),
            StructuralLeverage.longStop(160_000e18, 0, 0),
            0.03e18,
            "liq at current stop"
        );
    }

    // =========================================== audit fixes: freeze lifecycle / anchors / add

    /// Audit S2 (exit-reopen:901, verified 3-0). A FULL exit cleared `perpStopWad`, but the next
    /// FLAT crank re-armed it at the exit-time price; a later re-deposit at a DIFFERENT price then
    /// sized against the stale stop (reproduced 2.75× vs φ, liquidation 36% below vs the intended
    /// 62%). Re-deriving the stop every flat crank (freeze only while HELD) opens fresh.
    function test_full_exit_then_reopen_at_drifted_price_is_fresh() public {
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 0, 120_000e6);
        crankUntilIdle(v, 60);
        assertGt(readPos(address(v)).szi, 0);

        _setPx(150_000);
        vm.prank(user);
        v.initiateExit(1e18); // FULL exit in the free growth window
        crankUntilIdle(v, 60);
        assertEq(v.exitShareWad(), 0, "full exit finalized");
        assertEq(readPos(address(v)).szi, 0, "flat after a full exit");

        // Price drifts DOWN, then a fresh deposit re-opens. The stale 150k-based stop would give
        // ~2.75×; a fresh 90k-based stop gives φ.
        _setPx(90_000);
        fundAndDeposit(v, 0, 60_000e6);
        crankUntilIdle(v, 60);
        assertGt(readPos(address(v)).szi, 0, "re-opened from flat");
        assertApproxEqRel(_levWad(v), PHI, 0.03e18, "re-open leverage == phi, not the stale 2.75x");
        assertApproxEqRel(
            _liqWad(v),
            StructuralLeverage.longStop(90_000e18, 0, 0),
            0.03e18,
            "liq at the FRESH 90k stop, not the stale 150k stop"
        );
    }

    /// Critic HIGH (deposit mid-hold). A deposit taken while the long is HELD grows marginNeed and
    /// funds the deposit into margin; the added lots must be sized at the live MARK (not the frozen
    /// avg entry) so the increment liquidates at the stop too and the COMBINED liquidation never
    /// drifts off it. Pre-fix it drifted up toward the mark and a routine pullback wiped the book.
    function test_deposit_mid_hold_keeps_liquidation_on_the_stop() public {
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 0, 120_000e6);
        crankUntilIdle(v, 60);
        uint256 stop0 = StructuralLeverage.longStop(100_000e18, 0, 0); // frozen growth-rise stop
        assertApproxEqRel(_liqWad(v), stop0, 0.02e18, "opened on the stop");

        // Price triples while held; then the owner deposits more (deposits open in growth).
        _setPx(300_000);
        fundAndDeposit(v, 0, 120_000e6);
        crankUntilIdle(v, 60);

        assertGt(readPos(address(v)).szi, 0, "still long after the add");
        assertApproxEqRel(
            _liqWad(v), stop0, 0.05e18, "combined liquidation stays on the frozen structural stop"
        );
    }

    /// Audit S4 (claims-vs-code:75, verified 3-0). `_longStopWad` passed `B = 0` in every branch,
    /// so the fixed post-pivot MinStop `B − (B − Pb)/φ` was dead code and TerminalGrowth opened at
    /// flat-φ — over-lever, with the liquidation ABOVE the confirmed cycle low. L-post now wires
    /// `longStop(px, floor_ = Pb, cap_ = B)`.
    function test_terminal_growth_long_uses_fixed_min_stop_not_flat_phi() public {
        // Cycle 0's 62-window bottom Pb = 16k (dense — V9 density gate), then a halving
        // flips it to `floor`.
        _sampleDaily(GENESIS_TS + Calendar.T + 1 days, 11, 16_000);
        uint256 hts = GENESIS_TS + Calendar.T + 30 days;
        vm.warp(hts);
        acceptHalving(GENESIS_HEIGHT + 210_000, uint32(hts));
        _sampleDaily(hts + 1 days, 11, 30_000); // epoch-1 post-halving low (dense)
        // Cycle 1's 62-window bottom B = 20k (dense; `floor` untouched by a kind-1 window).
        _sampleDaily(hts + Calendar.T + 1 days, 11, 20_000);
        (uint256 floor_, uint256 cap_) = pool.anchors(DIR);
        assertEq(floor_ / 1e18, 16_000, "Pb = prev cycle bottom");
        assertEq(cap_ / 1e18, 20_000, "B = this cycle bottom");

        // TerminalGrowth of epoch 1: open a Pro Max leveraged long at 80k.
        vm.warp(hts + Calendar.T + Calendar.W + 10 days);
        _setPx(80_000);
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 0, 120_000e6);
        crankUntilIdle(v, 60);

        uint256 minStop = StructuralLeverage.longStop(80_000e18, floor_, cap_);
        assertGt(readPos(address(v)).szi, 0, "leveraged long open in terminal growth");
        assertApproxEqRel(_liqWad(v), minStop, 0.03e18, "liq at the FIXED MinStop, not flat-phi");
        assertLt(
            minStop, StructuralLeverage.longStop(80_000e18, 0, 0), "MinStop is deeper than flat-phi"
        );
    }

    /// Audit S1 (peak-ratchet:1046 / short-regime:1049, verified 6-0). `_shortStopWad` fed the
    /// pool's running `peakC` to `shortStructStop` with no zone gate, so a short opening in the
    /// S-win (OpeningFall, peak still forming) anchored to the unconfirmed running peak instead of
    /// the live price — an over-lever. The zone gate now passes `C = 0` (live p) in the S-win.
    function test_short_in_opening_fall_uses_live_price_not_running_peak() public {
        // Deposit in Growth and open the φ long before the OpeningFall transition.
        warpTo(300 days);
        _setPx(45_000);
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 0, 120_000e6);
        crankUntilIdle(v, 60);
        assertGt(readPos(address(v)).szi, 0, "long open in growth");

        // Sample a running peak (50k) DENSELY inside the peak window but BEFORE OpeningFall
        // (the V9 density gate confirms it; the S-win zone gate is what keeps it out of the
        // freeze below).
        _sampleDaily(GENESIS_TS + Calendar.P - Calendar.W + 1 days, 11, 50_000);
        (, uint256 peakC,) = pool.peaks(DIR);
        assertEq(peakC, 50_000e18, "running peak recorded (confirmed)");

        // OpeningFall (S-win): the target flips negative → the long re-derives into a short at 40k,
        // BELOW the running peak. The frozen stop must use the live 40k, not the 50k running peak.
        warpTo(Calendar.P - 5 days);
        _setPx(40_000);
        crankUntilIdle(v, 90);

        assertLt(readPos(address(v)).szi, 0, "short opened in the S-win");
        assertFalse(v.perpStopLong(), "frozen stop is the short side");
        // The S-win freezes on the LIVE price (C = 0): 40k + 40k/φ — NOT the running peak
        // (50k + 50k/φ), which the pre-fix ungated `peakC` would have used (a ~25% over-lever).
        // (The frozen stop is the exact quantity the fix corrects; the realized liquidation of a
        // ramping mid-window short is the separately-documented per-slice-DCA interim.)
        assertEq(
            v.perpStopWad(),
            StructuralLeverage.shortStructStop(40_000e18, 0, 0),
            "S-win froze at the live price, not the running peak"
        );
        assertLt(
            v.perpStopWad(),
            StructuralLeverage.shortStructStop(40_000e18, 0, 50_000e18),
            "live-p stop is closer than the (wrong) running-peak stop"
        );
    }
}
