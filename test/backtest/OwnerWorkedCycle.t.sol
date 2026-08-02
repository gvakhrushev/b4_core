// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Test.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {
    StrategyMini,
    StrategyB4,
    StrategyPro,
    StrategyProMax
} from "src/periphery/ReferenceStrategies.sol";

/// @title The owner's worked cycle, run through the real contracts.
/// @notice A synthetic price path where the answer is known by hand, so the engine's output can
///         be checked against the product thesis rather than against another model:
///
///           halving   $1,000   deposit $1,000 (1 BTC) into each product
///           38-point  $4,000   everyone is up 4x and holds the same $4,000
///           62-point  $2,000   the fall halves the price
///           halving   $5,000   the recovery
///
///         Expected by hand, and what each number means:
///           Mini   holds spot throughout          -> takes the -50 % fall, ends $5,000
///           B4     rotates to settlement at 38    -> no fall, rebuys 2x the BTC, ends $10,000
///           Pro    shorts 1x from 4k to 2k        -> +$2,000, rebuys 3x the BTC, ends $15,000
///           ProMax leveraged expression of Pro    -> more than Pro
///
///         The engine will not reproduce those figures exactly and should not: the calendar
///         rotates over 20-day windows rather than at an instant, entries DCA across them, the
///         performance fee is charged at each settlement, and the structural stop sizes the short
///         off confirmed anchors rather than at a hand-picked 2x. What MUST hold is the ordering
///         and the mechanism behind each step, which is what this pins.
contract OwnerWorkedCycleTest is VaultTestBase {
    uint256 constant DEPOSIT_BTC = 1e8; // 1 BTC at 8 decimals

    function setUp() public {
        setUpProtocol();
    }

    function _setPx(uint256 usd) internal {
        hub.setSpotPx(SPOT_MKT, uint64(usd * 1e4));
        hub.setMarkPx(PERP_MKT, uint64(usd * 1e2));
        hub.setOraclePx(PERP_MKT, uint64(usd * 1e2));
    }

    /// Walk from `fromDay` to `toDay` interpolating the price linearly, cranking daily and
    /// sampling the anchor windows exactly as the permissionless keeper does.
    function _walk(B4Vault[4] memory vs, uint256 fromDay, uint256 toDay, uint256 pxA, uint256 pxB)
        internal
    {
        uint256 span = toDay - fromDay;
        for (uint256 d = fromDay; d <= toDay; d++) {
            warpTo(d * 1 days);
            uint256 px = pxA + (pxB > pxA ? (pxB - pxA) * (d - fromDay) / span : 0)
                - (pxA > pxB ? (pxA - pxB) * (d - fromDay) / span : 0);
            _setPx(px);
            try pool.sampleAnchor(1) {} catch {}
            for (uint256 i = 0; i < 4; i++) {
                crankUntilIdle(vs[i], 24);
            }
        }
    }

    function test_owner_worked_cycle_ordering() public {
        B4Vault[4] memory vs = [
            createVault(address(new StrategyMini())),
            createVault(address(new StrategyB4())),
            createVault(address(new StrategyPro())),
            createVault(address(new StrategyProMax()))
        ];

        warpTo(0);
        _setPx(1_000);
        for (uint256 i = 0; i < 4; i++) {
            fundAndDeposit(vs[i], DEPOSIT_BTC, 0);
            crankUntilIdle(vs[i], 40);
        }

        uint256 dP = Calendar.P / 1 days; // the 38.2 % pivot
        uint256 dT = Calendar.T / 1 days; // the 61.8 % pivot
        uint256 dEnd = Calendar.CYCLE / 1 days - 1;

        _walk(vs, 0, dP, 1_000, 4_000); // growth: 1k -> 4k
        _walk(vs, dP, dT, 4_000, 2_000); // fall: 4k -> 2k
        _walk(vs, dT, dEnd, 2_000, 5_000); // recovery: 2k -> 5k

        string[4] memory names = ["Mini  ", "B4    ", "Pro   ", "ProMax"];
        uint256[4] memory navs;
        for (uint256 i = 0; i < 4; i++) {
            navs[i] = equityWad(vs[i]);
            console.log(names[i], navs[i] / 1e18, vs[i].navWad() / 1e18);
        }

        // The thesis, in the order the products are meant to sit in.
        assertGt(navs[1], navs[0], "B4 > Mini: rotating out of the fall beats holding through it");
        assertGt(navs[2], navs[1], "Pro > B4: shorting the fall beats sitting in settlement");
        assertGt(navs[3], navs[2], "Pro Max > Pro: leverage on the same signs");
        // Against the hand figures: Mini 5,000 (exact), B4 ~10,000, Pro ~15,000, Pro Max more.
        assertApproxEqRel(navs[0], 5_000e18, 0.05e18, "Mini ends at the 5x the price did");
        assertApproxEqRel(navs[1], 10_000e18, 0.1e18, "B4 rebuys ~2x the BTC");
        assertApproxEqRel(navs[2], 15_000e18, 0.1e18, "Pro's 1x short adds ~2,000 before rebuying");
        assertGt(navs[3], 2 * navs[2], "Pro Max is leveraged, not marginally ahead");
        // The trap this test exists to keep shut: read on navWad alone Pro Max ranks BELOW Pro,
        // because NAV excludes unrealized perp PnL (B3) and Pro Max is pure perp.
        assertLt(vs[3].navWad(), vs[2].navWad(), "navWad alone would invert the ladder");
    }
}
