// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BtcHeader} from "src/libraries/BtcHeader.sol";

contract BtcHeaderHarness {
    function hash(bytes calldata h) external pure returns (bytes32) {
        return BtcHeader.hash(h);
    }

    function timestamp(bytes calldata h) external pure returns (uint256) {
        return BtcHeader.timestamp(h);
    }
}

contract BtcHeaderTest is Test {
    BtcHeaderHarness harness = new BtcHeaderHarness();

    // Bitcoin genesis block header (height 0).
    bytes constant GENESIS = hex"0100000000000000000000000000000000000000000000000000000000000000"
        hex"000000003ba3edfd7a7b12b27ac72c3e67768f617fc81bc3888a51323a9fb8aa"
        hex"4b1e5e4a29ab5f49ffff001d1dac2b7c";

    function test_genesis_vector() public view {
        assertEq(GENESIS.length, 80);
        // dSHA256 in internal byte order (reversed display hex of
        // 000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f).
        assertEq(
            harness.hash(GENESIS),
            bytes32(hex"6fe28c0ab6f1b372c1a6a246ae63f74f931e8365e15a089c68d6190000000000")
        );
        assertEq(harness.timestamp(GENESIS), 1231006505);
    }

    function testFuzz_rejects_bad_length(bytes calldata data) public {
        vm.assume(data.length != 80);
        vm.expectRevert(BtcHeader.BadHeaderLength.selector);
        harness.hash(data);
        vm.expectRevert(BtcHeader.BadHeaderLength.selector);
        harness.timestamp(data);
    }

    function testFuzz_timestamp_littleEndian(uint32 ts) public view {
        bytes memory h = new bytes(80);
        h[68] = bytes1(uint8(ts));
        h[69] = bytes1(uint8(ts >> 8));
        h[70] = bytes1(uint8(ts >> 16));
        h[71] = bytes1(uint8(ts >> 24));
        assertEq(harness.timestamp(h), ts);
    }
}
