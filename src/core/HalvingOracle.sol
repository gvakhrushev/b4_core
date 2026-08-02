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
    uint256 public immutable bootstrapHeight;

    uint256 public halvingHeight;
    uint256 public halvingTs;
    /// Number of accepted facts after bootstrap (the bootstrap fact itself is epoch 0).
    uint256 public epoch;
    /// height ⇒ accepted header hash, including the proven bootstrap fact.
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
    error NoHalvingFact();
    error OnlyDelegate();
    error AlreadyRenounced();

    constructor(
        address endpoint_,
        uint32 srcEid_,
        bytes32 srcSender_,
        uint256 bootstrapHeight_,
        address delegate_
    ) {
        if (bootstrapHeight_ == 0 || bootstrapHeight_ % BtcHeader.HALVING_PERIOD != 0) revert BadHeight();
        endpoint = ILayerZeroEndpointV2(endpoint_);
        srcEid = srcEid_;
        srcSender = srcSender_;
        bootstrapHeight = bootstrapHeight_;
        delegate = delegate_;
        ILayerZeroEndpointV2(endpoint_).setDelegate(delegate_);
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
        if (ts == 0) revert NonMonotonicTimestamp();
        if (ts > block.timestamp) revert FutureTimestamp();

        if (halvingHeight == 0) {
            // Bootstrap is not a special trusted constructor path: the first fact is
            // proven and delivered through exactly the same immutable LayerZero route
            // as every later halving. It establishes epoch 0.
            if (height != bootstrapHeight) revert NotNextHeight();
            halvingHeight = height;
            halvingTs = ts;
            factHash[height] = headerHash;
            emit HalvingAccepted(0, height, ts, headerHash);
            return;
        }
        if (height <= halvingHeight) {
            // Idempotent by height: an exact re-delivery is a no-op; a conflict reverts.
            if (factHash[height] != headerHash) revert ConflictingFact();
            return;
        }
        if (height != halvingHeight + BtcHeader.HALVING_PERIOD) revert NotNextHeight();
        if (ts <= halvingTs) revert NonMonotonicTimestamp();
        // E1: no wall-clock interval window — the height is the fact, not the calendar.

        halvingHeight = height;
        halvingTs = ts;
        unchecked {
            ++epoch;
        }
        factHash[height] = headerHash;
        emit HalvingAccepted(epoch, height, ts, headerHash);
    }

    /// @notice Time since the latest accepted fact. Reverts until the proof-backed bootstrap
    ///         fact arrives; afterward it never underflows because accepted timestamps are
    ///         non-future and strictly monotonic (E4).
    function timeSinceHalving() external view returns (uint256) {
        if (halvingHeight == 0) revert NoHalvingFact();
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
    /// @dev Zero selects UNORDERED delivery, and that is load-bearing rather than a default.
    ///      `HalvingProver.publish` is permissionless and accepts any height the Citrea light
    ///      client can prove — including a REAL PAST halving. Such a fact arrives here, fails
    ///      `factHash[height] != headerHash` (nothing was ever accepted at that height) and
    ///      reverts `ConflictingFact`, which is the correct answer: an unknown old fact must not
    ///      be admitted. Under ORDERED delivery that permanently-reverting message would sit at
    ///      the head of the channel and block every later genuine halving — a permissionless
    ///      liveness attack on the protocol's only external fact, and the calendar with it.
    ///      Unordered delivery is what makes the revert local to that one message.
    ///      Pinned by `test/unit/HalvingOracle.t.sol`.
    function nextNonce(uint32, bytes32) external pure returns (uint64) {
        return 0;
    }
}
