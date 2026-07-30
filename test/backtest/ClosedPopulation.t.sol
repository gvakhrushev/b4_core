// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SimTest} from "./Sim.t.sol";
import {MockLzEndpoint} from "../mocks/MockLzEndpoint.sol";
import {HalvingOracle} from "src/core/HalvingOracle.sol";
import {B4ProductFactory} from "src/core/B4ProductFactory.sol";
import {B4Pool} from "src/core/B4Pool.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {B4VaultOps} from "src/core/B4VaultOps.sol";
import {B4VaultRecovery} from "src/core/B4VaultRecovery.sol";
import {B4VaultStorage} from "src/core/B4VaultStorage.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {Phi} from "src/libraries/Phi.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";
import {
    StrategyMini,
    StrategyB4,
    StrategyPro,
    StrategyProMax
} from "src/periphery/ReferenceStrategies.sol";

/// @notice Contract-backed closed-population simulator. Every run has ten equal daily
/// participants: r=10% means 9 stayers / 1 exiter; r=20% means 8 stayers / 2 exiters.
/// Each scenario creates the strict single-product pool for its selected strategy, so a
/// non-free exit goes through that product's escrow -> sleeve -> free-window realization
/// path before it can become an ordinary `claimFor` basket. There is no parallel return
/// or penalty model here.
contract ClosedPopulationTest is SimTest {
    uint256 internal constant DAILY_USER_WAD_CLOSED = 10e18;

    B4ProductFactory internal productFactory;
    address[4] internal productStrategies; // Mini, B4, Pro, Pro Max
    uint8 internal productPolicy;

    uint256 internal stayCount;
    uint256 internal exitCount;
    uint256 internal targetHodlBtcWad;
    uint256 internal targetHodlDepositWad;

    function test_closed_population_r10_b4_full() public {
        _runClosed(10e16, 0, "closed_r10_b4_full", HALVING_TS[0]);
    }

    function test_closed_population_r10_pro_full() public {
        _runClosed(10e16, 1, "closed_r10_pro_full", HALVING_TS[0]);
    }

    function test_closed_population_r10_promax_full() public {
        _runClosed(10e16, 2, "closed_r10_promax_full", HALVING_TS[0]);
    }

    function test_closed_population_r10_mini_full() public {
        _runClosed(10e16, 3, "closed_r10_mini_full", HALVING_TS[0]);
    }

    function test_closed_population_r20_b4_full() public {
        _runClosed(20e16, 0, "closed_r20_b4_full", HALVING_TS[0]);
    }

    function test_closed_population_r20_b4_c1mid() public {
        _runClosed(20e16, 0, "closed_r20_b4_c1mid", HALVING_TS[0] + 1191 days);
    }

    function test_closed_population_r20_pro_full() public {
        _runClosed(20e16, 1, "closed_r20_pro_full", HALVING_TS[0]);
    }

    function test_closed_population_r20_promax_full() public {
        _runClosed(20e16, 2, "closed_r20_promax_full", HALVING_TS[0]);
    }

    function test_closed_population_r20_mini_full() public {
        _runClosed(20e16, 3, "closed_r20_mini_full", HALVING_TS[0]);
    }

    /// @dev `entryTs` is deliberately an input: calculator-facing entry-date sweeps call this
    /// same runner independently, never as concurrent vaults in someone else's denominator.
    function _runClosed(uint256 rWad_, uint256 strat_, string memory label, uint256 entryTs)
        internal
    {
        rWad = rWad_;
        stratIdx = strat_;
        shardTag = label;
        productPolicy = _policyForScenario(strat_);
        _freshProductProtocol();
        _buildSchedule();

        // Ten equal participants make `r` an exact tenth-sized behavioural input. The
        // public matrix pins 10% and 20%, while calculator-facing sweeps may choose any
        // 10% increment without silently rounding the population or the denominator.
        exitCount = rWad_ * 10 / Phi.WAD;
        require(exitCount > 0 && exitCount < 10 && exitCount * Phi.WAD / 10 == rWad_, "bad r");
        stayCount = 10 - exitCount;
        for (uint256 i = 0; i < stayCount; i++) {
            _deployProductCohort(K_STAYER, "stayer", entryTs);
        }
        for (uint256 i = 0; i < exitCount; i++) {
            _deployProductCohort(K_EXITER, "exiter", entryTs);
        }

        uint256 pointIndex;
        uint256 nextHalving = 1;
        uint256 epoch;
        uint256 last;
        for (uint256 i = 0; i < ts.length; i++) {
            // A late entrant does not make the global pool/calendar late. Advance and lock
            // every historical point from h0, while withholding this population's deposits
            // until its chosen entry date.
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

            // A sleeve may only realize into common claim inventory during a free
            // exit window. Do this before the settlement point on the same day, so
            // the just-realized inventory enters that checkpoint's actual basket.
            if (Calendar.freeExit(t)) _driveProductSleeve(true);

            // Claims are made on the first eligible daily close, while this is still the
            // latest interval. They are not delayed to the next settlement point.
            _claimClosed(pxWad);
            while (pointIndex < pts.length && ts[i] >= pts[pointIndex]) {
                _settleClosed();
                pointIndex++;
            }
            if (_inAnchorWindow(t)) {
                try pool.sampleAnchor(1) {} catch {}
            }

            if (ts[i] >= entryTs) {
                for (uint256 j = 0; j < stayCount; j++) {
                    _deposit(j, DAILY_USER_WAD_CLOSED, pxWad);
                }
                targetHodlBtcWad += DAILY_USER_WAD_CLOSED * 1e18 / pxWad;
                targetHodlDepositWad += DAILY_USER_WAD_CLOSED;

                // An exiter is one of the population's daily users, not a synthetic flow.
                // Full same-day exit makes its gross cash flow exactly that day's deposit.
                for (uint256 j = 0; j < exitCount; j++) {
                    uint256 idx = stayCount + j;
                    _deposit(idx, DAILY_USER_WAD_CLOSED, pxWad);
                    _exitDailyIntoProductSleeve(idx, pxWad, t);
                }
            }

            // Outside a free window a sleeve remains live and follows the ordinary
            // permissionless engine; inside it the branch above keeps draining it.
            if (!Calendar.freeExit(t)) _driveProductSleeve(false);

            // Deposits enter EVM custody daily, and the ordinary keeper deploys them weekly.
            // At settlement `_settleClosed` forces an immediate idle state before reporting.
            if (i % 7 == 0) {
                for (uint256 j = 0; j < stayCount; j++) {
                    _crankUntilIdle(cohorts[j].v, 60);
                }
            }
        }

        vm.warp(ts[last]);
        uint256 pxEnd = _pxLive(ts[last]);
        _setPx(pxEnd);
        _claimClosed(pxEnd);

        Cohort storage target = cohorts[0];
        assertGt(target.cumDepWad, 0, "target funded");
        assertGt(target.cumClaimsWad, 0, "closed population receives a real pool claim");
        uint256 finalNavWad = target.v.navWad();
        uint256 finalWithClaimsWad = finalNavWad + target.cumClaimsWad;
        uint256 hodlWad = targetHodlBtcWad * pxEnd / 1e18;

        emit log_named_string("closed population", label);
        emit log_named_uint("target deposits WAD", target.cumDepWad);
        emit log_named_uint("target vault NAV WAD", finalNavWad);
        emit log_named_uint("target received claims WAD", target.cumClaimsWad);
        emit log_named_uint(
            "target total multiple x1e6", finalWithClaimsWad * 1e6 / target.cumDepWad
        );
        emit log_named_uint("same-flow HODL multiple x1e6", hodlWad * 1e6 / targetHodlDepositWad);
    }

    /// @dev Scenario indices retain the old B4/Pro/ProMax CLI order and add Mini as 3.
    function _policyForScenario(uint256 scenario) internal pure returns (uint8) {
        if (scenario == 0) return 2; // B4
        if (scenario == 1) return 3; // Pro
        if (scenario == 2) return 4; // Pro Max
        if (scenario == 3) return 1; // Mini
        revert("unknown product");
    }

    function _freshProductProtocol() internal {
        vm.warp(HALVING_TS[0]);
        endpoint = new MockLzEndpoint();
        oracle = new HalvingOracle(
            address(endpoint), SRC_EID, SRC_SENDER, HALVING_HEIGHT[0], address(this)
        );
        _acceptHalving(HALVING_HEIGHT[0], HALVING_TS[0]);
        address impl =
            address(new B4Vault(address(new B4VaultOps()), address(new B4VaultRecovery())));
        productFactory =
            new B4ProductFactory(address(oracle), usdcDescriptor(), impl, address(poolDeployer));
        productStrategies[0] = address(new StrategyMini());
        productStrategies[1] = address(new StrategyB4());
        productStrategies[2] = address(new StrategyPro());
        productStrategies[3] = address(new StrategyProMax());

        CoreTypes.AssetDescriptor[] memory dirs = new CoreTypes.AssetDescriptor[](1);
        dirs[0] = ubtcDescriptor();
        pool = B4Pool(
            productFactory.createProductPool(
                dirs, productStrategies, uint8(1) << (productPolicy - 1)
            )
        );
        assertEq(pool.policyMask(), uint8(1) << (productPolicy - 1), "selected isolated pool");
        assertTrue(pool.sleeveOf(productPolicy, 1) != address(0), "matching sleeve deployed");
    }

    function _deployProductCohort(uint8 kind, string memory tag, uint256 entryTs)
        internal
        returns (uint256 idx)
    {
        idx = cohorts.length;
        Cohort storage c = cohorts.push();
        c.kind = kind;
        c.tag = tag;
        c.entryTs = entryTs;
        c.owner = address(uint160(0xC400 + idx * 7 + 1));
        vm.prank(c.owner);
        c.v = B4Vault(
            productFactory.createVault(
                address(pool),
                CoreTypes.descriptorHash(ubtcDescriptor()),
                productStrategies[productPolicy - 1],
                Phi.WAD,
                100,
                B4VaultStorage.FeeRoute({
                    operator: address(0x0FE0),
                    operatorBps: 3819,
                    referrer: address(0),
                    referrerBps: 0
                })
            )
        );
        vm.prank(c.owner);
        ubtc.approve(address(c.v), type(uint256).max);
    }

    /// @dev The daily exiter is a real pool user. It transfers the exact in-kind
    /// penalty into product-specific escrow, then the pool folds that measured balance
    /// into its fixed sleeve. No dollar approximation chooses the sleeve capital.
    function _exitDailyIntoProductSleeve(uint256 idx, uint256 pxWad, uint256 t) internal {
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
        uint256 measuredPenaltyWad = escrowUsdc * 1e12 + escrowBtc * 1e10 * pxWad / 1e18;
        if (penalty == 0) {
            assertEq(measuredPenaltyWad, 0, "free exit cannot create sleeve capital");
        } else {
            assertLe(measuredPenaltyWad, penalty, "in-kind floor cannot exceed exit penalty");
            assertTrue(pool.foldPenalty(productPolicy, 1), "penalty folds into matching sleeve");
        }

        // Full same-day exits minimize strategy exposure, but in-kind flooring can
        // leave sub-cent residual dust. The penalty is therefore always derived from
        // the contract's live `nav`, never from an assumed zero-profit cash flow.
    }

    function _driveProductSleeve(bool freeWindow) internal {
        if (freeWindow) {
            pool.initiateSleeveExit(productPolicy, 1);
        }
        for (uint256 i = 0; i < (freeWindow ? 180 : 1); i++) {
            if (!pool.crankSleeve(productPolicy, 1)) break;
        }
    }

    function _settleClosed() internal {
        assertTrue(pool.advance(), "one passed settlement point materializes");
        uint256 id = pool.intervalCount() - 1;
        pool.lockPrices(id);
        for (uint256 j = 0; j < stayCount; j++) {
            _crankUntilIdle(cohorts[j].v, 80);
            cohorts[j].v.settle(id);
        }

        uint256 w0 = pool.weightOf(id, address(cohorts[0].v));
        for (uint256 j = 1; j < stayCount; j++) {
            assertEq(
                pool.weightOf(id, address(cohorts[j].v)),
                w0,
                "identical stayers report equal weight"
            );
        }
    }

    function _claimClosed(uint256 pxWad) internal {
        uint256 count = pool.intervalCount();
        if (count == 0) return;
        uint256 id = count - 1;
        if (block.timestamp <= pool.reportDeadline(id)) return;
        for (uint256 j = 0; j < stayCount; j++) {
            if (pool.weightOf(id, address(cohorts[j].v)) == 0) continue;
            address owner_ = cohorts[j].owner;
            uint256 btcBefore = ubtc.balanceOf(owner_);
            uint256 usdcBefore = usdc.balanceOf(owner_);
            pool.claimFor(id, address(cohorts[j].v));
            uint256 claimWad = (ubtc.balanceOf(owner_) - btcBefore) * 1e10 * pxWad / 1e18
                + (usdc.balanceOf(owner_) - usdcBefore) * 1e12;
            cohorts[j].cumClaimsWad += claimWad;
        }
    }
}
