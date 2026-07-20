// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";
import {HUB, MockCoreHub, PrecompileShim, CoreWriterShim, MockERC20} from "../mocks/MockCore.sol";

/// @notice Shared venue fixture: etches the mock hub + precompile/CoreWriter shims and
///         configures a standard universe — UBTC (fine-lot directional asset) and USDC
///         (settlement). Decimals chosen to exercise every conversion:
///         UBTC: core wei 8, sz 4 (1 lot = 1e4 wei), evm 8; spot px 4 decimals.
///         USDC: core wei 8, evm 6; perp USD 6 decimals.
abstract contract VenueTestBase is Test {
    MockCoreHub public hub;
    MockERC20 public usdc;
    MockERC20 public ubtc;

    uint64 constant USDC_CORE = 0;
    uint64 constant UBTC_CORE = 1;
    uint32 constant SPOT_MKT = 5;
    uint32 constant PERP_MKT = 3;

    // $100,000 per BTC in each convention.
    uint64 constant SPOT_PX = 100_000 * 1e4; // 8−4 = 4 px decimals
    uint64 constant MARK_PX = 100_000 * 1e2; // 6−4 = 2 px decimals

    function setUpVenue() internal {
        vm.etch(HUB, type(MockCoreHub).runtimeCode);
        hub = MockCoreHub(HUB);

        bytes memory shim = type(PrecompileShim).runtimeCode;
        vm.etch(CoreTypes.PRECOMPILE_POSITION, shim);
        vm.etch(CoreTypes.PRECOMPILE_SPOT_BALANCE, shim);
        vm.etch(CoreTypes.PRECOMPILE_WITHDRAWABLE, shim);
        vm.etch(CoreTypes.PRECOMPILE_MARK_PX, shim);
        vm.etch(CoreTypes.PRECOMPILE_ORACLE_PX, shim);
        vm.etch(CoreTypes.PRECOMPILE_SPOT_PX, shim);
        vm.etch(CoreTypes.PRECOMPILE_PERP_ASSET_INFO, shim);
        vm.etch(CoreTypes.PRECOMPILE_SPOT_INFO, shim);
        vm.etch(CoreTypes.PRECOMPILE_TOKEN_INFO, shim);
        vm.etch(CoreTypes.PRECOMPILE_CORE_USER_EXISTS, shim);
        vm.etch(CoreTypes.CORE_WRITER, type(CoreWriterShim).runtimeCode);

        usdc = new MockERC20("USDC", 6);
        ubtc = new MockERC20("UBTC", 8);

        hub.registerToken(USDC_CORE, address(usdc), 8, 0, 6, "USDC");
        hub.registerToken(UBTC_CORE, address(ubtc), 8, 4, 8, "UBTC");
        hub.setUsdcToken(USDC_CORE);
        hub.registerSpotMarket(SPOT_MKT, UBTC_CORE, USDC_CORE);
        hub.registerPerpMarket(PERP_MKT, 4, 40, false);
        hub.setSpotPx(SPOT_MKT, SPOT_PX);
        hub.setMarkPx(PERP_MKT, MARK_PX);
        hub.setOraclePx(PERP_MKT, MARK_PX);
        // Default: fully synchronous behavior; tests override per scenario.
        hub.setAuto(true, true, true);
    }

    function ubtcDescriptor() internal view returns (CoreTypes.AssetDescriptor memory) {
        return CoreTypes.AssetDescriptor({
            evmToken: address(ubtc),
            evmDecimals: 8,
            coreToken: UBTC_CORE,
            spotMarket: SPOT_MKT,
            perpMarket: PERP_MKT,
            coreWeiDecimals: 8,
            spotSzDecimals: 4,
            perpSzDecimals: 4,
            perpMaxLeverage: 40,
            fixedUsd: false
        });
    }

    function usdcDescriptor() internal view returns (CoreTypes.AssetDescriptor memory) {
        return CoreTypes.AssetDescriptor({
            evmToken: address(usdc),
            evmDecimals: 6,
            coreToken: USDC_CORE,
            spotMarket: CoreTypes.NO_MARKET,
            perpMarket: CoreTypes.NO_MARKET,
            coreWeiDecimals: 8,
            spotSzDecimals: 0,
            perpSzDecimals: 0,
            perpMaxLeverage: 0,
            fixedUsd: true
        });
    }
}
