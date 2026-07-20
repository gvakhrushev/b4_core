// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title BtcHeader — 80-byte Bitcoin header binding (HAZARDS E3).
/// @notice The halving fact is bound cryptographically: the light-client block hash must
///         equal dSHA256(header) and the fact timestamp is derived from the header bytes,
///         never taken from the message envelope.
/// @dev Hash is produced in Bitcoin-internal byte order (the raw dSHA256 output, i.e. the
///      byte-reversed form of the conventional display hex). The Citrea light client's
///      stored convention must be confirmed at integration — funded gate (REPORT.md).
library BtcHeader {
    uint256 internal constant HEADER_LENGTH = 80;
    /// Bitcoin halving period in blocks.
    uint256 internal constant HALVING_PERIOD = 210_000;

    error BadHeaderLength();

    /// @notice dSHA256 of the raw 80-byte header.
    function hash(bytes memory header) internal pure returns (bytes32) {
        if (header.length != HEADER_LENGTH) revert BadHeaderLength();
        return sha256(abi.encodePacked(sha256(header)));
    }

    /// @notice Header timestamp: little-endian uint32 at offset 68.
    function timestamp(bytes memory header) internal pure returns (uint256 ts) {
        if (header.length != HEADER_LENGTH) revert BadHeaderLength();
        ts = uint256(uint8(header[68])) | (uint256(uint8(header[69])) << 8)
            | (uint256(uint8(header[70])) << 16) | (uint256(uint8(header[71])) << 24);
    }
}
