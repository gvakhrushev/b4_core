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
///         halving flip, genesis, and the permissionless-but-ungameable surface.
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
        oracle = new HalvingOracle(
            address(endpoint), SRC_EID, SRC_SENDER, GEN_HEIGHT, GEN_TS, address(this)
        );
        CoreTypes.AssetDescriptor[] memory ds = new CoreTypes.AssetDescriptor[](2);
        ds[0] = usdcDescriptor();
        ds[1] = ubtcDescriptor();
        pool = new B4Pool(address(oracle), ds);
    }

    function _at(uint256 t) internal {
        vm.warp(GEN_TS + t);
    }

    function _setBtc(uint256 usd) internal {
        hub.setSpotPx(SPOT_MKT, uint64(usd * 1e4)); // 8−4 = 4 px decimals for UBTC
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
    /// raise it. The floor stays 0 in the first cycle (no prior structural low).
    function test_62_window_ratchets_down_only() public {
        _at(Calendar.T);
        _setBtc(20_000);
        pool.sampleAnchor(DIR);
        assertEq(_cap() / 1e18, 20_000, "cap seeded");
        assertEq(_floor(), 0, "no prior low yet");

        _at(Calendar.T + 5 days);
        _setBtc(16_000); // a lower low
        pool.sampleAnchor(DIR);
        assertEq(_cap() / 1e18, 16_000, "cap ratcheted down");

        _at(Calendar.T + 9 days);
        _setBtc(19_000); // higher again
        pool.sampleAnchor(DIR);
        assertEq(_cap() / 1e18, 16_000, "cap does NOT rise");
    }

    // ------------------------------------------------------------- the halving flip

    /// The full ratchet across an epoch: sample a 62-window bottom, accept the next halving,
    /// then sample the post-halving window — the previous cap becomes the new floor (the
    /// flip) and the cap reseeds to the post-halving low.
    function test_halving_flip_previous_cap_becomes_floor() public {
        // Cycle 0's 62-window bottom = 16,000.
        _at(Calendar.T + 3 days);
        _setBtc(16_000);
        pool.sampleAnchor(DIR);
        assertEq(_floor(), 0);
        assertEq(_cap() / 1e18, 16_000);

        // Next halving lands (epoch 0 → 1); the fact's timestamp must not be in the future,
        // so warp to it before accepting, then step 2 days into the new post-halving window.
        uint256 hts = GEN_TS + Calendar.T + 30 days;
        vm.warp(hts);
        _acceptHalving(GEN_HEIGHT + 210_000, uint32(hts));
        vm.warp(hts + 2 days); // t = timeSinceHalving = 2 days
        _setBtc(60_000); // post-halving consolidation area
        pool.sampleAnchor(DIR);

        assertEq(_floor() / 1e18, 16_000, "old cap flipped to floor");
        assertEq(_cap() / 1e18, 60_000, "cap reseeded to the post-halving low");

        // Ratchet the post-halving window down; floor is untouched by intra-window samples.
        vm.warp(hts + 10 days);
        _setBtc(52_000);
        pool.sampleAnchor(DIR);
        assertEq(_floor() / 1e18, 16_000, "floor stable within the window");
        assertEq(_cap() / 1e18, 52_000, "cap ratchets down");
    }

    /// A 62-window opening does NOT flip the floor — only the cap reseeds.
    function test_62_window_open_keeps_floor() public {
        // Establish (floor=16000, cap=60000) via a flip.
        _at(Calendar.T + 3 days);
        _setBtc(16_000);
        pool.sampleAnchor(DIR);
        uint256 hts = GEN_TS + Calendar.T + 30 days;
        vm.warp(hts);
        _acceptHalving(GEN_HEIGHT + 210_000, uint32(hts));
        vm.warp(hts + 2 days);
        _setBtc(60_000);
        pool.sampleAnchor(DIR);
        assertEq(_floor() / 1e18, 16_000);

        // The 62-window of this NEW epoch opens: cap reseeds to the new bottom, floor unchanged.
        vm.warp(hts + Calendar.T + 1 days);
        _setBtc(40_000);
        pool.sampleAnchor(DIR);
        assertEq(_floor() / 1e18, 16_000, "62-window open does not flip the floor");
        assertEq(_cap() / 1e18, 40_000, "cap reseeded to the new 62-window bottom");
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
