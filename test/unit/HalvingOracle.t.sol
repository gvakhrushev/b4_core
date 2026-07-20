// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {HalvingOracle} from "src/core/HalvingOracle.sol";
import {HalvingProver, IBitcoinLightClient} from "src/citrea/HalvingProver.sol";
import {BtcHeader} from "src/libraries/BtcHeader.sol";
import {Origin} from "src/interfaces/ILayerZero.sol";
import {MockLzEndpoint} from "../mocks/MockLzEndpoint.sol";

contract MockLightClient is IBitcoinLightClient {
    mapping(uint256 => bytes32) public hashes;

    function set(uint256 height, bytes32 h) external {
        hashes[height] = h;
    }

    function getBlockHash(uint256 height) external view returns (bytes32) {
        return hashes[height];
    }
}

contract BtcHeaderLib {
    function hash(bytes memory h) external pure returns (bytes32) {
        return BtcHeader.hash(h);
    }
}

contract HalvingOracleTest is Test {
    uint32 constant SRC_EID = 30_101;
    bytes32 constant SRC_SENDER = bytes32(uint256(uint160(address(0xBEEF))));
    uint256 constant GENESIS_HEIGHT = 840_000;
    uint256 constant GENESIS_TS = 1_713_571_767; // April 2024 halving

    MockLzEndpoint endpoint;
    HalvingOracle oracle;
    BtcHeaderLib lib;
    address configurator = address(0xC0FFEE);

    function setUp() public {
        vm.warp(GENESIS_TS + 100 days);
        endpoint = new MockLzEndpoint();
        lib = new BtcHeaderLib();
        oracle = new HalvingOracle(
            address(endpoint), SRC_EID, SRC_SENDER, GENESIS_HEIGHT, GENESIS_TS, configurator
        );
    }

    function _header(uint32 ts) internal pure returns (bytes memory h) {
        h = new bytes(80);
        h[0] = 0x04; // arbitrary non-timestamp bytes
        h[68] = bytes1(uint8(ts));
        h[69] = bytes1(uint8(ts >> 8));
        h[70] = bytes1(uint8(ts >> 16));
        h[71] = bytes1(uint8(ts >> 24));
    }

    function _deliver(uint256 height, bytes memory header) internal {
        vm.prank(address(endpoint));
        oracle.lzReceive(
            Origin(SRC_EID, SRC_SENDER, 1), bytes32(0), abi.encode(height, header), address(0), ""
        );
    }

    // ---------------------------------------------------------------- acceptance (E1/E2)

    function test_accepts_next_height_nominal() public {
        uint32 ts = uint32(GENESIS_TS + 1319 days); // realized-fast historical interval
        vm.warp(uint256(ts) + 1 hours);
        _deliver(GENESIS_HEIGHT + 210_000, _header(ts));
        (uint256 h, uint256 t, uint256 e) = oracle.latest();
        assertEq(h, GENESIS_HEIGHT + 210_000);
        assertEq(t, ts);
        assertEq(e, 1);
    }

    /// E1 regression (TEST_PLAN §3.11): a FAST cycle — interval far under nominal — is
    /// accepted; there is no wall-clock window at all (ts = previous + 1 works).
    function test_accepts_ultraFast_cycle_noWallClockWindow() public {
        uint32 ts = uint32(GENESIS_TS + 1);
        _deliver(GENESIS_HEIGHT + 210_000, _header(ts));
        (, uint256 t, uint256 e) = oracle.latest();
        assertEq(t, ts);
        assertEq(e, 1);
    }

    function test_accepts_chained_epochs() public {
        uint32 ts1 = uint32(GENESIS_TS + 1000 days);
        vm.warp(uint256(ts1) + 1);
        _deliver(GENESIS_HEIGHT + 210_000, _header(ts1));
        uint32 ts2 = ts1 + 1400 days;
        vm.warp(uint256(ts2) + 1);
        _deliver(GENESIS_HEIGHT + 420_000, _header(ts2));
        (uint256 h,, uint256 e) = oracle.latest();
        assertEq(h, GENESIS_HEIGHT + 420_000);
        assertEq(e, 2);
    }

    // ---------------------------------------------------------------- rejections

    function test_rejects_nonMonotonic_timestamp() public {
        vm.expectRevert(HalvingOracle.NonMonotonicTimestamp.selector);
        _deliver(GENESIS_HEIGHT + 210_000, _header(uint32(GENESIS_TS)));
        vm.expectRevert(HalvingOracle.NonMonotonicTimestamp.selector);
        _deliver(GENESIS_HEIGHT + 210_000, _header(uint32(GENESIS_TS - 5)));
    }

    function test_rejects_future_timestamp() public {
        uint32 ts = uint32(block.timestamp + 1);
        vm.expectRevert(HalvingOracle.FutureTimestamp.selector);
        _deliver(GENESIS_HEIGHT + 210_000, _header(ts));
    }

    function test_rejects_wrong_heights() public {
        bytes memory h = _header(uint32(GENESIS_TS + 1000));
        vm.expectRevert(HalvingOracle.BadHeight.selector);
        _deliver(GENESIS_HEIGHT + 1, h);
        vm.expectRevert(HalvingOracle.NotNextHeight.selector);
        _deliver(GENESIS_HEIGHT + 420_000, h); // skipping a halving is impossible
        vm.expectRevert(HalvingOracle.BadHeight.selector);
        _deliver(0, h);
    }

    /// E3 regression (TEST_PLAN §3.12): spoofed/mismatched paths rejected.
    function test_rejects_untrusted_paths() public {
        bytes memory msgData =
            abi.encode(GENESIS_HEIGHT + 210_000, _header(uint32(GENESIS_TS + 1000)));
        // Wrong caller.
        vm.expectRevert(HalvingOracle.OnlyEndpoint.selector);
        oracle.lzReceive(Origin(SRC_EID, SRC_SENDER, 1), 0, msgData, address(0), "");
        // Wrong EID.
        vm.prank(address(endpoint));
        vm.expectRevert(HalvingOracle.UntrustedPath.selector);
        oracle.lzReceive(Origin(SRC_EID + 1, SRC_SENDER, 1), 0, msgData, address(0), "");
        // Wrong sender.
        vm.prank(address(endpoint));
        vm.expectRevert(HalvingOracle.UntrustedPath.selector);
        oracle.lzReceive(Origin(SRC_EID, bytes32(uint256(1)), 1), 0, msgData, address(0), "");
    }

    /// E3: idempotent re-delivery no-ops; a conflicting fact reverts.
    function test_idempotent_and_conflicting_redelivery() public {
        uint32 ts = uint32(GENESIS_TS + 1000 days);
        vm.warp(uint256(ts) + 1);
        bytes memory header = _header(ts);
        _deliver(GENESIS_HEIGHT + 210_000, header);
        (,, uint256 e) = oracle.latest();

        // Exact re-delivery: no-op, epoch unchanged.
        _deliver(GENESIS_HEIGHT + 210_000, header);
        (,, uint256 e2) = oracle.latest();
        assertEq(e2, e);

        // Conflicting header for the same height: revert.
        bytes memory conflicting = _header(ts + 1);
        vm.expectRevert(HalvingOracle.ConflictingFact.selector);
        _deliver(GENESIS_HEIGHT + 210_000, conflicting);

        // The genesis anchor carries no header: any delivery for it conflicts.
        vm.expectRevert(HalvingOracle.ConflictingFact.selector);
        _deliver(GENESIS_HEIGHT, header);
    }

    function test_rejects_malformed_header() public {
        vm.prank(address(endpoint));
        vm.expectRevert(BtcHeader.BadHeaderLength.selector);
        oracle.lzReceive(
            Origin(SRC_EID, SRC_SENDER, 1),
            0,
            abi.encode(GENESIS_HEIGHT + 210_000, new bytes(79)),
            address(0),
            ""
        );
    }

    // ---------------------------------------------------------------- genesis edges (E4)

    function test_genesis_constructor_validation() public {
        vm.expectRevert(HalvingOracle.BadGenesis.selector);
        new HalvingOracle(address(endpoint), SRC_EID, SRC_SENDER, 0, GENESIS_TS, configurator);
        vm.expectRevert(HalvingOracle.BadGenesis.selector);
        new HalvingOracle(address(endpoint), SRC_EID, SRC_SENDER, 840_001, GENESIS_TS, configurator);
        vm.expectRevert(HalvingOracle.BadGenesis.selector);
        new HalvingOracle(address(endpoint), SRC_EID, SRC_SENDER, 840_000, 0, configurator);
        vm.expectRevert(HalvingOracle.BadGenesis.selector);
        new HalvingOracle(
            address(endpoint), SRC_EID, SRC_SENDER, 840_000, block.timestamp + 1, configurator
        );
    }

    function test_timeSince_no_underflow_at_boundary() public {
        uint32 ts = uint32(block.timestamp); // accepted exactly "now"
        _deliver(GENESIS_HEIGHT + 210_000, _header(ts));
        assertEq(oracle.timeSinceHalving(), 0);
    }

    // ---------------------------------------------------------------- delegate (E3)

    function test_delegate_renounce_oneShot() public {
        assertEq(endpoint.delegates(address(oracle)), configurator);
        vm.expectRevert(HalvingOracle.OnlyDelegate.selector);
        oracle.renounceDelegate();

        vm.prank(configurator);
        oracle.renounceDelegate();
        assertTrue(oracle.delegateRenounced());
        assertEq(endpoint.delegates(address(oracle)), address(0));

        vm.prank(configurator);
        vm.expectRevert(HalvingOracle.OnlyDelegate.selector);
        oracle.renounceDelegate();
    }

    // ---------------------------------------------------------------- prover (source side)

    function test_prover_publishes_bound_fact() public {
        MockLightClient lc = new MockLightClient();
        MockLzEndpoint srcEp = new MockLzEndpoint();
        HalvingProver prover = new HalvingProver(
            address(srcEp),
            address(lc),
            40_362,
            bytes32(uint256(uint160(address(oracle)))),
            configurator
        );
        bytes memory header = _header(uint32(GENESIS_TS + 1000));
        bytes32 h = lib.hash(header);

        // Mismatch (light client has nothing) → revert.
        vm.expectRevert(HalvingProver.HashMismatch.selector);
        prover.publish(GENESIS_HEIGHT + 210_000, header, "");

        lc.set(GENESIS_HEIGHT + 210_000, h);
        prover.publish{value: 0.001 ether}(GENESIS_HEIGHT + 210_000, header, "");
        assertEq(srcEp.sendCount(), 1);
        (uint256 sentHeight, bytes memory sentHeader) =
            abi.decode(srcEp.lastMessage(), (uint256, bytes));
        assertEq(sentHeight, GENESIS_HEIGHT + 210_000);
        assertEq(keccak256(sentHeader), keccak256(header));

        vm.expectRevert(HalvingProver.BadHeight.selector);
        prover.publish(GENESIS_HEIGHT + 1, header, "");
    }
}
