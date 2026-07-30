// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {console2} from "forge-std/console2.sol";

/// @notice V8 Scope D: diagnose the V6B_2d waterfall failure ("usdc dust 17,784 > 10").
///         Replicates the skipped scenario and dumps EVERY bucket around each exit to
///         decide: real conservation leak vs stale assertion vs mis-routed bucket.
contract V8D_ExitWaterfallDiagTest is VaultTestBase {
    function setUp() public {
        setUpProtocol();
    }

    function p1() internal pure returns (uint256) {
        return Calendar.P - Calendar.H;
    }

    function _dump(B4Vault v, string memory tag) internal view {
        console2.log(
            string.concat(
                "== ",
                tag,
                " rotEvm=",
                vm.toString(v.usdcRotatedEvm()),
                " marEvm=",
                vm.toString(v.usdcMarginEvm()),
                " coreRot=",
                vm.toString(uint256(v.coreUsdcRotatedWei())),
                " coreMar=",
                vm.toString(uint256(v.coreUsdcMarginWei())),
                " perp6=",
                vm.toString(uint256(v.perpMargin6())),
                " dirEvm=",
                vm.toString(v.dirEvm()),
                " coreDir=",
                vm.toString(uint256(v.coreDirWei()))
            )
        );
        console2.log(
            string.concat(
                "   usdc: user=",
                vm.toString(usdc.balanceOf(user)),
                " op=",
                vm.toString(usdc.balanceOf(operator)),
                " ref=",
                vm.toString(usdc.balanceOf(referrer)),
                " pool=",
                vm.toString(usdc.balanceOf(address(pool))),
                " vault=",
                vm.toString(usdc.balanceOf(address(v))),
                " | ubtc: user=",
                vm.toString(ubtc.balanceOf(user)),
                " op=",
                vm.toString(ubtc.balanceOf(operator)),
                " ref=",
                vm.toString(ubtc.balanceOf(referrer)),
                " pool=",
                vm.toString(ubtc.balanceOf(address(pool)))
            )
        );
    }

    function test_diag_waterfall() public {
        B4Vault v = createVault(address(mini));
        fundAndDeposit(v, 1e8, 20_000e6);
        _dump(v, "post-deposit");

        hub.setSpotPx(SPOT_MKT, 120_000e4);
        warpTo(p1());
        pool.advance();
        uint256 id = pool.intervalCount() - 1;
        pool.lockPrices(id);
        v.settle(id);
        _dump(v, "post-settle");

        hub.setSpotPx(SPOT_MKT, 130_000e4);

        for (uint256 i; i < 3; i++) {
            vm.prank(user);
            v.initiateExit(0.1e18);
            uint256 steps;
            for (steps = 0; steps < 20 && v.exitShareWad() != 0; steps++) {
                v.crank();
            }
            _dump(v, string.concat("post-exit-", vm.toString(i)));
        }

        warpTo(Calendar.P + 1 days);
        vm.prank(user);
        v.initiateExit(0.1e18);
        uint256 s2;
        for (s2 = 0; s2 < 20 && v.exitShareWad() != 0; s2++) {
            v.crank();
        }
        _dump(v, "post-exit-penalty");
    }
}
