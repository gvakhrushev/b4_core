// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {StructuralLeverage} from "src/libraries/StructuralLeverage.sol";
import {Phi} from "src/libraries/Phi.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";

/// @notice V8 Scope C — REGRESSION for V8-M-1 (sparse-peak over-leverage) and V8-L-2
///         (prevPeak stranded on a skip), both fixed by the V9 sampling-density gate
///         (≥ 10 daily samples spanning ≥ W/2 to confirm a window's anchor). Pre-fix these PoCs
///         DEMONSTRATED the bugs; they now pin the SAFE behavior, quoting the pre-fix
///         measurements as the regression baseline:
///         - sparse peakC 110k vs true 130k, prevPeak 100k, Fall entry 90k → pre-fix the
///           engine froze maxStop 116.18k and realized 3.44× (liquidation ≈116k, BELOW the
///           proven 130k peak — inside the market-proven range); post-fix the sparse peak
///           is WITHHELD and the engine refuses to anchor to it.
///         - a skipped peak window pre-fix stranded prevPeak at 0 (silent genesis flat-φ
///           degrade); post-fix a confirmed peak promotes EAGERLY at the halving flip and
///           the short runs the anchored window extrapolation off it instead.
contract V8C_SparsePeakTest is VaultTestBase {
    uint256 constant DIR = 1;

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

    /// Effective venue leverage: entryNtl / margin.
    function _levWad(B4Vault v) internal view returns (uint256) {
        CoreTypes.Position memory p = readPos(address(v));
        if (v.perpMargin6() == 0) return 0;
        return Phi.mulDiv(uint256(p.entryNtl), Phi.WAD, v.perpMargin6());
    }

    /// Short liquidation (WAD): (entryNtl + margin) / |szi|.
    function _liqShortWad(B4Vault v) internal view returns (uint256) {
        CoreTypes.Position memory p = readPos(address(v));
        if (p.szi >= 0) return 0;
        return Phi.mulDiv(
            (uint256(p.entryNtl) + v.perpMargin6()) * 1e4, Phi.WAD, uint256(uint64(-p.szi)) * 1e6
        );
    }

    /// Sample `n` times, one day apart, starting at the ABSOLUTE time `t0abs`, at price
    /// `px`. 11 daily samples satisfy the V9 density gate (count ≥ 10 AND span ≥ W/2).
    function _sampleDaily(uint256 t0abs, uint256 n, uint256 px) internal {
        for (uint256 k = 0; k < n; k++) {
            vm.warp(t0abs + k * 1 days);
            _setPx(px);
            pool.sampleAnchor(DIR);
        }
    }

    function _halvingAt(uint256 hts, uint256 height) internal {
        vm.warp(hts);
        acceptHalving(height, uint32(hts));
    }

    /// Epoch-0 peak window sampled DENSELY at `px` (confirmed), then the halving accepted.
    function _denseEpochZeroPeakThenHalving(uint256 px) internal returns (uint256 hts) {
        _sampleDaily(GENESIS_TS + Calendar.P - Calendar.W + 1 days, 11, px);
        hts = GENESIS_TS + Calendar.T + 30 days;
        _halvingAt(hts, GENESIS_HEIGHT + 210_000);
    }

    // ============================================= V8-M-1 regression: sparse peak withheld

    /// Pre-fix behavior (regression baseline): the cycle-1 peak window sampled ONCE at its
    /// open (110k; the true 130k max never sampled) passed the freshness gate, the engine
    /// fed the sparse C, froze maxStop 116.18k and realized 3.44× vs the honest 1.54× —
    /// with the realized liquidation ≈116k BELOW the true printed 130k peak, inside the
    /// price range the market already proved.
    /// Post-fix: the sparse window never confirms — `peaks()` withholds peakC (read as 0,
    /// tag still fresh) and the Fall entry at 90k (≤ prevPeak 100k, no confirmed C) is
    /// REFUSED. No leveraged position is ever sized against a sparse anchor.
    function test_sparsePeak_withheld_engine_refuses_regression() public {
        uint256 hts = _denseEpochZeroPeakThenHalving(100_000); // prevPeak for cycle 1 = 100k

        // Cycle-1 peak window: sampled ONCE at its open. True max 130k never sampled.
        vm.warp(hts + Calendar.P - Calendar.W + 2 days);
        _setPx(110_000);
        pool.sampleAnchor(DIR);
        (uint256 pp, uint256 c, uint256 tag) = pool.peaks(DIR);
        assertEq(pp, 100_000e18, "prevPeak = confirmed cycle-0 peak");
        assertEq(c, 0, "FIXED: sparse peakC withheld (pre-fix: 110k fed)");
        assertEq(tag, oracle.epoch() + 1, "freshness tag advances (withheld != stale)");

        // Fall of cycle 1: the Pro Max short at 90k is refused.
        vm.warp(hts + Calendar.P + 30 days);
        _setPx(90_000);
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 0, 120_000e6);
        crankUntilIdle(v, 60);

        assertEq(readPos(address(v)).szi, 0, "FIXED: no short opened against a sparse anchor");
        assertEq(v.perpMargin6(), 0, "no margin deployed");
        assertEq(
            v.perpStopWad(), 0, "nothing frozen (pre-fix: 116.18k stop at 3.44x, liq inside range)"
        );
    }

    /// Control: the SAME window sampled DENSELY (110k at the open, 130k printed daily
    /// after) confirms peakC at the true max and de-leverages the identical Fall entry to
    /// the honest ~1.54×, with the liquidation BEYOND the proven extreme. (The freshness
    /// tag was identical in the sparse scenario — the tag never distinguished sparse from
    /// dense; the density gate now does.)
    function test_denseSampling_sameWindow_deleverages() public {
        uint256 hts = _denseEpochZeroPeakThenHalving(100_000);

        vm.warp(hts + Calendar.P - Calendar.W + 1 days);
        _setPx(110_000);
        pool.sampleAnchor(DIR);
        _sampleDaily(hts + Calendar.P - Calendar.W + 2 days, 10, 130_000); // true max, dense
        (uint256 pp, uint256 c, uint256 tag) = pool.peaks(DIR);
        assertEq(pp, 100_000e18);
        assertEq(c, 130_000e18, "dense sampling confirms the true peak");
        assertEq(tag, oracle.epoch() + 1, "same freshness tag as the sparse scenario");

        vm.warp(hts + Calendar.P + 30 days);
        _setPx(90_000);
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 0, 120_000e6);
        crankUntilIdle(v, 60);

        assertLt(readPos(address(v)).szi, 0, "short opened");
        assertApproxEqRel(
            _levWad(v),
            StructuralLeverage.shortStructLev(90_000e18, 100_000e18, 130_000e18),
            0.03e18,
            "dense leverage == honest structural leverage (~1.54x)"
        );
        assertGt(_liqShortWad(v), 130_000e18, "liquidation BEYOND the proven extreme");
    }

    // ===================================================== lifecycle edges (V8-L-2 fixed)

    /// Genesis (no peak ever sampled, prevPeak == peakC == peakTag == 0): the Fall short
    /// must NOT refuse — `shortStructStop(p, 0, 0)` = p + p/φ = 1.618p ⇒ exactly flat φ.
    /// (Unaffected by the density gate: nothing sampled, nothing withheld.)
    function test_genesis_fall_short_degrades_to_flat_phi() public {
        warpTo(Calendar.P + 30 days);
        _setPx(40_000);
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 0, 120_000e6);
        crankUntilIdle(v, 60);

        assertLt(readPos(address(v)).szi, 0, "genesis short opens (NOT refused)");
        assertEq(
            v.perpStopWad(),
            StructuralLeverage.shortStructStop(40_000e18, 0, 0),
            "genesis stop = 1.618p"
        );
        assertApproxEqRel(_levWad(v), Phi.PHI, 0.03e18, "genesis leverage == flat phi");
    }

    /// V8-L-2 regression: cycle-0 peak confirmed DENSE (60k); the cycle-1 peak window is
    /// SKIPPED entirely. Pre-fix prevPeak promoted only inside a peak-window SAMPLE, so the
    /// skip stranded it at 0 and the Fall short silently degraded to the genesis flat-φ
    /// path (stop 1.618p, unanchored). Post-fix the confirmed peak promotes EAGERLY at the
    /// halving flip (mirroring the low side): the stale tag still gates C to 0, but the
    /// short now runs the anchored S-win extrapolation off the confirmed prevPeak
    /// (stop = p + (p − Pp)/φ), and an entry at/below that prevPeak is REFUSED again.
    function test_skipped_peak_window_promotes_eagerly_runs_anchored_extrapolation() public {
        uint256 hts = _denseEpochZeroPeakThenHalving(60_000); // cycle-0 peak 60k, confirmed
        // Fire the halving flip (kind-0 opening of epoch 1); the cycle-1 peak window is
        // SKIPPED entirely from here on.
        vm.warp(hts + 2 days);
        _setPx(50_000);
        pool.sampleAnchor(DIR);
        (uint256 pp, uint256 c, uint256 tag) = pool.peaks(DIR);
        assertEq(pp, 60_000e18, "FIXED: prevPeak promoted EAGERLY at the flip (pre-fix: 0)");
        assertEq(c, 60_000e18, "cycle-0 peak parked in peakC (still confirmed)");
        assertEq(tag, 1, "tag stale (epoch-0 window)");

        vm.warp(hts + Calendar.P + 30 days); // Fall of cycle 1
        assertEq(oracle.epoch() + 1, 2, "gate wants tag 2; stale 1 rejected so C = 0");

        _setPx(90_000);
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 0, 120_000e6);
        crankUntilIdle(v, 60);
        assertLt(readPos(address(v)).szi, 0, "short opened (anchored, not genesis flat-phi)");
        assertEq(
            v.perpStopWad(),
            StructuralLeverage.shortStructStop(90_000e18, 60_000e18, 0),
            "anchored S-win extrapolation off the confirmed prevPeak"
        );
        assertApproxEqRel(
            _levWad(v),
            StructuralLeverage.shortStructLev(90_000e18, 60_000e18, 0),
            0.03e18,
            "~4.85x: the clamp-backed window regime (StructuralLeverage caveat), anchored"
        );

        // prevPeak promoted ⇒ the `p <= Pp` refusal is live again: a deep entry at/below
        // the confirmed prior peak has no positive delta and is refused (pre-fix the
        // stranded prevPeak == 0 disabled the gate and the entry opened unanchored).
        _setPx(50_000);
        B4Vault v2 = createVault(address(proMax));
        fundAndDeposit(v2, 0, 120_000e6);
        crankUntilIdle(v2, 60);
        assertEq(readPos(address(v2)).szi, 0, "entry at/below confirmed prevPeak: refused");
    }

    /// TWO consecutive skipped peak windows. Pre-fix the confirmed 60k peak was never
    /// promoted (promotion happened only inside a peak-window SAMPLE), so cycle 2's Fall
    /// saw (prevPeak, C) = (0, 0) and degraded to genesis flat-φ — the anchor chain broke
    /// silently on a single skip. Post-fix the peak is REMEMBERED: promoted eagerly at the
    /// first flip, untouched by the second (its tag no longer matches the current epoch).
    function test_two_consecutive_skips_remember_the_confirmed_peak() public {
        uint256 hts = _denseEpochZeroPeakThenHalving(60_000);
        vm.warp(hts + 2 days); // epoch-1 flip: eager promotion fires
        _setPx(50_000);
        pool.sampleAnchor(DIR);
        // Skip the cycle-1 peak window; accept the cycle-2 halving; skip cycle-2 too.
        uint256 hts2 = hts + Calendar.T + 30 days;
        _halvingAt(hts2, GENESIS_HEIGHT + 420_000);
        vm.warp(hts2 + 2 days); // epoch-2 flip: peakTag (1) != epoch (2) — no move
        _setPx(45_000);
        pool.sampleAnchor(DIR);

        (uint256 pp, uint256 c, uint256 tag) = pool.peaks(DIR);
        assertEq(pp, 60_000e18, "confirmed peak REMEMBERED across two skips (pre-fix: 0)");
        assertEq(c, 60_000e18, "still parked (confirmed)");
        assertEq(tag, 1, "tag two epochs stale");

        vm.warp(hts2 + Calendar.P + 30 days); // Fall of cycle 2
        _setPx(90_000);
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 0, 120_000e6);
        crankUntilIdle(v, 60);

        assertLt(readPos(address(v)).szi, 0, "short opens anchored");
        assertEq(
            v.perpStopWad(),
            StructuralLeverage.shortStructStop(90_000e18, 60_000e18, 0),
            "anchored extrapolation (pre-fix: genesis flat-phi -- anchors forgotten)"
        );
        assertApproxEqRel(
            _levWad(v),
            StructuralLeverage.shortStructLev(90_000e18, 60_000e18, 0),
            0.03e18,
            "~4.85x anchored window regime, not the unanchored 1.618x genesis degrade"
        );
    }
}
