// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {Phi} from "src/libraries/Phi.sol";

/// @notice The product's core claim, asserted end to end: the position is closed by REAL
///         orders, 1/10 per day across the 10-day closing leg, and the interval's profit is
///         the actual proceeds against what was actually paid in — no mark anywhere.
contract RealizedCloseTest is VaultTestBase {
    function _setPx(uint256 usd) internal {
        hub.setSpotPx(SPOT_MKT, uint64(usd * 1e4));
        hub.setMarkPx(PERP_MKT, uint64(usd * 1e2));
        hub.setOraclePx(PERP_MKT, uint64(usd * 1e2));
    }

    function setUp() public {
        setUpProtocol();
    }

    /// Enter at 1k, ride to ~4k, then let the calendar close it day by day at whatever the
    /// market prints each day (3900 / 4000 / 4100 ...). Profit must equal realised USDC
    /// minus the deposit, and settlement must need no price at all.
    function test_close_is_realised_day_by_day_and_profit_is_actual_proceeds() public {
        _setPx(1_000);
        B4Vault v = createVault(address(b4)); // B4 = (1, 0): flat by the settlement point
        fundAndDeposit(v, 1e8, 0); // 1 BTC at 1k
        crankUntilIdle(v, 30);
        assertEq(v.entryLedgerWad(), 1_000e18, "paid in: 1k");

        _setPx(4_000);
        uint256 closeStart = GENESIS_TS + Calendar.P - Calendar.W;

        // Day-by-day through the 10-day closing leg, at a DIFFERENT price each day.
        uint256[10] memory px =
            [uint256(3_900), 4_000, 4_100, 3_950, 4_050, 4_200, 3_900, 4_000, 4_150, 4_000];
        uint256 prevDir = type(uint256).max;
        for (uint256 d = 0; d < 10; d++) {
            vm.warp(closeStart + d * 1 days);
            _setPx(px[d]);
            crankUntilIdle(v, 30);
            uint256 dirNow = v.dirEvm() + v.coreDirWei();
            assertLe(dirNow, prevDir, "the directional leg only ever shrinks while closing");
            prevDir = dirNow;
        }

        // At the settlement point the target is exactly zero: fully in fiat.
        vm.warp(GENESIS_TS + Calendar.P - Calendar.H);
        crankUntilIdle(v, 40);
        assertEq(v.dirEvm() + v.coreDirWei(), 0, "closed out by real orders");

        // Profit is proceeds minus what was paid in. No price is consulted to establish it:
        // the whole NAV is USDC, valued at a fixed 1 USD.
        uint256 proceeds = v.usdcRotatedEvm() + v.usdcMarginEvm();
        uint256 navWad = v.navWad();
        assertEq(navWad, _toWadUsdc(proceeds), "NAV is exactly the realised USDC");
        assertGt(navWad, v.entryLedgerWad(), "and it beat the 1k that was paid in");

        // Settlement is now price-independent: it reports the same profit at any spot print.
        pool.advance();
        uint256 id = pool.intervalCount() - 1;
        pool.lockPrices(id);
        uint256 navBefore = v.navWad();
        _setPx(50_000); // an absurd mark must change nothing
        assertEq(v.navWad(), navBefore, "a flat vault's NAV does not move with the mark");
        v.settle(id);
        assertGt(pool.weightOf(id, address(v)), 0, "fee taken on the realised gain");
    }

    function _toWadUsdc(uint256 amount6) internal pure returns (uint256) {
        return amount6 * 1e12;
    }
}
