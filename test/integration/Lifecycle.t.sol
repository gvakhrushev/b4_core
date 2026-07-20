// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {Keeper} from "src/periphery/Keeper.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {Phi} from "src/libraries/Phi.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";

/// @notice Full product-ladder lifecycle (TEST_PLAN §1 integration): four products in one
///         pool driven ONLY through the keeper across a whole cycle — growth, both
///         transitions, two settlements, distribution, buy-back, next halving, exit.
///         Asserts the global custody invariants at every checkpoint.
contract LifecycleTest is VaultTestBase {
    Keeper keeper;
    B4Vault vMini;
    B4Vault vB4;
    B4Vault vPro;
    B4Vault vProMax;
    address[] vaults;

    function setUp() public {
        setUpProtocol();
        keeper = new Keeper();
        vMini = createVault(address(mini));
        vB4 = createVault(address(b4));
        vPro = createVault(address(pro));
        vProMax = createVault(address(proMax));
        vaults = [address(vMini), address(vB4), address(vPro), address(vProMax)];

        fundAndDeposit(vMini, 1e8, 0);
        fundAndDeposit(vB4, 1e8, 0);
        fundAndDeposit(vPro, 1e8, 10_000e6);
        fundAndDeposit(vProMax, 1e8, 20_000e6);
    }

    function kcrank() internal {
        keeper.crank(pool, vaults, 20);
    }

    /// Books never exceed real assets, per vault and side (A11/B-series safety net).
    function assertBooksSound(B4Vault v) internal view {
        assertGe(ubtc.balanceOf(address(v)), v.dirEvm(), "dir evm books");
        assertGe(
            usdc.balanceOf(address(v)), v.usdcRotatedEvm() + v.usdcMarginEvm(), "usdc evm books"
        );
        assertGe(hub.spotBal(address(v), UBTC_CORE), v.coreDirWei(), "dir core books");
        assertGe(
            hub.spotBal(address(v), USDC_CORE),
            uint256(v.coreUsdcRotatedWei()) + v.coreUsdcMarginWei(),
            "usdc core books"
        );
        assertGe(hub.wd(address(v)), v.perpMargin6(), "perp books");
    }

    function assertAllSound() internal view {
        assertBooksSound(vMini);
        assertBooksSound(vB4);
        assertBooksSound(vPro);
        assertBooksSound(vProMax);
        // Pool discipline (D2).
        assertGe(usdc.balanceOf(address(pool)), pool.liability(address(usdc)));
        assertGe(ubtc.balanceOf(address(pool)), pool.liability(address(ubtc)));
    }

    function readSzi(address who) internal view returns (int64) {
        (bool ok, bytes memory ret) =
            CoreTypes.PRECOMPILE_POSITION.staticcall(abi.encode(who, uint16(PERP_MKT)));
        require(ok, "read");
        return abi.decode(ret, (CoreTypes.Position)).szi;
    }

    function test_full_cycle_all_products() public {
        // ---------------- growth: only Pro Max opens a long residual -----------------
        kcrank();
        kcrank();
        assertEq(readSzi(address(vMini)), 0);
        assertEq(readSzi(address(vB4)), 0);
        assertEq(readSzi(address(vPro)), 0);
        assertGt(readSzi(address(vProMax)), 0);
        assertAllSound();

        // ---------------- price runs up into the pivot ------------------------------
        hub.setSpotPx(SPOT_MKT, 120_000e4);
        hub.setMarkPx(PERP_MKT, 120_000e2);
        hub.setOraclePx(PERP_MKT, 120_000e2);

        // ClosingGrowth: targets interpolate toward zero; keeper tracks them.
        warpTo(Calendar.P - Calendar.W + 5 days);
        kcrank();
        kcrank();
        kcrank();
        assertAllSound();

        // ---------------- settlement point 1 (P − H): the zero crossing -------------
        warpTo(Calendar.P - Calendar.H + 10 minutes);
        kcrank(); // advance + lock + close residuals
        kcrank();
        kcrank(); // wrong-sign gone ⇒ settles all four
        assertEq(pool.intervalCount(), 1);
        (, uint64 lockedAt,, uint256 w1) = pool.intervalInfo(0);
        assertGt(lockedAt, 0);
        assertGt(w1, 0); // profitable interval: weights reported
        assertGt(pool.weightOf(0, address(vMini)), 0);
        assertGt(pool.weightOf(0, address(vProMax)), 0);
        assertAllSound();
        uint256 miniAfterFee = vMini.dirEvm(); // 1 BTC minus the in-kind operator cut

        // ---------------- fall: rotation + shorts open ------------------------------
        warpTo(Calendar.P + 1 days);
        for (uint256 i = 0; i < 6; i++) {
            kcrank();
        }
        assertEq(vB4.dirEvm(), 0); // B4 fully rotated
        assertGt(vB4.usdcRotatedEvm(), 0);
        assertEq(readSzi(address(vMini)), 0);
        assertLt(readSzi(address(vPro)), 0); // hedge short
        assertLt(readSzi(address(vProMax)), 0); // leveraged short
        // Mini still just holds — no trade in any regime (only the settle fee left).
        assertEq(vMini.dirEvm(), miniAfterFee);
        assertGt(miniAfterFee, 99_000_000); // fee is a sliver, not a rotation
        assertAllSound();

        // ---------------- drawdown: shorts profit, Mini rides it down ---------------
        hub.setSpotPx(SPOT_MKT, 80_000e4);
        hub.setMarkPx(PERP_MKT, 80_000e2);
        hub.setOraclePx(PERP_MKT, 80_000e2);
        kcrank();
        assertAllSound();

        // ---------------- settlement point 2 (T + H) --------------------------------
        warpTo(Calendar.T + Calendar.H + 10 minutes);
        kcrank();
        kcrank();
        kcrank();
        assertEq(pool.intervalCount(), 2);
        (, uint64 locked2,,) = pool.intervalInfo(1);
        assertGt(locked2, 0);
        // Shorts realized profit through the verified zero: weights reported again.
        assertGt(pool.weightOf(1, address(vProMax)), pool.weightOf(0, address(vProMax)));
        assertAllSound();

        // ---------------- distribution after the report window ----------------------
        warpTo(Calendar.T + Calendar.H + Calendar.SNAPSHOT_WINDOW + Calendar.REPORT_WINDOW + 1);
        uint256 ownerUsdcBefore = usdc.balanceOf(user);
        kcrank(); // claims for interval 1 pay the fixed owner
        assertAllSound();

        // ---------------- back to growth: buy-back ----------------------------------
        warpTo(Calendar.T + Calendar.W + 1 days);
        hub.setSpotPx(SPOT_MKT, 90_000e4);
        hub.setMarkPx(PERP_MKT, 90_000e2);
        hub.setOraclePx(PERP_MKT, 90_000e2);
        for (uint256 i = 0; i < 8; i++) {
            kcrank();
        }
        assertGt(vB4.dirEvm(), 9e7); // rotated back into BTC
        assertEq(readSzi(address(vPro)), 0); // hedge closed, margin returned
        assertEq(vPro.perpMargin6(), 0);
        assertGt(readSzi(address(vProMax)), 0); // long residual re-opened
        assertAllSound();

        // ---------------- next halving: epoch continuity + free exit ----------------
        uint32 ts2 = uint32(GENESIS_TS + 1_400 days);
        vm.warp(uint256(ts2) + 1 days);
        acceptHalving(GENESIS_HEIGHT + 210_000, ts2);
        (,, uint256 epoch) = oracle.latest();
        assertEq(epoch, 1);

        vm.prank(user);
        vB4.initiateExit(1e18); // inside the post-fact free window
        for (uint256 i = 0; i < 4; i++) {
            kcrank();
        }
        assertEq(vB4.exitShareWad(), 0);
        assertEq(pool.liability(address(ubtc)), 0); // free exit: no penalty entered
        assertAllSound();

        // Owner ended up with claims + the exited vault's assets.
        assertGt(usdc.balanceOf(user) + ubtc.balanceOf(user), ownerUsdcBefore);
    }

    /// Invariant 16: multiple vaults of one owner stay independent accounting domains —
    /// an exit on one changes nothing on the others.
    function test_multivault_independence() public {
        kcrank();
        kcrank();
        uint256 miniNav = vMini.navWad();
        uint256 proMaxEntry = vProMax.entryLedgerWad();

        warpTo(Calendar.P - Calendar.W + 1); // free zone
        vm.prank(user);
        vB4.initiateExit(1e18);
        for (uint256 i = 0; i < 4; i++) {
            kcrank();
        }
        assertEq(vB4.exitShareWad(), 0);

        // Independence: B4's exit leaves the co-resident vaults' accounting domains
        // untouched — Mini's NAV and Pro Max's entry ledger are exactly as before.
        assertEq(vMini.navWad(), miniNav);
        assertEq(vProMax.entryLedgerWad(), proMaxEntry);
        assertAllSound();
    }
}
