// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Test.sol";
import {ClosedPopulationTest} from "./ClosedPopulation.t.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {Phi} from "src/libraries/Phi.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";

/// @notice A45 — value-conservation audit of the strict-pool penalty pipeline, and the pin for
/// the claim the docs make about it. For each product it tracks, in kind and in USD-at-the-day:
///   folds in → sleeve equity (MTM incl. unrealized perp PnL) → captured to accruing
///   → claims out → residuals (accruing / liability / escrow / sleeve) at run end.
///
/// What it proved the first time it ran: the Pro Max sleeve PRODUCES MORE than Mini's —
/// captured value at realization-day prices is strictly increasing in strategy strength
/// (Mini 33.6k < B4 34.4k < Pro 35.0k < Pro Max 44.5k). The published ranking used to invert
/// this (Mini 188.6k … Pro Max 6.1k) because it valued every claim "held in the kind it was
/// paid, untouched to run end": a settlement-token claim frozen for 13 years measures the
/// payout form, not the pool. The receipt-day gap that remains (Pro Max ~5.6k vs Mini ~10.4k)
/// is in-pool parking: a capture at the halving-boundary window waits in `accruing` until the
/// next settlement point (~1.5 years) — in kind for Mini (rides the asset), in settlement token
/// for Pro Max (flat). That parking is real protocol behaviour and stays visible in the
/// receipt-day number; the cross-product comparison must not add a 13-year freeze on top.
contract PoolYieldDiagTest is ClosedPopulationTest {
    uint256 internal foldBtc; // raw ubtc into sleeve
    uint256 internal foldUsdc; // raw usdc into sleeve
    uint256 internal foldWadAtFold; // USD value at fold day

    uint256 internal capBtc; // raw ubtc captured into accruing
    uint256 internal capUsdc; // raw usdc captured into accruing
    uint256 internal capWadAtDay; // USD value at capture day

    uint256 internal peakSleeveMtmWad;
    uint256 internal peakSleeveMtmTs;
    bool internal wasInWindow;
    uint256 internal windowN;

    /// Sequential runs per product, ascending strategy strength; asserts the pool
    /// PRODUCTION — captured value at realization-day prices — is strictly increasing, and
    /// that the unlevered sleeve conserves the penalty in kind (folds ≈ captures + sleeve
    /// tail). Split in two: all four runs in one test exceed the 40B block gas limit.
    function test_diag_pool_production_monotone_unlevered() public {
        uint256 capMini = _runDiag(3);
        assertLe(capBtc, foldBtc, "mini sleeve cannot create BTC");
        assertLt(foldBtc - capBtc, foldBtc / 50, "mini folds return in kind up to sleeve tail");

        uint256 capB4 = _runDiag(0);
        uint256 capPro = _runDiag(1);
        assertGt(capB4, capMini, "B4 sleeve production exceeds Mini");
        assertGt(capPro, capB4, "Pro sleeve production exceeds B4");
    }

    function test_diag_pool_production_monotone_levered() public {
        uint256 capPro = _runDiag(1);
        uint256 capProMax = _runDiag(2);
        assertGt(capProMax, capPro, "Pro Max sleeve production exceeds Pro");
    }

    function _resetRun() internal {
        _resetPopulation();
        foldBtc = 0;
        foldUsdc = 0;
        foldWadAtFold = 0;
        capBtc = 0;
        capUsdc = 0;
        capWadAtDay = 0;
        peakSleeveMtmWad = 0;
        peakSleeveMtmTs = 0;
        wasInWindow = false;
        windowN = 0;
    }

    function _runDiag(uint256 strat_) internal returns (uint256 capturedWadAtDay) {
        _resetRun();
        rWad = 20e16;
        stratIdx = strat_;
        shardTag = "diag";
        productPolicy = _policyForScenario(strat_);
        _freshProductProtocol();
        _buildSchedule();

        exitCount = 2;
        stayCount = 8;
        for (uint256 i = 0; i < stayCount; i++) {
            _deployProductCohort(K_STAYER, "stayer", HALVING_TS[0]);
        }
        for (uint256 i = 0; i < exitCount; i++) {
            _deployProductCohort(K_EXITER, "exiter", HALVING_TS[0]);
        }

        uint256 pointIndex;
        uint256 nextHalving = 1;
        uint256 epoch;
        uint256 last;
        for (uint256 i = 0; i < ts.length; i++) {
            if (ts[i] < HALVING_TS[0]) continue;
            last = i;
            vm.warp(ts[i]);
            uint256 pxWad = _pxLive(ts[i]);
            _setPx(pxWad);

            while (nextHalving < 4 && ts[i] >= HALVING_TS[nextHalving]) {
                _acceptHalving(HALVING_HEIGHT[nextHalving], HALVING_TS[nextHalving]);
                epoch = nextHalving;
                nextHalving++;
            }
            uint256 t = ts[i] - HALVING_TS[epoch];

            bool free = Calendar.freeExit(t);
            if (free && !wasInWindow) {
                windowN++;
                (uint256 nav, int256 mtm) = _sleeveState();
                console.log("=== window open #", windowN);
                console.log("  ts / px:", ts[i], pxWad / 1e18);
                console.log("  sleeve nav WAD:", nav);
                console.logInt(mtm);
            }
            wasInWindow = free;

            if (free) _driveDiag(true, pxWad);
            _claimClosed(pxWad);
            while (pointIndex < pts.length && ts[i] >= pts[pointIndex]) {
                _settleClosed();
                pointIndex++;
                _logCheckpoint(ts[i], pxWad);
            }
            if (_inAnchorWindow(t)) {
                try pool.sampleAnchor(1) {} catch {}
            }

            for (uint256 j = 0; j < stayCount; j++) {
                _deposit(j, DAILY_USER_WAD_CLOSED, pxWad);
            }
            for (uint256 j = 0; j < exitCount; j++) {
                uint256 idx = stayCount + j;
                _deposit(idx, DAILY_USER_WAD_CLOSED, pxWad);
                _exitDiag(idx, pxWad, t);
            }

            if (!free) _driveDiag(false, pxWad);

            if (i % 7 == 0) {
                for (uint256 j = 0; j < stayCount; j++) {
                    _crankUntilIdle(cohorts[j].v, 60);
                }
            }

            (, int256 mtmDay) = _sleeveState();
            if (mtmDay > 0 && uint256(mtmDay) > peakSleeveMtmWad) {
                peakSleeveMtmWad = uint256(mtmDay);
                peakSleeveMtmTs = ts[i];
            }
        }

        vm.warp(ts[last]);
        uint256 pxEnd = _pxLive(ts[last]);
        _setPx(pxEnd);
        _claimClosed(pxEnd);

        console.log("======== END STATE, strategy index:", strat_);
        console.log("px end:", pxEnd / 1e18);
        console.log("folds  btc raw / usdc raw:", foldBtc, foldUsdc);
        console.log("folds  USD at fold day WAD:", foldWadAtFold);
        console.log("capture btc raw / usdc raw:", capBtc, capUsdc);
        console.log("capture USD at day WAD:", capWadAtDay);
        console.log("target claims btc raw / usdc raw:", targetClaimBtc, targetClaimUsdc);
        console.log("target claims receipt-day WAD:", cohorts[0].cumClaimsWad);
        (uint256 navEnd, int256 mtmEnd) = _sleeveState();
        console.log("sleeve nav end WAD:", navEnd);
        console.logInt(mtmEnd);
        console.log("sleeve MTM peak WAD / ts:", peakSleeveMtmWad, peakSleeveMtmTs);
        console.log("accruing usdc / btc:", pool.accruing(0), pool.accruing(1));
        console.log(
            "liability usdc / btc:", pool.liability(address(usdc)), pool.liability(address(ubtc))
        );
        return capWadAtDay;
    }

    function _logCheckpoint(uint256 nowTs, uint256 pxWad) internal view {
        (uint256 nav, int256 mtm) = _sleeveState();
        console.log("--- settle ts / px:", nowTs, pxWad / 1e18);
        console.log("  cum fold USD@fold WAD:", foldWadAtFold);
        console.log("  cum capture USD@day WAD:", capWadAtDay);
        console.log("  cum target claims receipt WAD:", cohorts[0].cumClaimsWad);
        console.log("  sleeve nav after WAD:", nav);
        console.logInt(mtm);
    }

    /// Same daily exiter as the parent, plus fold-side accounting.
    function _exitDiag(uint256 idx, uint256 pxWad, uint256 t) internal {
        B4Vault v = cohorts[idx].v;
        uint256 nav = v.navWad();
        assertGt(nav, 0, "daily exiter funded");
        uint256 penalty = Calendar.freeExit(t) ? 0 : Phi.wmul(nav, Phi.EXIT_Q);
        uint256 escrowUsdcBefore = pool.penaltyEscrow(productPolicy, 1, 0);
        uint256 escrowBtcBefore = pool.penaltyEscrow(productPolicy, 1, 1);

        vm.prank(cohorts[idx].owner);
        v.initiateExit(Phi.WAD);
        _crankUntilIdle(v, 40);
        assertEq(v.exitShareWad(), 0, "daily exiter finalizes");

        uint256 escrowUsdc = pool.penaltyEscrow(productPolicy, 1, 0) - escrowUsdcBefore;
        uint256 escrowBtc = pool.penaltyEscrow(productPolicy, 1, 1) - escrowBtcBefore;
        if (penalty != 0) {
            foldBtc += escrowBtc;
            foldUsdc += escrowUsdc;
            foldWadAtFold += escrowUsdc * 1e12 + escrowBtc * 1e10 * pxWad / 1e18;
            assertTrue(pool.foldPenalty(productPolicy, 1), "penalty folds into matching sleeve");
        }
    }

    /// Parent's sleeve drive wrapped with accruing-delta capture accounting.
    function _driveDiag(bool freeWindow, uint256 pxWad) internal {
        uint256 a0 = pool.accruing(0);
        uint256 a1 = pool.accruing(1);
        _driveProductSleeve(freeWindow);
        uint256 d0 = pool.accruing(0) - a0;
        uint256 d1 = pool.accruing(1) - a1;
        if (d0 != 0 || d1 != 0) {
            capUsdc += d0;
            capBtc += d1;
            capWadAtDay += d0 * 1e12 + d1 * 1e10 * pxWad / 1e18;
        }
    }

    /// Mark-to-market sleeve equity: navWad + unrealized perp PnL (same read as
    /// BacktestReal._equityWad — NAV alone is blind to the perp leg by B3).
    function _sleeveState() internal view returns (uint256 nav, int256 mtm) {
        address s = pool.sleeveOf(productPolicy, 1);
        nav = B4Vault(s).navWad();
        mtm = int256(nav);
        (bool ok, bytes memory ret) =
            CoreTypes.PRECOMPILE_POSITION.staticcall(abi.encode(s, uint16(PERP_MKT)));
        if (!ok || ret.length < 32) return (nav, mtm);
        CoreTypes.Position memory p = abi.decode(ret, (CoreTypes.Position));
        if (p.szi == 0) return (nav, mtm);
        uint64 absSz = uint64(p.szi > 0 ? p.szi : -p.szi);
        int256 markNtl = int256(uint256(absSz) * uint256(hub.markPxOf(PERP_MKT)));
        int256 uPnL6 = p.szi > 0
            ? markNtl - int256(uint256(p.entryNtl))
            : int256(uint256(p.entryNtl)) - markNtl;
        mtm += uPnL6 * int256(10 ** (18 - uint256(CoreTypes.PERP_USD_DECIMALS)));
    }
}
