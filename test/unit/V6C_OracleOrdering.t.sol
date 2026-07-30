// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {HalvingOracle} from "src/core/HalvingOracle.sol";
import {Origin} from "src/interfaces/ILayerZero.sol";

/// @notice V6 Scope C — oracle root-of-trust residuals: unordered LayerZero delivery
///         (nextNonce == 0) means fact N+2 can arrive before N+1. Prove the receiver
///         rejects the jump and self-heals on re-delivery, and that height monotonicity
///         is enforced on-chain regardless of message order.
contract V6C_OracleOrderingTest is VaultTestBase {
    function setUp() public {
        setUpProtocol();
    }

    /// H2 before H1: reverts (NotNextHeight), then H1 lands, then H2 lands — nothing is
    /// permanently stuck, no state is corrupted by the out-of-order attempt.
    function test_outOfOrder_delivery_rejected_then_heals() public {
        uint32 ts1 = uint32(GENESIS_TS + 1_400 days);
        uint32 ts2 = uint32(GENESIS_TS + 2_800 days);
        vm.warp(uint256(ts2) + 1 days);

        vm.expectRevert(HalvingOracle.NotNextHeight.selector);
        acceptHalving(GENESIS_HEIGHT + 420_000, ts2);
        (uint256 h, uint256 ts, uint256 e) = oracle.latest();
        assertEq(h, GENESIS_HEIGHT);
        assertEq(ts, GENESIS_TS);
        assertEq(e, 0);

        acceptHalving(GENESIS_HEIGHT + 210_000, ts1);
        acceptHalving(GENESIS_HEIGHT + 420_000, ts2);
        (h, ts, e) = oracle.latest();
        assertEq(h, GENESIS_HEIGHT + 420_000);
        assertEq(ts, ts2);
        assertEq(e, 2);
    }

    /// A "reorged" fact: same height, different header bytes — even from the trusted
    /// path it reverts (ConflictingFact); the accepted fact is immutable.
    function test_conflicting_same_height_rejected() public {
        uint32 ts1 = uint32(GENESIS_TS + 1_400 days);
        vm.warp(uint256(ts1) + 1 days);
        acceptHalving(GENESIS_HEIGHT + 210_000, ts1);

        bytes memory evil = new bytes(80);
        evil[0] = bytes1(uint8(0xFF)); // different header, same height claim
        evil[68] = bytes1(uint8(ts1));
        evil[69] = bytes1(uint8(ts1 >> 8));
        evil[70] = bytes1(uint8(ts1 >> 16));
        evil[71] = bytes1(uint8(ts1 >> 24));
        vm.prank(address(endpoint));
        vm.expectRevert(HalvingOracle.ConflictingFact.selector);
        oracle.lzReceive(
            Origin(SRC_EID, SRC_SENDER, 2),
            bytes32(0),
            abi.encode(GENESIS_HEIGHT + 210_000, evil),
            address(0),
            ""
        );
        (uint256 h, uint256 ts, uint256 e) = oracle.latest();
        assertEq(h, GENESIS_HEIGHT + 210_000);
        assertEq(ts, ts1);
        assertEq(e, 1);
    }
}
