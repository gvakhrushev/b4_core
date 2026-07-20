// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BtcHeader} from "../libraries/BtcHeader.sol";
import {ILayerZeroEndpointV2, ILayerZeroReceiver, Origin} from "../interfaces/ILayerZero.sol";

/// @title HalvingOracle — immutable-path receiver of the proven Bitcoin halving fact.
/// @notice SPECIFICATION §4 / HAZARDS E1–E4. The fact is bound cryptographically
///         (light-client hash ⇔ 80-byte header on the source side; here the header is
///         re-hashed and the timestamp re-derived from header bytes). Acceptance of the
///         next height requires exactly `current + 210000`, a strictly monotonic and
///         not-in-future timestamp — and deliberately NO wall-clock interval window
///         (E1: a predicted-time window can permanently halt an un-upgradeable calendar).
///         Delivery is idempotent by height; a conflicting fact reverts. User funds never
///         pass through this contract.
contract HalvingOracle is ILayerZeroReceiver {
    ILayerZeroEndpointV2 public immutable endpoint;
    uint32 public immutable srcEid;
    bytes32 public immutable srcSender;

    uint256 public halvingHeight;
    uint256 public halvingTs;
    /// Number of accepted facts since the deploy-time genesis anchor.
    uint256 public epoch;
    /// height ⇒ accepted header hash (0 for the genesis anchor, which carries no header).
    mapping(uint256 => bytes32) public factHash;

    /// One temporary LayerZero configurator; MUST be permanently removed before
    /// production (SECURITY_MODEL — administrative boundary).
    address public delegate;
    bool public delegateRenounced;

    event HalvingAccepted(
        uint256 indexed epoch, uint256 indexed height, uint256 timestamp, bytes32 headerHash
    );
    event DelegateRenounced();

    error OnlyEndpoint();
    error UntrustedPath();
    error BadHeight();
    error NotNextHeight();
    error NonMonotonicTimestamp();
    error FutureTimestamp();
    error ConflictingFact();
    error BadGenesis();
    error OnlyDelegate();
    error AlreadyRenounced();

    constructor(
        address endpoint_,
        uint32 srcEid_,
        bytes32 srcSender_,
        uint256 genesisHeight,
        uint256 genesisTs,
        address delegate_
    ) {
        if (
            genesisHeight == 0 || genesisHeight % BtcHeader.HALVING_PERIOD != 0 || genesisTs == 0
                || genesisTs > block.timestamp
        ) revert BadGenesis();
        endpoint = ILayerZeroEndpointV2(endpoint_);
        srcEid = srcEid_;
        srcSender = srcSender_;
        halvingHeight = genesisHeight;
        halvingTs = genesisTs;
        delegate = delegate_;
        ILayerZeroEndpointV2(endpoint_).setDelegate(delegate_);
        emit HalvingAccepted(0, genesisHeight, genesisTs, bytes32(0));
    }

    /// @inheritdoc ILayerZeroReceiver
    function lzReceive(
        Origin calldata origin,
        bytes32,
        bytes calldata message,
        address,
        bytes calldata
    ) external payable {
        if (msg.sender != address(endpoint)) revert OnlyEndpoint();
        if (origin.srcEid != srcEid || origin.sender != srcSender) revert UntrustedPath();

        (uint256 height, bytes memory headerMem) = abi.decode(message, (uint256, bytes));
        _accept(height, headerMem);
    }

    function _accept(uint256 height, bytes memory headerMem) internal {
        // Re-derive the binding from the raw header bytes (E3).
        bytes32 headerHash = BtcHeader.hash(headerMem);
        uint256 ts = BtcHeader.timestamp(headerMem);

        if (height == 0 || height % BtcHeader.HALVING_PERIOD != 0) revert BadHeight();

        if (height <= halvingHeight) {
            // Idempotent by height: an exact re-delivery is a no-op; a conflict reverts.
            if (factHash[height] != headerHash) revert ConflictingFact();
            return;
        }
        if (height != halvingHeight + BtcHeader.HALVING_PERIOD) revert NotNextHeight();
        if (ts <= halvingTs) revert NonMonotonicTimestamp();
        if (ts > block.timestamp) revert FutureTimestamp();
        // E1: no wall-clock interval window — the height is the fact, not the calendar.

        halvingHeight = height;
        halvingTs = ts;
        unchecked {
            ++epoch;
        }
        factHash[height] = headerHash;
        emit HalvingAccepted(epoch, height, ts, headerHash);
    }

    /// @notice Time since the latest accepted fact. Never underflows: acceptance requires
    ///         ts ≤ block.timestamp and time only moves forward (E4).
    function timeSinceHalving() external view returns (uint256) {
        return block.timestamp - halvingTs;
    }

    function latest() external view returns (uint256 height, uint256 ts, uint256 epoch_) {
        return (halvingHeight, halvingTs, epoch);
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

    /// @inheritdoc ILayerZeroReceiver
    function allowInitializePath(Origin calldata origin) external view returns (bool) {
        return origin.srcEid == srcEid && origin.sender == srcSender;
    }

    /// @inheritdoc ILayerZeroReceiver
    function nextNonce(uint32, bytes32) external pure returns (uint64) {
        return 0; // unordered delivery
    }
}
