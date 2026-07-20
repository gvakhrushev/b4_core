// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VenueTestBase} from "../utils/VenueTestBase.sol";
import {CoreReader} from "src/venue/CoreReader.sol";
import {CoreWriterLib} from "src/venue/CoreWriterLib.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";

/// @notice A "user" of the venue: routes CoreReader/CoreWriterLib calls so msg.sender at
///         the CoreWriter shim is this contract, like a vault.
contract VenueUser {
    function readSpot(uint64 token) external view returns (uint64) {
        return CoreReader.spotBalance(address(this), token);
    }

    function readWd() external view returns (uint64) {
        return CoreReader.withdrawable(address(this));
    }

    function readPosition(uint32 perp) external view returns (CoreTypes.Position memory) {
        return CoreReader.position(address(this), perp);
    }

    function toPerp(uint64 ntl) external {
        CoreWriterLib.usdClassTransfer(ntl, true);
    }

    function toSpot(uint64 ntl) external {
        CoreWriterLib.usdClassTransfer(ntl, false);
    }

    function send(address dest, uint64 token, uint64 weiAmount) external {
        CoreWriterLib.spotSend(dest, token, weiAmount);
    }

    function order(uint32 asset, bool isBuy, uint64 limitPx, uint64 sz, bool reduceOnly) external {
        CoreWriterLib.iocOrder(asset, isBuy, limitPx, sz, reduceOnly);
    }
}

