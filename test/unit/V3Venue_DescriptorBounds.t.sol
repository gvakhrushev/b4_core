// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {MockERC20} from "../mocks/MockCore.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {B4Pool} from "src/core/B4Pool.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";
import {DescriptorLib} from "src/venue/DescriptorLib.sol";

/// @notice V3-VENUE-2 (was a candidate): DescriptorLib validated CONSISTENCY against the
///         venue but not RANGE SANITY of the decimal fields. Two gaps existed:
///         (a) no `spotSzDecimals <= coreWeiDecimals` check — `_dirWeiPerLot()` computes
///             `10 ** (coreWeiDecimals - spotSzDecimals)` (B4VaultEngine.sol) which panics on
///             underflow for such a token, permanently reverting every strategy crank once
///             principal sits on Core spot;
///         (b) no bound on |evmDecimals - coreWeiDecimals| — `10 ** |diff|` overflows for a
///             large spread (evmExtraWeiDecimals is int8 on the wire, so up to 127 passes),
///             bricking deposits/conversions.
///         Both require venue-impossible token configurations (a spot lot must be >= 1 wei on
///         HyperCore, so szDecimals <= weiDecimals holds there, and real wei/EVM spreads are
///         small). FIX: `_verifyToken` now rejects `spotSzDecimals > coreWeiDecimals` and a
///         wei/EVM spread `> 30` at BINDING — the binding layer's job (SPEC §2) is to reject
///         unworkable descriptors BEFORE funds. These are PASS-AFTER regressions.
contract V3VenueDescriptorBoundsTest is VaultTestBase {
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
        hub.setSpotPx(ODD_SPOT, uint64(10 ** (8 - szDec))); // $1 in (8 - szDec) px decimals
        hub.setMarkPx(ODD_PERP, 100); // $1 in (6 - 4) px decimals
        hub.setOraclePx(ODD_PERP, 100);
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

    /// (a) PASS-AFTER: spotSzDecimals (8) > coreWeiDecimals (4) is now rejected at BINDING —
    /// the pool is never created, so no funds can ever reach the bricked sizing path.
    function test_V3VENUE2_spotSzDecimals_above_weiDecimals_rejected_at_binding() public {
        _registerOdd({weiDec: 4, szDec: 8, evmDec: 8});
        CoreTypes.AssetDescriptor memory d = _oddDescriptor(4, 8, 8);
        vm.expectRevert(DescriptorLib.DecimalsMismatch.selector);
        factory.createPool(_dirs(d));
    }

    /// (b) PASS-AFTER: a wei/EVM spread of 82 (fits int8 evmExtraWeiDecimals) is now rejected
    /// at BINDING — the unworkable descriptor never reaches deposit/conversion.
    function test_V3VENUE2_extreme_decimal_spread_rejected_at_binding() public {
        _registerOdd({weiDec: 8, szDec: 4, evmDec: 90});
        CoreTypes.AssetDescriptor memory d = _oddDescriptor(8, 4, 90);
        vm.expectRevert(DescriptorLib.DecimalsMismatch.selector);
        factory.createPool(_dirs(d));
    }

    /// Boundary: spotSzDecimals == coreWeiDecimals (the tightest LIVE lot) still binds and the
    /// full strategy + exit path works — the guard rejects only the impossible strict-greater
    /// case, never a real venue configuration.
    function test_V3VENUE2_szDecimals_equal_weiDecimals_binds_and_works() public {
        _registerOdd({weiDec: 6, szDec: 6, evmDec: 8});
        CoreTypes.AssetDescriptor memory d = _oddDescriptor(6, 6, 8);

        B4Pool oddPool = B4Pool(factory.createPool(_dirs(d))); // binds
        vm.prank(user);
        B4Vault v = B4Vault(
            factory.createVault(
                address(oddPool),
                CoreTypes.descriptorHash(d),
                address(b4), // growth=1, fall=0
                1e18,
                100,
                defaultRoute()
            )
        );

        odd.mint(user, 1000e8);
        vm.startPrank(user);
        odd.approve(address(v), 1000e8);
        v.deposit(1000e8, 0);
        vm.stopPrank();

        warpTo(Calendar.P);
        assertTrue(v.crank(), "fund intent created");
        assertTrue(v.crank(), "fund verified onto Core spot");
        assertGt(v.coreDirWei(), 0, "principal on Core spot");
        // Strategy cranks proceed to completion WITHOUT the wei-per-lot underflow that a
        // szDecimals > weiDecimals descriptor would have caused — the sell sizing math is
        // exercised here (10 ** (6 - 6) = 1, no panic).
        crankUntilIdle(v, 12);

        vm.prank(user);
        v.initiateExit(1e18);
        crankUntilIdle(v, 12);
        assertEq(v.exitShareWad(), 0, "exit finalized (no freeze)");
        // Owner recovered value — in whichever token the strategy left it (ODD if held,
        // USDC if the fall-zone sale rotated it). No funds frozen.
        assertGt(odd.balanceOf(user) + usdc.balanceOf(user), 0, "owner recovered value");
        assertLe(v.coreDirWei(), 1, "Core spot drained (<=1 wei floor dust)");
    }
}
