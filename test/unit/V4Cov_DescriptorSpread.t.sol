// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {MockERC20} from "../mocks/MockCore.sol";
import {B4Pool} from "src/core/B4Pool.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";
import {DescriptorLib} from "src/venue/DescriptorLib.sol";

/// @notice V4-COV-1 (test-gap closure for V3-VENUE-2): the remediation's regression
///         tests cover szDecimals > weiDecimals and an 82-spread, but never the exact
///         boundary of the new `spread > 30` rule (DescriptorLib.sol:76-79). This pins
///         it: spread == 30 binds, spread == 31 reverts DecimalsMismatch.
contract V4CovDescriptorSpreadTest is VaultTestBase {
    uint64 constant ODD_CORE = 2;
    uint32 constant ODD_SPOT = 6;
    uint32 constant ODD_PERP = 4;

    MockERC20 odd;

    function setUp() public {
        setUpProtocol();
    }

    function _registerOdd(uint8 weiDec, uint8 szDec, uint8 evmDec) internal {
        odd = new MockERC20("ODD", evmDec);
        hub.registerToken(ODD_CORE, address(odd), weiDec, szDec, evmDec, "ODD");
        hub.registerSpotMarket(ODD_SPOT, ODD_CORE, USDC_CORE);
        hub.registerPerpMarket(ODD_PERP, 4, 40, false);
    }

    function _oddDescriptor(uint8 weiDec, uint8 szDec, uint8 evmDec)
        internal
        view
        returns (CoreTypes.AssetDescriptor memory)
    {
        return CoreTypes.AssetDescriptor({
            evmToken: address(odd),
            evmDecimals: evmDec,
            coreToken: ODD_CORE,
            spotMarket: ODD_SPOT,
            perpMarket: ODD_PERP,
            coreWeiDecimals: weiDec,
            spotSzDecimals: szDec,
            perpSzDecimals: 4,
            perpMaxLeverage: 40,
            fixedUsd: false
        });
    }

    function _dirs(CoreTypes.AssetDescriptor memory d)
        internal
        pure
        returns (CoreTypes.AssetDescriptor[] memory dirs)
    {
        dirs = new CoreTypes.AssetDescriptor[](1);
        dirs[0] = d;
    }

    /// Boundary low: |38 − 8| = 30 ≤ 30 → binds (a 38-decimal EVM token is absurd but
    /// the guard's contract is "rejects only spread > 30").
    function test_V4COV_spread_exactly_30_binds() public {
        _registerOdd({weiDec: 8, szDec: 4, evmDec: 38});
        B4Pool p = B4Pool(factory.createPool(_dirs(_oddDescriptor(8, 4, 38))));
        assertTrue(address(p) != address(0), "spread 30 must bind");
    }

    /// Boundary high: |39 − 8| = 31 > 30 → rejected at binding.
    function test_V4COV_spread_31_reverts() public {
        _registerOdd({weiDec: 8, szDec: 4, evmDec: 39});
        vm.expectRevert(DescriptorLib.DecimalsMismatch.selector);
        factory.createPool(_dirs(_oddDescriptor(8, 4, 39)));
    }

    /// Symmetric direction: core wei decimals ABOVE evm decimals, spread exactly 30.
    function test_V4COV_spread_exactly_30_inverse_binds() public {
        _registerOdd({weiDec: 34, szDec: 4, evmDec: 4});
        B4Pool p = B4Pool(factory.createPool(_dirs(_oddDescriptor(34, 4, 4))));
        assertTrue(address(p) != address(0), "inverse spread 30 must bind");
    }

    function test_V4COV_spread_31_inverse_reverts() public {
        _registerOdd({weiDec: 35, szDec: 4, evmDec: 4});
        vm.expectRevert(DescriptorLib.DecimalsMismatch.selector);
        factory.createPool(_dirs(_oddDescriptor(35, 4, 4)));
    }
}
