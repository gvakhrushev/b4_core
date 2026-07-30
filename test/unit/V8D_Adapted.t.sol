// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {B4Pool} from "src/core/B4Pool.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";
import {MockERC20} from "../mocks/MockCore.sol";
import {console2} from "forge-std/console2.sol";

/// @notice V8 Scope D: adapted versions of the skipped scenarios — expectations updated
///         to the post-cdedd60 routing (USDC deposits are strategy capital in the rotated
///         bucket). If the FUNCTIONAL properties still hold, the skips are stale-scenario;
///         if they don't, the skip hides a bug.
contract V8D_AdaptedTest is VaultTestBase {
    function setUp() public {
        setUpProtocol();
    }

    // --------------------------------------------------------- A: post-exit planner (Mini)
    /// After a Mini exit finalizes, the sync planner now deploys the remaining rotated
    /// USDC into spot (decompose(1) → spot 1, strategy includes the USDC deposit). Pin
    /// exactly where the "17,784" went.
    function test_A_post_exit_planner_deploys_rotated_into_spot() public {
        B4Vault v = createVault(address(mini));
        fundAndDeposit(v, 1e8, 20_000e6);
        hub.setSpotPx(SPOT_MKT, 120_000e4);
        warpTo(Calendar.P - Calendar.H);
        pool.advance();
        uint256 id = pool.intervalCount() - 1;
        pool.lockPrices(id);
        v.settle(id);
        hub.setSpotPx(SPOT_MKT, 130_000e4);

        vm.prank(user);
        v.initiateExit(0.1e18);
        for (uint256 i; i < 20 && v.exitShareWad() != 0; i++) {
            v.crank();
        }
        uint256 rotAfterExit = v.usdcRotatedEvm();
        uint256 dirAfterExit = v.dirEvm();
        console2.log("exit done: rot", rotAfterExit, "dir", dirAfterExit);

        crankUntilIdle(v, 20); // the extra cranks the original test performed
        console2.log("idle: rot", v.usdcRotatedEvm(), "coreRot", uint256(v.coreUsdcRotatedWei()));
        console2.log("idle: dir", v.dirEvm(), "coreDir", uint256(v.coreDirWei()));
        // The rotated USDC was converted to dir (minus slippage-free mock fills): value conserved.
        assertLt(v.usdcRotatedEvm(), rotAfterExit, "planner deployed rotated");
        assertGt(
            v.dirEvm() + uint256(v.coreDirWei()), dirAfterExit, "dir grew by the deployed USDC"
        );
    }

    // --------------------------------------------------------- B: adapted Findings:464
    MockERC20 soltoken;

    function _spotOnlyDescriptor() internal returns (CoreTypes.AssetDescriptor memory d) {
        hub.registerToken(7, address(soltoken), 8, 2, 18, "SOL");
        hub.registerSpotMarket(7, 7, USDC_CORE);
        hub.setSpotPx(7, 200e6); // $200
        d = CoreTypes.AssetDescriptor({
            evmToken: address(soltoken),
            evmDecimals: 18,
            coreToken: 7,
            spotMarket: 7,
            perpMarket: CoreTypes.NO_MARKET,
            coreWeiDecimals: 8,
            spotSzDecimals: 2,
            perpSzDecimals: 0,
            perpMaxLeverage: 0,
            fixedUsd: false
        });
    }

    function test_B_spot_only_perp_policy_degrades_and_recovers_ADAPTED() public {
        soltoken = new MockERC20("SOL", 18);
        CoreTypes.AssetDescriptor[] memory dirs = new CoreTypes.AssetDescriptor[](1);
        dirs[0] = _spotOnlyDescriptor();
        B4Pool p2 = B4Pool(factory.createPool(dirs));

        vm.prank(user);
        B4Vault v = B4Vault(
            factory.createVault(
                address(p2),
                CoreTypes.descriptorHash(dirs[0]),
                address(pro),
                1e18,
                100,
                defaultRoute()
            )
        );
        soltoken.mint(user, 100e18);
        usdc.mint(user, 5_000e6);
        vm.startPrank(user);
        soltoken.approve(address(v), 100e18);
        usdc.approve(address(v), 5_000e6);
        v.deposit(100e18, 5_000e6);
        vm.stopPrank();

        // NEW ROUTING: the $5k is strategy capital (rotated), not an inert owner reserve.
        assertEq(v.usdcRotatedEvm(), 5_000e6);
        assertEq(v.usdcMarginEvm(), 0);

        // Fall: rotate the directional to USDC; the perp short is inexpressible (skipped).
        warpTo(Calendar.P);
        crankUntilIdle(v, 30);
        assertEq(v.dirEvm(), 0);
        assertEq(v.usdcRotatedEvm(), 25_000e6, "whole strategy rotates to USDC");
        assertEq(v.perpMargin6(), 0);
        assertEq(v.usdcMarginEvm(), 0);

        // External perp top-up still recoverable.
        hub.addWithdrawable(address(v), 250e6);
        vm.prank(user);
        v.recoverPerpSurplus();
        crankUntilIdle(v, 5);
        assertEq(usdc.balanceOf(user), 250e6);

        // Full exit at the fall plateau: whole 25k NAV less one penalty + 250 recovery.
        vm.prank(user);
        v.initiateExit(1e18);
        crankUntilIdle(v, 10);
        assertEq(v.exitShareWad(), 0);
        console2.log("owner usdc", usdc.balanceOf(user));
        assertGt(usdc.balanceOf(user), 22_000e6);
        assertLt(usdc.balanceOf(user), 22_500e6);
    }

    // --------------------------------------------------------- C: adapted SyncMachine:298
    /// Pro round trip growth→fall→growth: margin must come home and REDEPLOY as strategy
    /// (new routing), ending flat with perpMargin6 == 0 and the value back in the spot leg.
    function test_C_margin_roundtrip_lands_in_rotation_ADAPTED() public {
        B4Vault v = createVault(address(pro));
        fundAndDeposit(v, 1e8, 10_000e6);
        crankUntilIdle(v, 30); // growth: spot 1; everything deployed into spot
        assertEq(readPos(address(v)).szi, 0);
        assertEq(v.perpMargin6(), 0);
        assertEq(v.usdcMarginEvm(), 0);
        console2.log("growth: dir", v.dirEvm(), "rot", v.usdcRotatedEvm());

        warpTo(Calendar.P); // fall: 1x short
        crankUntilIdle(v, 40);
        assertLt(readPos(address(v)).szi, 0);
        assertGt(uint256(v.perpMargin6()), 0);
        console2.log("fall: szi<0 perpMargin", uint256(v.perpMargin6()));

        warpTo(Calendar.T + Calendar.W); // growth again
        crankUntilIdle(v, 40);
        assertEq(readPos(address(v)).szi, 0);
        assertEq(v.perpMargin6(), 0);
        assertEq(v.coreUsdcMarginWei(), 0);
        assertEq(v.usdcMarginEvm(), 0);
        // The money: margin returned to rotation and redeployed into the spot leg.
        console2.log(
            string.concat(
                "growth2: dir=",
                vm.toString(v.dirEvm()),
                " coreDir=",
                vm.toString(uint256(v.coreDirWei())),
                " rot=",
                vm.toString(v.usdcRotatedEvm()),
                " coreRot=",
                vm.toString(uint256(v.coreUsdcRotatedWei()))
            )
        );
        uint256 nav = v.navWad();
        console2.log("growth2: nav", nav);
        // Conservation: ~110k initial (1 BTC + $10k), no venue losses at flat prices in the mock.
        assertGt(nav, 109_000e18, "value conserved across the round trip");
        assertLt(nav, 111_000e18);
    }

    function readPos(address who) internal view returns (CoreTypes.Position memory) {
        (bool ok, bytes memory ret) =
            CoreTypes.PRECOMPILE_POSITION.staticcall(abi.encode(who, uint16(PERP_MKT)));
        require(ok, "read");
        return abi.decode(ret, (CoreTypes.Position));
    }
}
