// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// Minimal LayerZero V2 surface used by B4. Live endpoint/library/DVN configuration is a
/// funded release gate (SECURITY_MODEL §5.12–13); nothing here custodies user funds.
struct Origin {
    uint32 srcEid;
    bytes32 sender;
    uint64 nonce;
}

struct MessagingParams {
    uint32 dstEid;
    bytes32 receiver;
    bytes message;
    bytes options;
    bool payInLzToken;
}

struct MessagingFee {
    uint256 nativeFee;
    uint256 lzTokenFee;
}

struct MessagingReceipt {
    bytes32 guid;
    uint64 nonce;
    MessagingFee fee;
}

interface ILayerZeroEndpointV2 {
    function send(MessagingParams calldata params, address refundAddress)
        external
        payable
        returns (MessagingReceipt memory);

    function quote(MessagingParams calldata params, address sender)
        external
        view
        returns (MessagingFee memory);

    function setDelegate(address delegate) external;
}

interface ILayerZeroReceiver {
    function lzReceive(
        Origin calldata origin,
        bytes32 guid,
        bytes calldata message,
        address executor,
        bytes calldata extraData
    ) external payable;

    function allowInitializePath(Origin calldata origin) external view returns (bool);

    function nextNonce(uint32 srcEid, bytes32 sender) external view returns (uint64);
}
