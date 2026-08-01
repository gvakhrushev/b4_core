// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {StructuralLeverage} from "src/libraries/StructuralLeverage.sol";
import {Phi} from "src/libraries/Phi.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";

/// @notice V9 — the anchor sampling-density gate (audit findings V8-M-1, V8-M-2, V8-L-2).
///         A sampling window CONFIRMS its anchor only at ≥ 10 daily samples spanning ≥ W/2 of the
///         window; an unconfirmed (sparse, compressed, or single-wick) anchor is WITHHELD —
///         the pool getters read it as 0 ("absent"), it is never promoted into
///         floor/prevPeak, and the engine never sizes a leveraged position against it.
///         These tests encode the FIXED behavior: the sparse/wick/eager tests FAIL on the
///         pre-fix code (they detect the bugs); the dense controls pass before and after
///         (behavior preservation).
contract V9AnchorDensityTest is VaultTestBase {
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

    /// Sample the anchor ratchet `n` times, one day apart, starting at absolute time `t0`,
    /// at a constant price. 11 daily samples satisfy the confirmation gate (count ≥ 10
    /// AND span ≥ W/2 = 10 days).
    function _sampleDaily(uint256 t0, uint256 n, uint256 px) internal {
        for (uint256 k = 0; k < n; k++) {
            vm.warp(t0 + k * 1 days);
            _setPx(px);
            pool.sampleAnchor(DIR);
        }
    }

    function _halvingAt(uint256 hts, uint256 height) internal {
        vm.warp(hts);
        acceptHalving(height, uint32(hts));
    }

    // ============================================= low side: floor promotion density gate

    /// DENSE control (passes before and after the fix): a 62-window sampled daily confirms
    /// its bottom and the halving flip promotes it into `floor` exactly as before.
    function test_dense_62_window_confirms_floor_promotes() public {
        _sampleDaily(GENESIS_TS + Calendar.T + 1 days, 11, 16_000);
        (, uint256 cap_) = pool.anchors(DIR);
        assertEq(cap_, 16_000e18, "dense window: cap confirmed and exposed");

        uint256 hts = GENESIS_TS + Calendar.T + 30 days;
        _halvingAt(hts, GENESIS_HEIGHT + 210_000);
        vm.warp(hts + 2 days);
        _setPx(60_000);
        pool.sampleAnchor(DIR); // kind-0 opening: the halving flip fires
        (uint256 floor_,) = pool.anchors(DIR);
        assertEq(floor_, 16_000e18, "confirmed cap promotes to floor (as before)");
    }

    /// SPARSE (V8-M-1 fix, low side — the V6-M-1 class): a 62-window sampled 3 times in
    /// 3 days never confirms — the cap is WITHHELD from the getters and the halving flip
    /// does NOT promote the floor. Pre-fix this promoted the sparse 20k upper bound into
    /// the floor for a full cycle, over-levering every long on the pool.
    function test_sparse_62_window_withheld_no_floor_promotion() public {
        for (uint256 k = 0; k < 3; k++) {
            vm.warp(GENESIS_TS + Calendar.T + (k + 1) * 1 days);
            _setPx(20_000);
            pool.sampleAnchor(DIR);
        }
        (, uint256 cap_) = pool.anchors(DIR);
        assertEq(cap_, 0, "sparse window: cap WITHHELD (pre-fix: 20k exposed)");

        uint256 hts = GENESIS_TS + Calendar.T + 30 days;
        _halvingAt(hts, GENESIS_HEIGHT + 210_000);
        vm.warp(hts + 2 days);
        _setPx(60_000);
        pool.sampleAnchor(DIR);
        (uint256 floor_,) = pool.anchors(DIR);
        assertEq(floor_, 0, "sparse window: floor NOT promoted (pre-fix: 20k poisoned)");
    }

    /// COMPRESSED: 11 calls packed into 5 days count as only daily observations. One
    /// endpoint sample at W/2 still leaves the window under-dense; the remaining daily
    /// observations are required before confirmation.
    function test_compressed_sampling_requires_daily_observations_and_span() public {
        for (uint256 k = 0; k < 11; k++) {
            vm.warp(GENESIS_TS + Calendar.T + 1 days + k * 12 hours);
            _setPx(20_000);
            pool.sampleAnchor(DIR);
        }
        (, uint256 cap_) = pool.anchors(DIR);
        assertEq(cap_, 0, "11 samples in 5 days: span < W/2, still WITHHELD");

        vm.warp(GENESIS_TS + Calendar.T + 11 days); // span now exactly W/2
        _setPx(20_000);
        pool.sampleAnchor(DIR);
        (, cap_) = pool.anchors(DIR);
        assertEq(cap_, 0, "endpoint span alone cannot replace daily density");

        for (uint256 d = 12; d <= 16; d++) {
            vm.warp(GENESIS_TS + Calendar.T + d * 1 days);
            _setPx(20_000);
            pool.sampleAnchor(DIR);
        }
        (, cap_) = pool.anchors(DIR);
        assertEq(cap_, 20_000e18, "daily count + span confirms");
    }

    /// Engine mirror of the sparse low (V6-M-1, long side): a sparse 62-window leaves
    /// TerminalGrowth WITHOUT a confirmed cap — the leveraged long degrades to the flat-φ
    /// stop instead of pinning the fixed MinStop to an under-sampled low. Pre-fix the
    /// engine froze MinStop off the sparse 20k cap (floor 16k): 20k − (20k−16k)/φ ≈
    /// 17.53k, over-levering the long all of terminal growth.
    function test_sparse_cap_withheld_long_side_degrades_flat_phi() public {
        _sampleDaily(GENESIS_TS + Calendar.T + 1 days, 11, 16_000); // dense cycle-0 bottom
        uint256 hts = GENESIS_TS + Calendar.T + 30 days;
        _halvingAt(hts, GENESIS_HEIGHT + 210_000);
        for (uint256 k = 0; k < 3; k++) {
            // Sparse cycle-1 62-window: 3 samples in 3 days.
            vm.warp(hts + Calendar.T + (k + 1) * 1 days);
            _setPx(20_000);
            pool.sampleAnchor(DIR);
        }
        (, uint256 cap_) = pool.anchors(DIR);
        assertEq(cap_, 0, "sparse 62-window withheld (pre-fix: 20k exposed)");

        vm.warp(hts + Calendar.T + Calendar.W + 10 days); // TerminalGrowth of cycle 1
        _setPx(80_000);
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 0, 120_000e6);
        crankUntilIdle(v, 60);
        assertGt(readPos(address(v)).szi, 0, "long opens on the degrade path");
        assertEq(
            v.perpStopWad(),
            StructuralLeverage.longStop(80_000e18, 0, 0),
            "unconfirmed cap: flat-phi degrade, NOT the sparse MinStop"
        );
        assertApproxEqRel(_levWad(v), Phi.PHI, 0.03e18, "leverage == phi (fail-safe)");
    }

    // ============================================= peak side: V8-M-1 sparse peak / V8-M-2 wick

    /// Epoch-0 peak window sampled DENSELY at `px`, then the halving accepted at T+30d.
    function _denseEpochZeroPeakThenHalving(uint256 px) internal returns (uint256 hts) {
        _sampleDaily(GENESIS_TS + Calendar.P - Calendar.W + 1 days, 11, px);
        hts = GENESIS_TS + Calendar.T + 30 days;
        _halvingAt(hts, GENESIS_HEIGHT + 210_000);
    }

    /// V8-M-1 regression (PoC numbers): prevPeak 100k confirmed dense; the cycle-1 peak
    /// window sampled ONCE at its open (110k; the true 130k max never sampled). Pre-fix
    /// the freshness gate passed, the engine fed the sparse C, froze maxStop 116.18k and
    /// realized 3.44× — liquidation ≈116k, BELOW the true 130k peak (inside the range the
    /// market proved). Fixed: the sparse peak is WITHHELD and the Fall entry at 90k
    /// (≤ prevPeak 100k, no confirmed C) is REFUSED — no leveraged position on a sparse
    /// anchor.
    function test_sparse_peak_withheld_engine_refuses_short() public {
        uint256 hts = _denseEpochZeroPeakThenHalving(100_000);

        vm.warp(hts + Calendar.P - Calendar.W + 2 days);
        _setPx(110_000);
        pool.sampleAnchor(DIR); // the ONLY sample of the cycle-1 peak window
        (uint256 pp, uint256 c, uint256 tag) = pool.peaks(DIR);
        assertEq(pp, 100_000e18, "prevPeak promoted from the dense cycle-0 peak");
        assertEq(c, 0, "sparse peakC WITHHELD (pre-fix: 110k fed to the engine)");
        assertEq(tag, 2, "freshness tag still advances (withheld != stale)");

        vm.warp(hts + Calendar.P + 30 days); // Fall of cycle 1
        _setPx(90_000);
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 0, 120_000e6);
        crankUntilIdle(v, 60);
        assertEq(readPos(address(v)).szi, 0, "no short opened against a sparse anchor");
        assertEq(v.perpMargin6(), 0, "no margin deployed");
        assertEq(v.perpStopWad(), 0, "nothing frozen (pre-fix: 116.18k stop at 3.44x)");
    }

    /// DENSE control (passes before and after): the same window sampled daily confirms C
    /// at the true 130k max; the identical Fall entry de-leverages to the honest ~1.54×
    /// with the liquidation BEYOND the proven extreme (the V8-M-1 PoC's honest baseline).
    function test_dense_peak_confirmed_engine_sizes_honest_short() public {
        uint256 hts = _denseEpochZeroPeakThenHalving(100_000);
        vm.warp(hts + Calendar.P - Calendar.W + 1 days);
        _setPx(110_000);
        pool.sampleAnchor(DIR);
        _sampleDaily(hts + Calendar.P - Calendar.W + 2 days, 10, 130_000); // true max, dense
        (uint256 pp, uint256 c,) = pool.peaks(DIR);
        assertEq(pp, 100_000e18);
        assertEq(c, 130_000e18, "dense sampling confirms the true peak");

        // Entry at 70k, DELIBERATELY inside the band where the anchors bind. At 90k the base
        // phi stop (90k*phi = 145.6k) sits between C and maxStop, so the clamp is inert and the
        // engine emits the SAME stop it would with no anchors at all — the assertion below could
        // not tell "the honest dense peak was fed" from "nothing was fed", which is what this
        // test exists to prove. At 70k the pin binds (70k*phi = 113.3k < C).
        vm.warp(hts + Calendar.P + 30 days); // Fall of cycle 1
        _setPx(70_000);
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 0, 120_000e6);
        crankUntilIdle(v, 60);
        assertLt(readPos(address(v)).szi, 0, "short opened");
        assertEq(
            v.perpStopWad(),
            StructuralLeverage.shortStructStop(70_000e18, 100_000e18, 130_000e18),
            "sized on the confirmed anchors"
        );
        // The discriminator: with the anchors the stop is pinned to the printed peak; without
        // them it would be the bare base-phi stop. These must NOT be equal.
        assertEq(v.perpStopWad(), 130_000e18, "pinned to the confirmed peak C");
        assertGt(
            v.perpStopWad(),
            StructuralLeverage.shortStructStop(70_000e18, 0, 0),
            "the anchors CHANGED the stop -- this is what the density gate buys"
        );
        assertGe(_liqShortWad(v), 130_000e18, "liquidation not inside the proven extreme");
    }

    /// V8-M-2 regression (direction-H PoC numbers): one wicked print (70k) in a window
    /// sampled only twice can never be repaired and pre-fix promoted into prevPeak,
    /// over-levering the NEXT cycle to 3.58× vs the 1.96× honest baseline. Fixed: the
    /// 2-sample window never confirms — the wick is neither fed nor promoted; the next
    /// cycle sizes off the honest dense anchors only (de-levered vs honest: fail-safe).
    function test_single_wick_peak_not_promoted_not_fed() public {
        warpTo(Calendar.P - Calendar.W + 2 days);
        _setPx(40_000);
        pool.sampleAnchor(DIR); // honest open
        warpTo(Calendar.P - Calendar.W + 9 days);
        _setPx(70_000);
        pool.sampleAnchor(DIR); // the wick — only the 2nd sample of the window

        uint256 hts = GENESIS_TS + Calendar.T + 30 days;
        _halvingAt(hts, GENESIS_HEIGHT + 210_000);
        _sampleDaily(hts + Calendar.P - Calendar.W + 1 days, 11, 90_000); // honest dense C'
        (uint256 pp, uint256 c,) = pool.peaks(DIR);
        assertEq(pp, 0, "wick NEVER promoted (pre-fix: 70k poisoned prevPeak)");
        assertEq(c, 90_000e18, "honest dense C' confirmed");

        // 50k, not 80k: at 80k the base-phi stop sits mid-band and the clamp is inert, so the
        // assertion would pass identically with no anchor fed at all. At 50k the pin binds.
        vm.warp(hts + Calendar.P + 30 days); // Fall of cycle 1
        _setPx(50_000);
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 0, 120_000e6);
        crankUntilIdle(v, 60);
        assertLt(readPos(address(v)).szi, 0, "short opened on the honest anchors");
        assertEq(
            v.perpStopWad(),
            StructuralLeverage.shortStructStop(50_000e18, 0, 90_000e18),
            "unconfirmed cycle-0 window discarded whole (prevPeak 0)"
        );
        assertEq(v.perpStopWad(), 90_000e18, "pinned to the honest C', not the wick");
        assertGt(
            v.perpStopWad(),
            StructuralLeverage.shortStructStop(50_000e18, 0, 0),
            "the honest anchor CHANGED the stop"
        );
        // The poisoning damage is a CAP effect, so it has to be read where the cap binds: at a
        // deep entry the pin dominates and a poisoned prevPeak changes nothing (both 1.25x here),
        // which is why this comparison is taken at 80k rather than at the engine's 50k entry.
        assertLt(
            StructuralLeverage.shortStructLev(80_000e18, 0, 90_000e18),
            StructuralLeverage.shortStructLev(80_000e18, 40_000e18, 90_000e18),
            "a promoted 40k wick WOULD have over-levered -- it never got promoted"
        );
    }

    // ============================================= V8-L-2: eager prevPeak promotion at the flip

    /// A confirmed peak promotes into `prevPeak` at the HALVING FLIP itself (the first
    /// post-halving window sample), mirroring the low side — no longer stranded until the
    /// next peak-window sample. The lazy peak-window path stays as the fallback and is
    /// idempotent: one coherent, confirmation-gated promotion rule.
    function test_prevPeak_promoted_eagerly_at_halving_flip() public {
        _sampleDaily(GENESIS_TS + Calendar.P - Calendar.W + 1 days, 11, 60_000); // dense 60k
        uint256 hts = GENESIS_TS + Calendar.T + 30 days;
        _halvingAt(hts, GENESIS_HEIGHT + 210_000);

        vm.warp(hts + 2 days); // kind-0 opening of epoch 1 — the halving flip
        _setPx(50_000);
        pool.sampleAnchor(DIR);
        (uint256 pp,,) = pool.peaks(DIR);
        assertEq(pp, 60_000e18, "V8-L-2: prevPeak promoted EAGERLY at the flip (pre-fix: 0)");

        // The lazy path at the next peak-window opening re-promotes the SAME value
        // (idempotent) and reseeds peakC — no double promotion, no contradiction.
        _sampleDaily(hts + Calendar.P - Calendar.W + 1 days, 11, 95_000);
        (uint256 pp2, uint256 c2,) = pool.peaks(DIR);
        assertEq(pp2, 60_000e18, "no double promotion at the peak-window opening");
        assertEq(c2, 95_000e18, "peakC reseeded and confirmed dense");
    }
}
