// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    ILayerZeroEndpointV2,
    MessagingParams,
    MessagingFee,
    MessagingReceipt
} from "src/interfaces/ILayerZero.sol";

contract MockLzEndpoint is ILayerZeroEndpointV2 {
    mapping(address => address) public delegates;
    MessagingParams public lastParams;
    address public lastRefund;
    uint256 public sendCount;

    function send(MessagingParams calldata params, address refundAddress)
        external
        payable
        returns (MessagingReceipt memory receipt)
    {
        lastParams = params;
        lastRefund = refundAddress;
        ++sendCount;
        receipt.guid = keccak256(abi.encode(params.dstEid, params.receiver, sendCount));
        receipt.nonce = uint64(sendCount);
        receipt.fee = MessagingFee(msg.value, 0);
    }

    function quote(MessagingParams calldata, address)
        external
        pure
        returns (MessagingFee memory fee)
    {
        fee = MessagingFee(0.001 ether, 0);
    }

    function setDelegate(address delegate) external {
        delegates[msg.sender] = delegate;
    }

    function lastMessage() external view returns (bytes memory) {
        return lastParams.message;
    }
}
