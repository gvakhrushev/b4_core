// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VenueTestBase} from "../utils/VenueTestBase.sol";
import {MockLzEndpoint} from "../mocks/MockLzEndpoint.sol";
import {B4Pool} from "src/core/B4Pool.sol";
import {HalvingOracle} from "src/core/HalvingOracle.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";
import {Origin} from "src/interfaces/ILayerZero.sol";

/// @notice The structural-leverage anchor ratchet on B4Pool (SPECIFICATION §7b). Drives the
///         two sampling windows over a real epoch boundary and checks the ratchet, the
///         halving flip, genesis, the permissionless-but-ungameable surface, and the V9
///         sampling-density gate (≥ 10 daily samples spanning ≥ W/2 to confirm a window's anchor;
///         unconfirmed anchors are withheld by the getters and never promoted — V8-M-1).
contract AnchorRatchetTest is VenueTestBase {
    uint32 constant SRC_EID = 30_101;
    bytes32 constant SRC_SENDER = bytes32(uint256(1));
    uint256 constant GEN_HEIGHT = 840_000;
    uint256 constant GEN_TS = 1_713_571_767;

    MockLzEndpoint endpoint;
    HalvingOracle oracle;
    B4Pool pool;
    uint256 constant DIR = 1; // UBTC directional index

    function setUp() public {
        vm.warp(GEN_TS);
        setUpVenue();
        endpoint = new MockLzEndpoint();
        oracle =
            new HalvingOracle(address(endpoint), SRC_EID, SRC_SENDER, GEN_HEIGHT, address(this));
        _acceptHalving(GEN_HEIGHT, uint32(GEN_TS));
        CoreTypes.AssetDescriptor[] memory ds = new CoreTypes.AssetDescriptor[](2);
        ds[0] = usdcDescriptor();
        ds[1] = ubtcDescriptor();
        pool = new B4Pool(address(oracle), ds, address(this));
    }

    function _at(uint256 t) internal {
        vm.warp(GEN_TS + t);
    }

    function _setBtc(uint256 usd) internal {
        hub.setSpotPx(SPOT_MKT, uint64(usd * 1e4)); // 8−4 = 4 px decimals for UBTC
    }

    /// Sample `n` times, one day apart, starting at the ABSOLUTE time `t0abs`, at price
    /// `px`. 11 daily samples satisfy the V9 density gate (≥ 10 daily samples spanning ≥ W/2 =
    /// 10 days), so the window's anchor confirms and the getters expose it.
    function _sampleDailyAbs(uint256 t0abs, uint256 n, uint256 px) internal {
        for (uint256 k = 0; k < n; k++) {
            vm.warp(t0abs + k * 1 days);
            _setBtc(px);
            pool.sampleAnchor(DIR);
        }
    }

    function _cap() internal view returns (uint256) {
        (, uint256 c) = pool.anchors(DIR);
        return c;
    }

    function _floor() internal view returns (uint256) {
        (uint256 f,) = pool.anchors(DIR);
        return f;
    }

    // ------------------------------------------------------------- guards & genesis

    function test_genesis_anchors_zero() public view {
        (uint256 f, uint256 c) = pool.anchors(DIR);
        assertEq(f, 0);
        assertEq(c, 0);
    }

    function test_bad_asset_reverts() public {
        _at(Calendar.T + 1 days);
        vm.expectRevert(B4Pool.BadAsset.selector);
        pool.sampleAnchor(0); // settlement asset has no anchor
        vm.expectRevert(B4Pool.BadAsset.selector);
        pool.sampleAnchor(2); // out of range (only index 1 is directional)
    }

    function test_outside_window_reverts() public {
        _at(Calendar.W + 1 days); // past the post-halving window, before the 62-window
        vm.expectRevert(B4Pool.NotInWindow.selector);
        pool.sampleAnchor(DIR);
        _at(Calendar.T + Calendar.W + 1 days); // past the 62-window
        vm.expectRevert(B4Pool.NotInWindow.selector);
        pool.sampleAnchor(DIR);
    }

    function test_zero_price_reverts() public {
        _at(Calendar.T + 1 days);
        hub.setSpotPx(SPOT_MKT, 0);
        vm.expectRevert(B4Pool.ZeroPrice.selector);
        pool.sampleAnchor(DIR);
    }

    // ------------------------------------------------------------- the 62-window ratchet

    /// Within a window the cap tracks the running minimum DOWN; a higher later price does not
    /// raise it. The floor stays 0 in the first cycle (no prior structural low). Sampled
    /// densely so the V9 density gate confirms the window and the getter exposes the cap.
    function test_62_window_ratchets_down_only() public {
        _sampleDailyAbs(GEN_TS + Calendar.T, 11, 20_000);
        assertEq(_cap() / 1e18, 20_000, "cap seeded and confirmed");
        assertEq(_floor(), 0, "no prior low yet");

        _at(Calendar.T + 11 days);
        _setBtc(16_000); // a lower low
        pool.sampleAnchor(DIR);
        assertEq(_cap() / 1e18, 16_000, "cap ratcheted down");

        _at(Calendar.T + 12 days);
        _setBtc(19_000); // higher again
        pool.sampleAnchor(DIR);
        assertEq(_cap() / 1e18, 16_000, "cap does NOT rise");
    }

    // ------------------------------------------------------------- the halving flip

    /// The full ratchet across an epoch: sample a 62-window bottom (densely → confirmed),
    /// accept the next halving, then sample the post-halving window — the previous cap
    /// becomes the new floor (the flip) and the cap reseeds to the post-halving low.
    function test_halving_flip_previous_cap_becomes_floor() public {
        // Cycle 0's 62-window bottom = 16,000.
        _sampleDailyAbs(GEN_TS + Calendar.T + 1 days, 11, 16_000);
        assertEq(_floor(), 0);
        assertEq(_cap() / 1e18, 16_000);

        // Next halving lands (epoch 0 → 1); the fact's timestamp must not be in the future,
        // so warp to it before accepting, then step 2 days into the new post-halving window.
        uint256 hts = GEN_TS + Calendar.T + 30 days;
        vm.warp(hts);
        _acceptHalving(GEN_HEIGHT + 210_000, uint32(hts));
        vm.warp(hts + 2 days); // t = timeSinceHalving = 2 days
        _setBtc(60_000); // post-halving consolidation area
        pool.sampleAnchor(DIR); // kind-0 opening: the flip fires
        assertEq(_floor() / 1e18, 16_000, "old cap flipped to floor");

        // Complete the dense post-halving window so the reseeded cap confirms.
        _sampleDailyAbs(hts + 3 days, 10, 60_000);
        assertEq(_cap() / 1e18, 60_000, "cap reseeded to the post-halving low");

        // Ratchet the post-halving window down; floor is untouched by intra-window samples.
        vm.warp(hts + 13 days);
        _setBtc(52_000);
        pool.sampleAnchor(DIR);
        assertEq(_floor() / 1e18, 16_000, "floor stable within the window");
        assertEq(_cap() / 1e18, 52_000, "cap ratchets down");
    }

    /// A 62-window opening does NOT flip the floor — only the cap reseeds.
    function test_62_window_open_keeps_floor() public {
        // Establish (floor=16000, cap=60000) via a flip (both windows sampled densely).
        _sampleDailyAbs(GEN_TS + Calendar.T + 1 days, 11, 16_000);
        uint256 hts = GEN_TS + Calendar.T + 30 days;
        vm.warp(hts);
        _acceptHalving(GEN_HEIGHT + 210_000, uint32(hts));
        _sampleDailyAbs(hts + 1 days, 11, 60_000);
        assertEq(_floor() / 1e18, 16_000);

        // The 62-window of this NEW epoch opens: cap reseeds to the new bottom, floor unchanged.
        _sampleDailyAbs(hts + Calendar.T + 1 days, 11, 40_000);
        assertEq(_floor() / 1e18, 16_000, "62-window open does not flip the floor");
        assertEq(_cap() / 1e18, 40_000, "cap reseeded to the new 62-window bottom");
    }

    /// F1 (audit 2026-07-22): if a cycle's 62-window goes UNSAMPLED, the cap still holds that
    /// epoch's post-halving low (an odd/kind-0 tag). The next halving flip MUST NOT promote it
    /// to floor — a post-halving low is not a cycle bottom and the market breaks it. The floor
    /// must stay at the prior confirmed low (0 here), the conservative direction. The kind-0
    /// window is sampled DENSELY so this test pins the tag-parity gate itself, not the V9
    /// density gate (which independently blocks sparse windows — see V9AnchorDensity.t.sol).
    function test_flip_skips_promotion_when_62_window_unsampled() public {
        // Epoch 0: sample ONLY the post-halving window (densely → confirmed); the 62-window
        // is skipped. The cap holds a near-halving price, NOT the cycle bottom.
        _sampleDailyAbs(GEN_TS + 1 days, 11, 56_500);
        assertEq(_floor(), 0, "no floor yet");
        assertEq(_cap() / 1e18, 56_500, "cap holds the post-halving low (kind-0, odd tag)");
        // (No 62-window sample this epoch — the keeper missed it.)

        // Next halving; first post-halving sample of epoch 1 fires the flip.
        uint256 hts = GEN_TS + Calendar.T + 30 days;
        vm.warp(hts);
        _acceptHalving(GEN_HEIGHT + 210_000, uint32(hts));
        _sampleDailyAbs(hts + 1 days, 11, 60_000);

        // The unconfirmed (odd-tag) cap is NOT promoted; floor stays at the prior confirmed
        // low. (Pre-F1 this promoted 56,500 into floor, poisoning it high for a full cycle.)
        assertEq(_floor(), 0, "unconfirmed 62-window: floor NOT poisoned by the post-halving low");
        assertEq(_cap() / 1e18, 60_000, "cap still reseeds normally");
    }

    // ------------------------------------------------------------- the peak ratchet (short side)

    function _peakC() internal view returns (uint256) {
        (, uint256 c,) = pool.peaks(DIR);
        return c;
    }

    function _prevPeak() internal view returns (uint256) {
        (uint256 pp,,) = pool.peaks(DIR);
        return pp;
    }

    function test_genesis_peaks_zero() public view {
        (uint256 pp, uint256 c,) = pool.peaks(DIR);
        assertEq(pp, 0);
        assertEq(c, 0);
    }

    /// The peak window `[P−W, P)` ratchets the peak UP; a lower later price does not lower it.
    /// Sampled densely so the V9 density gate confirms the window and the getter exposes it.
    function test_peak_window_ratchets_up_only() public {
        _sampleDailyAbs(GEN_TS + Calendar.P - Calendar.W + 1 days, 11, 40_000);
        assertEq(_peakC() / 1e18, 40_000, "peakC seeded and confirmed");
        assertEq(_prevPeak(), 0, "no prior peak yet");

        _at(Calendar.P - Calendar.W + 12 days);
        _setBtc(52_000); // a higher high
        pool.sampleAnchor(DIR);
        assertEq(_peakC() / 1e18, 52_000, "peakC ratcheted up");

        _at(Calendar.P - 2 days);
        _setBtc(45_000); // lower again
        pool.sampleAnchor(DIR);
        assertEq(_peakC() / 1e18, 52_000, "peakC does NOT fall");
    }

    /// Across a halving the previous cycle's confirmed peak flips into `prevPeak` and `peakC`
    /// reseeds — the exact mirror of the low-side halving flip. Both windows sampled densely
    /// (the V9 density gate confirms the outgoing window before it can promote).
    function test_peak_flip_across_halving() public {
        _sampleDailyAbs(GEN_TS + Calendar.P - Calendar.W + 1 days, 11, 52_000);
        assertEq(_prevPeak(), 0);
        assertEq(_peakC() / 1e18, 52_000);

        uint256 hts = GEN_TS + Calendar.T + 30 days;
        vm.warp(hts);
        _acceptHalving(GEN_HEIGHT + 210_000, uint32(hts));
        _sampleDailyAbs(hts + Calendar.P - Calendar.W + 1 days, 11, 120_000);
        assertEq(_prevPeak() / 1e18, 52_000, "prev cycle peak flipped to prevPeak");
        assertEq(_peakC() / 1e18, 120_000, "peakC reseeded to the new cycle's peak");
    }

    // ------------------------------------------------------------- the density gate (V9)

    /// A window confirms its anchor only at ≥ 10 daily samples spanning ≥ W/2 (10 days); the
    /// getters WITHHOLD the anchor until then. Both thresholds are pinned independently.
    /// (The engine-level consequences live in V9AnchorDensity.t.sol.)
    function test_density_gate_confirmation_threshold() public {
        (bool lowConfirmed,) = pool.anchorConfirmed(DIR);
        assertFalse(lowConfirmed, "genesis: unconfirmed");
        assertEq(_cap(), 0);

        // 9 samples over an 8-day span: below both thresholds.
        _sampleDailyAbs(GEN_TS + Calendar.T + 1 days, 9, 20_000);
        (lowConfirmed,) = pool.anchorConfirmed(DIR);
        assertFalse(lowConfirmed, "9 samples / 8-day span: unconfirmed");
        assertEq(_cap(), 0, "cap withheld while unconfirmed");

        // The 10th sample at a 9-day span: the count threshold alone does not confirm.
        _at(Calendar.T + 10 days);
        _setBtc(20_000);
        pool.sampleAnchor(DIR);
        (lowConfirmed,) = pool.anchorConfirmed(DIR);
        assertFalse(lowConfirmed, "10 samples / 9-day span: unconfirmed (span short)");

        // The 11th sample at a 10-day span: count ≥ 10 AND span ≥ W/2 → confirmed.
        _at(Calendar.T + 11 days);
        _setBtc(20_000);
        pool.sampleAnchor(DIR);
        (lowConfirmed,) = pool.anchorConfirmed(DIR);
        assertTrue(lowConfirmed, "11 samples / 10-day span: confirmed");
        assertEq(_cap() / 1e18, 20_000, "confirmed cap exposed");
    }

    /// Same-block spam is not a distinct observation. The density gate's contract is
    /// `MIN_ANCHOR_SAMPLES` daily observations across >= W/2, not merely that many calls.
    function test_density_gate_ignores_same_timestamp_repeats() public {
        _at(Calendar.T + 1 days);
        _setBtc(20_000);
        pool.sampleAnchor(DIR);
        for (uint256 k = 0; k < 8; k++) {
            pool.sampleAnchor(DIR); // same timestamp: must not increase density
        }

        _at(Calendar.T + 11 days);
        _setBtc(20_000);
        pool.sampleAnchor(DIR); // only the second distinct timestamp

        (bool lowConfirmed,) = pool.anchorConfirmed(DIR);
        assertFalse(lowConfirmed, "two distinct timestamps cannot confirm a 20-day window");
        assertEq(_cap(), 0, "under-sampled cap stays withheld");
    }

    function test_density_gate_ignores_subday_repeat_spam() public {
        uint256 start = GEN_TS + Calendar.T + 1 days;
        for (uint256 k = 0; k < 10; k++) {
            vm.warp(start + k * 2 hours);
            _setBtc(20_000);
            pool.sampleAnchor(DIR);
        }
        vm.warp(start + Calendar.W / 2);
        _setBtc(20_000);
        pool.sampleAnchor(DIR);

        (bool lowConfirmed,) = pool.anchorConfirmed(DIR);
        assertFalse(lowConfirmed, "sub-day calls do not count as daily window coverage");
        assertEq(_cap(), 0, "compressed anchor stays withheld");
    }

    function _acceptHalving(uint256 height, uint32 ts) internal {
        bytes memory h = new bytes(80);
        h[68] = bytes1(uint8(ts));
        h[69] = bytes1(uint8(ts >> 8));
        h[70] = bytes1(uint8(ts >> 16));
        h[71] = bytes1(uint8(ts >> 24));
        vm.prank(address(endpoint));
        oracle.lzReceive(
            Origin(SRC_EID, SRC_SENDER, 1), bytes32(0), abi.encode(height, h), address(0), ""
        );
    }
}
