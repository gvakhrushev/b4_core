// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VenueTestBase} from "../utils/VenueTestBase.sol";
import {MockLzEndpoint} from "../mocks/MockLzEndpoint.sol";
import {B4Pool} from "src/core/B4Pool.sol";
import {HalvingOracle} from "src/core/HalvingOracle.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {Phi} from "src/libraries/Phi.sol";
import {StructuralLeverage} from "src/libraries/StructuralLeverage.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";
import {Origin} from "src/interfaces/ILayerZero.sol";

/// @title V6-A -- sampleAnchor attack hypotheses (a) wick-poisoning, (b) partial-window
///        promotion, (c) ratchet direction. Drives the REAL B4Pool ratchet over epoch
///        boundaries, then measures the leverage the S7b redo would compute from the
///        resulting on-chain anchors (StructuralLeverage is the intended consumer).
contract V6A_AnchorAttacksTest is VenueTestBase {
    uint32 constant SRC_EID = 30_101;
    bytes32 constant SRC_SENDER = bytes32(uint256(1));
    uint256 constant GEN_HEIGHT = 840_000;
    uint256 constant GEN_TS = 1_713_571_767;
    uint256 constant G = uint256(Phi.PHI); // Pro Max base leverage

    MockLzEndpoint endpoint;
    HalvingOracle oracle;
    B4Pool pool;
    uint256 constant DIR = 1;

    function setUp() public {
        vm.warp(GEN_TS);
        setUpVenue();
        endpoint = new MockLzEndpoint();
        oracle = new HalvingOracle(
            address(endpoint), SRC_EID, SRC_SENDER, GEN_HEIGHT, GEN_TS, address(this)
        );
        CoreTypes.AssetDescriptor[] memory ds = new CoreTypes.AssetDescriptor[](2);
        ds[0] = usdcDescriptor();
        ds[1] = ubtcDescriptor();
        pool = new B4Pool(address(oracle), ds);
    }

    function _setBtc(uint256 usd) internal {
        hub.setSpotPx(SPOT_MKT, uint64(usd * 1e4));
    }

    function _floor() internal view returns (uint256) {
        (uint256 f,) = pool.anchors(DIR);
        return f;
    }

    function _cap() internal view returns (uint256) {
        (, uint256 c) = pool.anchors(DIR);
        return c;
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

    // ----------------------------------------------------- (a) wick-DOWN poisoning: REFUTED

    /// Hypothesis (a): a wicked-down 62-window cap becomes a low floor at the flip and
    /// "INCREASES leverage". PoC: drive the ratchet with a wick to 12k (true bottom 16k),
    /// flip, then compare the leverage the redo computes from the poisoned anchors vs the
    /// honest anchors -- for BOTH the capped and the uncapped regime. The wicked floor only
    /// ever LOWERS leverage: the hypothesis has the direction backwards (fail-safe).
    function test_a_wickDown_only_lowers_leverage() public {
        // Cycle 0 62-window: honest bottom 16,000 sampled, then an attacker wick to 12,000.
        _setBtc(16_000);
        vm.warp(GEN_TS + Calendar.T + 3 days);
        pool.sampleAnchor(DIR);
        _setBtc(12_000); // the wick
        vm.warp(GEN_TS + Calendar.T + 5 days);
        pool.sampleAnchor(DIR);
        assertEq(_cap() / 1e18, 12_000, "wick captured: cap is the running min");

        // Halving 1: the poisoned cap flips into the floor.
        uint256 hts = GEN_TS + Calendar.T + 30 days;
        vm.warp(hts);
        _acceptHalving(GEN_HEIGHT + 210_000, uint32(hts));
        _setBtc(60_000);
        vm.warp(hts + 2 days);
        pool.sampleAnchor(DIR);
        assertEq(_floor() / 1e18, 12_000, "poisoned floor");
        assertEq(_cap() / 1e18, 60_000, "cap reseeded");

        // Leverage the S7b redo would compute at p = 100k from poisoned vs honest anchors.
        uint256 p = 100_000e18;
        uint256 lPoison = StructuralLeverage.leverageWad(p, G, 12_000e18, 60_000e18);
        uint256 lHonest = StructuralLeverage.leverageWad(p, G, 16_000e18, 60_000e18);
        assertLt(lPoison, lHonest, "wick-down LOWERS leverage (fail-safe), never raises it");

        // Uncapped regime (cap ignored) -- same direction, so the effect is not cap-specific.
        uint256 lPoisonU = StructuralLeverage.leverageWad(p, G, 12_000e18, 0);
        uint256 lHonestU = StructuralLeverage.leverageWad(p, G, 16_000e18, 0);
        assertLt(lPoisonU, lHonestU, "uncapped: lower floor => lower L");
    }

    // ------------------------------------- (b) partial-window promotion: CONFIRMED (over-leverage)

    /// Hypothesis (b): a 62-window sampled ONCE at its open promotes an upper bound, not the
    /// true bottom. PoC: sample px(T)=20,000 once, never again (keeper asleep / thin asset);
    /// the true 16,000 bottom is never recorded. The flip promotes 20,000 into the floor and
    /// the redo computes a HIGHER leverage than the honest bottom justifies. Direction is
    /// UNSAFE -- under-sampling systematically biases the floor UP (min over samples >= true
    /// min), i.e. toward over-leverage, and nothing on-chain enforces sampling density.
    function test_b_partial_window_promotion_overleverages() public {
        _setBtc(20_000);
        vm.warp(GEN_TS + Calendar.T); // first instant of the 62-window
        pool.sampleAnchor(DIR); // the ONLY sample this window
        // (true bottom 16,000 on day 3 is never sampled -- keeper failure / thin asset)

        uint256 hts = GEN_TS + Calendar.T + 30 days;
        vm.warp(hts);
        _acceptHalving(GEN_HEIGHT + 210_000, uint32(hts));
        _setBtc(60_000);
        vm.warp(hts + 2 days);
        pool.sampleAnchor(DIR);
        assertEq(
            _floor() / 1e18,
            20_000,
            "upper bound promoted to floor (F1 only guards the ZERO-sample case)"
        );

        uint256 p = 100_000e18;
        uint256 lPartial = StructuralLeverage.leverageWad(p, G, 20_000e18, 60_000e18);
        uint256 lTrue = StructuralLeverage.leverageWad(p, G, 16_000e18, 60_000e18);
        assertGt(lPartial, lTrue, "under-sampling => HIGHER leverage (unsafe direction)");
    }

    /// Active variant of (b): an attacker first-samples the 62-window at a wicked-UP price.
    /// The poison holds only if NO honest sample lands afterwards -- a single later sample at
    /// the fair price ratchets the cap back down. Defense = sampling density, off-chain only.
    function test_b_wickUp_reseed_neutralized_by_one_honest_sample() public {
        _setBtc(25_000); // wicked-up price at the window open
        vm.warp(GEN_TS + Calendar.T);
        pool.sampleAnchor(DIR); // attacker first-sample
        assertEq(_cap() / 1e18, 25_000, "poisoned while unsampled");

        _setBtc(16_000); // ONE honest later sample at the fair bottom
        vm.warp(GEN_TS + Calendar.T + 4 days);
        pool.sampleAnchor(DIR);
        assertEq(_cap() / 1e18, 16_000, "honest sample ratchets the wick away");
    }

    // ----------------------------------------------------- (c) ratchet direction: floor CAN move DOWN

    /// SPECIFICATION S7b: "Anchors -- two confirmed structural lows, ratcheted UP only."
    /// PoC: a deeper second bear (62-window bottom 9,000 < floor 16,000) makes the flip move
    /// the floor DOWN. Direction is fail-safe (lower floor => lower leverage), but the
    /// "ratchets UP only" claim is not enforced and is false as stated.
    function test_c_floor_moves_down_on_deeper_bear() public {
        // Establish floor = 16,000 via cycle-0 bottom + flip.
        _setBtc(16_000);
        vm.warp(GEN_TS + Calendar.T + 3 days);
        pool.sampleAnchor(DIR);
        uint256 hts = GEN_TS + Calendar.T + 30 days;
        vm.warp(hts);
        _acceptHalving(GEN_HEIGHT + 210_000, uint32(hts));
        _setBtc(60_000);
        vm.warp(hts + 2 days);
        pool.sampleAnchor(DIR);
        assertEq(_floor() / 1e18, 16_000);

        // Cycle 1 prints a DEEPER 62-window bottom; the next flip moves floor DOWN.
        _setBtc(9_000);
        vm.warp(hts + Calendar.T + 2 days);
        pool.sampleAnchor(DIR);
        uint256 hts2 = hts + Calendar.T + 40 days;
        vm.warp(hts2);
        _acceptHalving(GEN_HEIGHT + 2 * 210_000, uint32(hts2));
        _setBtc(30_000);
        vm.warp(hts2 + 1 days);
        pool.sampleAnchor(DIR);
        assertEq(_floor() / 1e18, 9_000, "floor moved DOWN: 'ratchets UP only' not enforced");
    }

    // ------------------------------------- late LayerZero acceptance skips the flip (critic #3)

    /// Halving 1 delivered 25 days late (> W): the kind-0 window of epoch 1 is unenterable,
    /// so the flip promoting cycle-0's 16,000 bottom never fires -- floor stays stale (0) for
    /// a whole cycle. The NEXT on-time halving flips cycle-1's 40,000 bottom straight in,
    /// SKIPPING the 16,000 bottom entirely. Stale floor is the fail-safe direction (lower L),
    /// refuting critic #3's "floor stale => more leverage"; the bottom-skip is real.
    function test_late_acceptance_skips_flip_and_skips_a_bottom() public {
        // Cycle 0 62-window bottom 16,000 confirmed (even tag).
        _setBtc(16_000);
        vm.warp(GEN_TS + Calendar.T + 3 days);
        pool.sampleAnchor(DIR);

        // Halving 1 happens at hts but is DELIVERED 25 days late.
        uint256 hts = GEN_TS + Calendar.T + 30 days;
        vm.warp(hts + 25 days);
        _acceptHalving(GEN_HEIGHT + 210_000, uint32(hts));
        // t = 25 days > W: post-halving window of epoch 1 is already gone.
        _setBtc(60_000);
        vm.expectRevert(B4Pool.NotInWindow.selector);
        pool.sampleAnchor(DIR);

        // Epoch 1's 62-window opens: kind-1 reseed does NOT flip -- floor stays stale.
        _setBtc(40_000);
        vm.warp(hts + Calendar.T + 1 days);
        pool.sampleAnchor(DIR);
        assertEq(_floor(), 0, "flip skipped: floor a full cycle stale (fail-safe LOW)");
        assertEq(_cap() / 1e18, 40_000);

        // Halving 2 on time: the flip promotes 40,000 -- the 16,000 bottom is SKIPPED forever.
        uint256 hts2 = hts + 1460 days;
        vm.warp(hts2);
        _acceptHalving(GEN_HEIGHT + 2 * 210_000, uint32(hts2));
        _setBtc(70_000);
        vm.warp(hts2 + 2 days);
        pool.sampleAnchor(DIR);
        assertEq(_floor() / 1e18, 40_000, "bottom_N skipped: floor jumps two cycles");
    }
}