contract VenueLayerTest is VenueTestBase {
    VenueUser user;

    function setUp() public {
        setUpVenue();
        user = new VenueUser();
        hub.setUserExists(address(user), true);
    }

    function test_read_write_roundtrip_spot_perp() public {
        hub.coreTopUp(address(user), USDC_CORE, 1_000e8); // $1000 core-spot USDC
        assertEq(user.readSpot(USDC_CORE), 1_000e8);

        user.toPerp(400e6); // $400 to perp
        assertEq(user.readSpot(USDC_CORE), 600e8);
        assertEq(user.readWd(), 400e6);

        user.toSpot(150e6);
        assertEq(user.readSpot(USDC_CORE), 750e8);
        assertEq(user.readWd(), 250e6);
    }

    function test_insufficient_transfer_isSilentNoop() public {
        hub.coreTopUp(address(user), USDC_CORE, 10e8);
        user.toPerp(100e6); // more than available: venue-rejected, no effect
        assertEq(user.readSpot(USDC_CORE), 10e8);
        assertEq(user.readWd(), 0);
    }

    function test_delayed_and_dropped_actions() public {
        hub.setAuto(false, true, true);
        hub.coreTopUp(address(user), USDC_CORE, 1_000e8);

        user.toPerp(400e6);
        assertEq(user.readSpot(USDC_CORE), 1_000e8); // not yet executed
        hub.executeActions();
        assertEq(user.readSpot(USDC_CORE), 600e8);

        hub.setDropNext(1);
        user.toPerp(100e6);
        hub.executeActions();
        assertEq(user.readWd(), 400e6); // dropped: no effect ever
    }

    function test_spotSend_coreToEvm_debitThenDeliver() public {
        hub.setAuto(true, true, false); // hold deliveries
        hub.coreTopUp(address(user), UBTC_CORE, 5e8);
        user.send(CoreTypes.systemAddress(UBTC_CORE), UBTC_CORE, 2e8);
        // Debited on Core, not yet delivered on EVM (A7 window).
        assertEq(user.readSpot(UBTC_CORE), 3e8);
        assertEq(ubtc.balanceOf(address(user)), 0);
        assertEq(hub.pendingDeliveries(), 1);
        hub.deliverEvm();
        assertEq(ubtc.balanceOf(address(user)), 2e8);
    }

    function test_evmToCore_credit_and_activationFee() public {
        hub.setAuto(true, false, true); // hold credits
        hub.setUserExists(address(user), false); // fresh Core account
        hub.setActivationFee(USDC_CORE, 1e8); // $1 activation fee
        usdc.mint(address(user), 500e6);
        vm.prank(address(user));
        usdc.transfer(CoreTypes.systemAddress(USDC_CORE), 500e6);

        assertEq(user.readSpot(USDC_CORE), 0); // in flight
        assertEq(hub.pendingCredits(), 1);
        hub.applyCredits();
        // Fresh account: fee deducted from the first credit (A9).
        assertEq(user.readSpot(USDC_CORE), 500e8 - 1e8);
        assertTrue(hub.userExists(address(user)));
    }

    // CoreWriter order fields are fixed-1e8 (human × 10⁸): $100k ⇒ 100_000e8; 0.5 BTC ⇒
    // 5e7. The mock converts to read/lot units internally, like the live venue.
    function test_spot_ioc_fill_partial_and_priceCheck() public {
        hub.coreTopUp(address(user), UBTC_CORE, 1e8); // 1 BTC = 1e4 lots

        // Sell 0.5 BTC at limit ≤ px: full fill at $100k → +50,000 USDC.
        user.order(CoreTypes.SPOT_ASSET_OFFSET + SPOT_MKT, false, 100_000e8, 5e7, false);
        assertEq(user.readSpot(UBTC_CORE), 5e7);
        assertEq(user.readSpot(USDC_CORE), 50_000e8);

        // Partial fill 40%.
        hub.setFillRatio(CoreTypes.SPOT_ASSET_OFFSET + SPOT_MKT, 4000);
        user.order(CoreTypes.SPOT_ASSET_OFFSET + SPOT_MKT, false, 100_000e8, 5e7, false);
        assertEq(user.readSpot(UBTC_CORE), 5e7 - 2000 * 1e4);

        // Limit above book on a sell: no fill.
        hub.setFillRatio(CoreTypes.SPOT_ASSET_OFFSET + SPOT_MKT, 10_000);
        uint64 before = user.readSpot(UBTC_CORE);
        user.order(CoreTypes.SPOT_ASSET_OFFSET + SPOT_MKT, false, 100_000e8 + 1e4, 1e7, false);
        assertEq(user.readSpot(UBTC_CORE), before);
    }

    function test_perp_order_open_reduce_pnl() public {
        // Open short 1 BTC (sz8 = 1e8) at $100k (px8 = 100_000e8).
        user.order(PERP_MKT, false, 100_000e8, 1e8, false);
        CoreTypes.Position memory p = user.readPosition(PERP_MKT);
        assertEq(p.szi, -1e4);
        assertEq(p.entryNtl, 100_000e6);

        // reduce-only in the same direction: no-op (never crosses zero).
        user.order(PERP_MKT, false, 100_000e8, 1e8, true);
        p = user.readPosition(PERP_MKT);
        assertEq(p.szi, -1e4);

        // Price falls to $90k; close half: +$5k realized to withdrawable.
        hub.setMarkPx(PERP_MKT, 90_000e2);
        user.order(PERP_MKT, true, 90_000e8, 5e7, true);
        p = user.readPosition(PERP_MKT);
        assertEq(p.szi, -5000);
        assertEq(p.entryNtl, 50_000e6);
        assertEq(user.readWd(), 5_000e6);

        // reduce-only clamps to remaining size and reaches raw zero.
        user.order(PERP_MKT, true, 90_000e8, 9e7, true);
        p = user.readPosition(PERP_MKT);
        assertEq(p.szi, 0);
        assertEq(p.entryNtl, 0);
        assertEq(user.readWd(), 10_000e6);
    }

    function test_adversarial_knobs() public {
        hub.coreTopUp(address(user), USDC_CORE, 7e8);
        assertEq(user.readSpot(USDC_CORE), 7e8);
        hub.setWithdrawable(address(user), 123e6);
        assertEq(user.readWd(), 123e6);
        hub.setPosition(address(user), PERP_MKT, -777, 5e6);
        assertEq(user.readPosition(PERP_MKT).szi, -777);
    }
}
