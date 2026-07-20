// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BtcHeader} from "../libraries/BtcHeader.sol";
import {ILayerZeroEndpointV2, MessagingParams, MessagingFee} from "../interfaces/ILayerZero.sol";

/// @notice Citrea's finalized Bitcoin light client, abstracted with the getter named per
///         Citrea's public interface (`getBlockHash(uint256)`). The concrete contract
///         identity, exact selector and hash byte-order convention remain
///         integration/funded gates (SECURITY_MODEL §5.12): a selector mismatch would
///         revert EVERY publication and stall the global calendar. If the live selector
///         differs, deploy a thin permissionless read adapter and point `lightClient`
///         at it — the adapter adds no trust (pure view forwarding).
interface IBitcoinLightClient {
    function getBlockHash(uint256 height) external view returns (bytes32);
}

/// @title HalvingProver — source-side publisher of the proven halving fact.
/// @notice Permissionless: anyone may publish (REQUIREMENTS §1 "fact submitter"). The
///         message carries only (height, 80-byte header); the receiver re-derives hash
///         and timestamp, so this contract adds no trusted data beyond the light client
///         binding it enforces. User funds never pass through (only the LZ gas fee).
contract HalvingProver {
    ILayerZeroEndpointV2 public immutable endpoint;
    IBitcoinLightClient public immutable lightClient;
    uint32 public immutable dstEid;
    bytes32 public immutable receiver;

    /// One temporary LayerZero configurator; removed one-shot before production (E3).
    address public delegate;
    bool public delegateRenounced;

    event FactPublished(uint256 indexed height, bytes32 headerHash);
    event DelegateRenounced();

    error BadHeight();
    error HashMismatch();
    error OnlyDelegate();
    error AlreadyRenounced();

    constructor(
        address endpoint_,
        address lightClient_,
        uint32 dstEid_,
        bytes32 receiver_,
        address delegate_
    ) {
        endpoint = ILayerZeroEndpointV2(endpoint_);
        lightClient = IBitcoinLightClient(lightClient_);
        dstEid = dstEid_;
        receiver = receiver_;
        delegate = delegate_;
        ILayerZeroEndpointV2(endpoint_).setDelegate(delegate_);
    }

    /// @notice Prove `header` is the canonical block at halving `height` and publish it.
    function publish(uint256 height, bytes calldata header, bytes calldata options)
        external
        payable
    {
        if (height == 0 || height % BtcHeader.HALVING_PERIOD != 0) revert BadHeight();
        bytes32 headerHash = BtcHeader.hash(header);
        if (lightClient.getBlockHash(height) != headerHash) revert HashMismatch();

        endpoint.send{value: msg.value}(
            MessagingParams({
                dstEid: dstEid,
                receiver: receiver,
                message: abi.encode(height, header),
                options: options,
                payInLzToken: false
            }),
            msg.sender
        );
        emit FactPublished(height, headerHash);
    }

    function quote(uint256 height, bytes calldata header, bytes calldata options)
        external
        view
        returns (MessagingFee memory)
    {
        return endpoint.quote(
            MessagingParams({
                dstEid: dstEid,
                receiver: receiver,
                message: abi.encode(height, header),
                options: options,
                payInLzToken: false
            }),
            address(this)
        );
    }

    /// @notice Permanently remove the LayerZero configurator (one-shot; E3).
    function renounceDelegate() external {
        if (msg.sender != delegate) revert OnlyDelegate();
        if (delegateRenounced) revert AlreadyRenounced();
        delegateRenounced = true;
        delegate = address(0);
        endpoint.setDelegate(address(0));
        emit DelegateRenounced();
    }
}
