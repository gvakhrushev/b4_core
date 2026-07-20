// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title CoreTypes — HyperCore venue addresses, action ids, and descriptor shapes.
/// @notice Addresses, ABI shapes and encodings follow the public HyperCore documentation.
///         Their LIVE semantics (atomicity, activation, gas, decimals, lot rounding) are
///         funded release gates (SECURITY_MODEL §5) — local mocks implement this same ABI
///         but cannot prove venue behavior.
library CoreTypes {
    // ------------------------------------------------------------------ addresses
    address internal constant CORE_WRITER = 0x3333333333333333333333333333333333333333;
    address internal constant PRECOMPILE_POSITION = 0x0000000000000000000000000000000000000800;
    address internal constant PRECOMPILE_SPOT_BALANCE = 0x0000000000000000000000000000000000000801;
    address internal constant PRECOMPILE_WITHDRAWABLE = 0x0000000000000000000000000000000000000803;
    address internal constant PRECOMPILE_MARK_PX = 0x0000000000000000000000000000000000000806;
    address internal constant PRECOMPILE_ORACLE_PX = 0x0000000000000000000000000000000000000807;
    address internal constant PRECOMPILE_SPOT_PX = 0x0000000000000000000000000000000000000808;
    address internal constant PRECOMPILE_PERP_ASSET_INFO =
        0x000000000000000000000000000000000000080a;
    address internal constant PRECOMPILE_SPOT_INFO = 0x000000000000000000000000000000000000080b;
    address internal constant PRECOMPILE_TOKEN_INFO = 0x000000000000000000000000000000000000080C;
    address internal constant PRECOMPILE_CORE_USER_EXISTS =
        0x0000000000000000000000000000000000000810;

    /// EVM→Core: transfer the linked ERC20 to the token's system address
    /// (0x2000…00 + core token index). Core→EVM: spotSend to the same system address.
    address internal constant SYSTEM_ADDRESS_BASE = 0x2000000000000000000000000000000000000000;

    // ------------------------------------------------------------------ action ids
    uint8 internal constant ACTION_VERSION = 1;
    uint24 internal constant ACTION_LIMIT_ORDER = 1;
    uint24 internal constant ACTION_SPOT_SEND = 6;
    uint24 internal constant ACTION_USD_CLASS_TRANSFER = 7;

    uint8 internal constant TIF_IOC = 3;
    /// Spot order asset id = 10000 + spot pair index.
    uint32 internal constant SPOT_ASSET_OFFSET = 10_000;
    /// Perp USD ("ntl") decimals.
    uint8 internal constant PERP_USD_DECIMALS = 6;

    // ------------------------------------------------------------------ read shapes
    struct Position {
        int64 szi; // signed size, perp szDecimals lots
        uint64 entryNtl; // absolute entry notional, 1e6 USD
        int64 isolatedRawUsd;
        uint32 leverage;
        bool isolated;
    }

    struct SpotBalance {
        uint64 total; // wei decimals of the token
        uint64 hold;
        uint64 entryNtl;
    }

    struct PerpAssetInfo {
        string coin;
        uint32 marginTableId;
        uint8 szDecimals;
        uint8 maxLeverage;
        bool onlyIsolated;
    }

    struct SpotInfo {
        string name;
        uint64[2] tokens; // [base, quote]
    }

    struct TokenInfo {
        string name;
        uint64[] spots;
        uint64 deployerTradingFeeShare;
        address deployer;
        address evmContract;
        uint8 szDecimals;
        uint8 weiDecimals;
        int8 evmExtraWeiDecimals;
    }

    // ------------------------------------------------------------------ descriptor
    /// One immutable asset descriptor (SPECIFICATION §2). A vault owns exactly one
    /// directional descriptor (fixedUsd = false) plus the settlement descriptor
    /// (fixedUsd = true, canonical USDC valued at a fixed 1 USD — decision C3).
    struct AssetDescriptor {
        address evmToken;
        uint8 evmDecimals;
        uint64 coreToken;
        uint32 spotMarket; // token/USDC spot pair index
        uint32 perpMarket; // type(uint32).max when no perp is associated
        uint8 coreWeiDecimals;
        uint8 spotSzDecimals; // base-token lot decimals on the spot pair
        uint8 perpSzDecimals;
        uint8 perpMaxLeverage;
        bool fixedUsd;
    }

    uint32 internal constant NO_MARKET = type(uint32).max;

    function descriptorHash(AssetDescriptor memory d) internal pure returns (bytes32) {
        return keccak256(abi.encode(d));
    }

    function systemAddress(uint64 coreToken) internal pure returns (address) {
        return address(uint160(SYSTEM_ADDRESS_BASE) + uint160(coreToken));
    }
}
