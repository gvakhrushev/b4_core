// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {EngineHarness} from "../utils/EngineHarness.sol";
import {MockERC20} from "../mocks/MockCore.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {B4VaultStorage} from "src/core/B4VaultStorage.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {Phi} from "src/libraries/Phi.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";

/// @notice Sync state machine: rotation, margin, perp sizing, harvest — including the
///         TEST_PLAN §2 regressions 3 (harvest-quota deadlock, A4/A5) and 5 (strict
///         custody flatness, A10).
contract SyncMachineTest is VaultTestBase {
    EngineHarness h;

    function setUp() public {
        setUpProtocol();
        h = new EngineHarness();
        h.setup(ubtcDescriptor(), usdcDescriptor(), address(oracle));
        hub.setUserExists(address(h), true);
    }

    // =====================================================================
    // Rotation lifecycles
    // =====================================================================

    /// Mini: hold spot in both regimes — no venue action is EVER emitted after deposit,
    /// through every transition sub-window (SPEC §4 same-sign rule; TEST_PLAN §3b.13).
    /// The performance fee still accrues on interval profit at settlement (in kind, no
    /// forced sale) — asserted in test_settle_profit_fee_weight, which uses Mini.
    function test_mini_never_trades() public {
        B4Vault v = createVault(address(mini));
        fundAndDeposit(v, 1e8, 0);
        hub.setAuto(false, true, true); // queue would retain any emitted action

        uint256[8] memory sweep = [
            uint256(0),
            Calendar.P - Calendar.W + 1, // ClosingGrowth
            Calendar.P - Calendar.H, // the settlement crossing itself
            Calendar.P - 1, // OpeningFall
            Calendar.P + 1 days, // Fall plateau
            Calendar.T + 1, // ClosingFall
            Calendar.T + Calendar.H + 1, // OpeningGrowth
            Calendar.T + Calendar.W + 30 days // terminal growth
        ];
        for (uint256 i = 0; i < sweep.length; i++) {
            warpTo(sweep[i]);
            assertEq(crankUntilIdle(v, 10), 0); // planner finds nothing to do
            assertEq(hub.pendingActions(), 0); // and emitted NO venue action
        }
        assertEq(v.dirEvm(), 1e8); // holdings byte-identical to the deposit
    }

    /// B4: growth 1 → fall 0 rotates all directional capital into USDC and back.
    function test_b4_full_rotation_and_back() public {
        B4Vault v = createVault(address(b4));
        fundAndDeposit(v, 1e8, 0);

        warpTo(Calendar.P); // fall plateau: target 0
        uint256 steps = crankUntilIdle(v, 30);
        assertGt(steps, 0);
        assertEq(v.dirEvm(), 0);
        assertEq(v.coreDirWei(), 0);
        assertEq(v.coreUsdcRotatedWei(), 0); // returned to EVM custody
        assertEq(v.usdcRotatedEvm(), 100_000e6); // 1 BTC @ 100k
        // Entry ledger untouched by token-form changes (B4 hazard).
        assertEq(v.entryLedgerWad(), 100_000e18);

        warpTo(Calendar.T + Calendar.W); // back to growth: target 1
        crankUntilIdle(v, 30);
        // Bought back within the tolerance band (1%), remainder stays as USDC on EVM.
        assertGe(v.dirEvm(), 98e6); // ≥ 0.98 BTC
        assertEq(v.coreDirWei(), 0);
        assertEq(v.coreUsdcRotatedWei(), 0);
        assertEq(v.entryLedgerWad(), 100_000e18);
    }

    /// Pro Max growth: spot 1 + perp (φ−1); margin flows EVM→spot→perp with every arrow
    /// proven; notional respects the φ safety reserve.
    function test_promax_opens_leveraged_long() public {
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 1e8, 20_000e6);
        crankUntilIdle(v, 30);

        CoreTypes.Position memory pos = readPos(address(v));
        assertGt(pos.szi, 0); // long residual
        // Target notional = (φ−1)·100k ≈ 61,803 USD ⇒ ~6180 lots at $100k.
        assertApproxEqAbs(int256(pos.szi), int256(6180), 5);
        // Margin reserve moved: ≈ notional·φ/maxLev ≈ $2500.
        assertApproxEqAbs(uint256(v.perpMargin6()), 2_500e6, 5e6);
        // notional ≤ margin·maxLev/φ (SPEC §7).
        uint256 notional6 = uint256(uint64(pos.szi)) * MARK_PX; // lots·rawPx = 1e6 USD
        assertLe(notional6, uint256(v.perpMargin6()) * 40 * 1e18 / Phi.PHI);
        // Owner margin never entered strategy value (B3).
        assertEq(v.strategyValueWad(), 100_000e18);
    }

    /// Invariant 9: a derivative sign change passes through a verified zero — the long is
    /// fully reduced (raw zero observed) before any short opens.
    function test_promax_sign_change_passes_through_zero() public {
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 1e8, 20_000e6);
        crankUntilIdle(v, 30);
        assertGt(readPos(address(v)).szi, 0);

        warpTo(Calendar.P); // fall: target −φ
        bool sawExactZeroWhileFlat = false;
        bool wentShort = false;
        for (uint256 i = 0; i < 60; i++) {
            if (!v.crank()) break;
            int64 szi = readPos(address(v)).szi;
            if (szi == 0) sawExactZeroWhileFlat = true;
            if (szi < 0) {
                wentShort = true;
                // Zero must have been observed before the first short lot.
                assertTrue(sawExactZeroWhileFlat);
            }
        }
        assertTrue(wentShort);
        CoreTypes.Position memory pos = readPos(address(v));
        // Short ≈ φ·V/px with V ≈ 100k (rotated) ⇒ ~16180 lots, margin-capped.
        assertLt(pos.szi, -15_000);
    }

    // =====================================================================
    // Regression 3 (A4/A5): the harvest-quota deadlock.
    // =====================================================================

    /// Record a harvest quota, then drive the withdrawable BELOW the quota (adverse
    /// move). Harvest MUST clamp to the available amount, clear the quota entirely, and
    /// leave the vault operable — NOT revert into a permanent freeze.
    function test_R3_harvest_quota_deadlock_clamps_and_clears() public {
        // Open long 1 BTC @ entry $90k, mark $100k: +10k unrealized. Margin 2500.
        hub.setPosition(address(h), PERP_MKT, 1e4, 90_000e6);
        hub.setWithdrawable(address(h), 2_500e6);
        h.setBuckets(0, 0, 0, 0, 0, 0, 2_500e6);

        // Reduce half: realizes +5k, records quota min(surplus, pnl×frac) = 5,000e6.
        h.startPerpOrder(false, 5000, true);
        assertTrue(h.verify());
        assertEq(h.pendingHarvest6(), 5_000e6);

        // ADVERSE MOVE while the claim is pending: withdrawable collapses to 2,800e6 —
        // only 300e6 above principal. The recorded claim now exceeds what one call can
        // settle. (The fail-before build tried to settle the FULL claim and froze.)
        hub.setWithdrawable(address(h), 2_800e6);

        h.startFromPerp(B4VaultStorage.Purpose.Harvest, 0);
        hub.executeActions();
        assertTrue(h.verify());
        // Settled min(claim, available) = 300e6; quota cleared ENTIRELY (A4).
        assertEq(h.coreUsdcRotatedWei(), 300e8);
        assertEq(h.pendingHarvest6(), 0);
        assertEq(uint8(h.intentKind()), uint8(B4VaultStorage.IntentKind.None));

        // Vault fully operable: the remaining position reduces, margin returns.
        h.startPerpOrder(false, 5000, true); // no gate blocked this (A5)
        assertTrue(h.verify());
        assertEq(readPos(address(h)).szi, 0);
    }

    /// Sub-case: withdrawable == 0 (liquidation). The quota clears with zero settled —
    /// no revert, no freeze, no phantom.
    function test_R3_harvest_quota_withdrawable_zero_liquidation() public {
        h.setPendingHarvest(5_000e6);
        hub.setPosition(address(h), PERP_MKT, 0, 0); // liquidated away
        hub.setWithdrawable(address(h), 0);
        h.setBuckets(0, 0, 0, 0, 0, 0, 0);

        h.startFromPerp(B4VaultStorage.Purpose.Harvest, 0);
        // Nothing settleable: cleared immediately, no intent even created.
        assertEq(h.pendingHarvest6(), 0);
        assertEq(uint8(h.intentKind()), uint8(B4VaultStorage.IntentKind.None));
        assertFalse(h.planSync() && false); // vault still plans without reverting
    }

    /// A5: a pending harvest claim gates NOTHING — reduces and recovery remain callable.
    function test_R3_pending_claim_gates_nothing() public {
        hub.setPosition(address(h), PERP_MKT, 1e4, 100_000e6);
        hub.setWithdrawable(address(h), 2_500e6);
        h.setBuckets(0, 0, 0, 0, 0, 0, 2_500e6);
        h.setPendingHarvest(9_999_999e6); // absurd unsettleable claim

        h.startPerpOrder(false, 1e4, true); // reduce proceeds — no claim gate
        assertTrue(h.verify());
        assertEq(readPos(address(h)).szi, 0);
    }

    /// Claim drained between intent creation and venue execution: the resend re-clamps
    /// to the NEW availability and still clears (adversarial refutation attempt).
    function test_R3_adversarial_drain_between_create_and_execute() public {
        hub.setAuto(false, true, true);
        hub.setWithdrawable(address(h), 3_000e6);
        h.setBuckets(0, 0, 0, 0, 0, 0, 2_500e6);
        h.setPendingHarvest(500e6);
        h.startFromPerp(B4VaultStorage.Purpose.Harvest, 0); // amount = min(500, 500)
        // Drain BEFORE the venue processes: the queued transfer will no-op.
        hub.setWithdrawable(address(h), 2_500e6);
        hub.executeActions(); // wd(2500) < ntl? no— transfer of 500 with wd 2500 succeeds…
        // the venue applies it: wd 2000, spot +500e8 — fine, it completes.
        assertTrue(h.verify());
        assertEq(h.pendingHarvest6(), 0);

        // Harsher: nothing available at execution time at all.
        hub.setWithdrawable(address(h), 3_000e6);
        h.setPendingHarvest(400e6);
        h.startFromPerp(B4VaultStorage.Purpose.Harvest, 0);
        hub.setWithdrawable(address(h), 100e6); // below the 400 in flight; transfer no-ops
        hub.executeActions();
        assertFalse(h.verify());
        vm.warp(block.timestamp + 1 hours);
        assertTrue(h.verify()); // re-clamp: available = 0 ⇒ claim cleared, no freeze
        assertEq(h.pendingHarvest6(), 0);
        assertEq(uint8(h.intentKind()), uint8(B4VaultStorage.IntentKind.None));
    }

    /// Harvest bound: credit ≤ min(measured surplus, snapshotted +PnL, PnL × fraction).
    function test_harvest_bounds() public {
        // Case 1: measured surplus smaller than PnL×frac ⇒ bound by surplus.
        // Entry 90k, mark 100k: reduce half realizes +5,000, but wd started depressed
        // (2,000 < principal 2,500), so surplus after realization is only 4,500.
        hub.setPosition(address(h), PERP_MKT, 1e4, 90_000e6);
        hub.setWithdrawable(address(h), 2_000e6);
        h.setBuckets(0, 0, 0, 0, 0, 0, 2_500e6);
        h.startPerpOrder(false, 5000, true);
        assertTrue(h.verify());
        assertEq(h.pendingHarvest6(), 4_500e6); // min(surplus 4500, pnl×frac 5000)

        // Case 2: no positive PnL snapshot ⇒ no claim regardless of surplus.
        h.setPendingHarvest(0);
        hub.setExecPx(PERP_MKT, 0);
        hub.setPosition(address(h), PERP_MKT, 1e4, 110_000e6); // mark below entry: −PnL
        hub.setWithdrawable(address(h), 9_000e6); // huge surplus (e.g. funding/top-up)
        h.startPerpOrder(false, 5000, true);
        assertTrue(h.verify());
        // C1 decision: funding-style surplus is NOT fiatized into the realized ledger.
        assertEq(h.pendingHarvest6(), 0);
    }

    // =====================================================================
    // Regression 5 (A10): strict custody flatness on a fine-lot market.
    // =====================================================================

    /// A sub-epsilon residual position MUST block margin return; a full reduce must be
    /// able to drive to raw zero, after which margin returns.
    function test_R5_strict_flatness_blocks_margin_return() public {
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 1e8, 20_000e6);
        crankUntilIdle(v, 30); // long ~6180 lots open

        vm.prank(user);
        v.initiateExit(1e18);

        // Illiquid venue: reduces fill 99.9% — a handful of sub-epsilon lots survive.
        hub.setFillRatio(PERP_MKT, 9990);
        for (uint256 i = 0; i < 12; i++) {
            v.crank();
        }
        CoreTypes.Position memory pos = readPos(address(v));
        assertGt(pos.szi, 0); // residual dust position ($10-ish notional)
        // STRICT flatness: margin has NOT been returned over the open residual, and no
        // exit payout has happened (raw szi == 0 required, never an epsilon).
        assertGt(uint256(v.perpMargin6()), 0);
        assertEq(usdc.balanceOf(user), 0);
        assertEq(ubtc.balanceOf(user), 0);

        // Liquidity returns: the pending no-fill IOC clears at the timeout, a fresh
        // reduce-only close reaches raw zero, and the exit completes — margin returned,
        // payout released. Delayed liveness, self-healing by cranking (H3).
        hub.setFillRatio(PERP_MKT, 10_000);
        vm.warp(block.timestamp + 1 hours);
        crankUntilIdle(v, 40);
        assertEq(readPos(address(v)).szi, 0);
        assertEq(v.perpMargin6(), 0);
        assertEq(v.exitShareWad(), 0);
        assertGt(usdc.balanceOf(user), 0);
    }

    /// Surplus recovery under a 1-lot residual: NotFlat (A10) — epsilon never accepted.
    function test_R5_recovery_requires_raw_zero() public {
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 1e8, 20_000e6);
        crankUntilIdle(v, 30);
        hub.setPosition(address(v), PERP_MKT, 1, 10e6); // 1 lot = $10: sub-epsilon
        vm.prank(user);
        vm.expectRevert(B4VaultStorage.NotFlat.selector);
        v.recoverPerpSurplus();
    }

    // =====================================================================
    // Margin return path (flat) and B2 reconciliation in sync.
    // =====================================================================

    function test_margin_returns_when_target_zero_and_flat() public {
        B4Vault v = createVault(address(pro)); // fall: −1/φ perp
        fundAndDeposit(v, 1e8, 10_000e6);
        crankUntilIdle(v, 30); // growth: no perp for Pro (perp target 0)
        assertEq(readPos(address(v)).szi, 0);
        assertEq(v.perpMargin6(), 0); // nothing was ever allocated
        assertEq(v.usdcMarginEvm(), 10_000e6);

        warpTo(Calendar.P); // fall: opens short 1/φ with margin
        crankUntilIdle(v, 40);
        assertLt(readPos(address(v)).szi, 0);
        assertGt(uint256(v.perpMargin6()), 0);

        warpTo(Calendar.T + Calendar.W); // growth again: perp target 0
        crankUntilIdle(v, 40);
        // Short reduced to raw zero, margin returned all the way to the EVM reserve.
        assertEq(readPos(address(v)).szi, 0);
        assertEq(v.perpMargin6(), 0);
        assertEq(v.coreUsdcMarginWei(), 0);
        assertGt(v.usdcMarginEvm(), 9_000e6); // minus harvest/loss rounding only
    }

    /// B2 in sync: the planner reconciles a flat realized loss before sizing.
    function test_sync_reconciles_loss_before_sizing() public {
        hub.setWithdrawable(address(h), 700e6);
        h.setBuckets(0, 0, 0, 0, 0, 0, 1_000e6); // recorded 1000 vs actual 700
        h.planSync();
        assertEq(h.perpMargin6(), 700e6); // written down before any valuation
    }

    // =====================================================================
    // M-1: a sub-lot spot residual must not be reported as planner progress.
    // =====================================================================

    /// When the directional imbalance sits in the dead zone — above the tolerance band but
    /// below one whole lot — the spot order floors to a zero-size no-op. The planner MUST
    /// NOT count that as progress: it has to fall through and size the perp leg, and the
    /// crank must not spin forever on a false "progressed" (the perp hedge would otherwise
    /// never open). The default fine-lot fixture has 1 lot == the $10 band, so the dead zone
    /// is unreachable there; this uses a COARSE-lot market (spotSzDecimals 2 ⇒ 1 lot =
    /// $1,000) where band ($10) < residual ($500) < one lot.
    function test_M1_sublot_spot_residual_does_not_starve_perp() public {
        MockERC20 cbtc = new MockERC20("CBTC", 8);
        uint64 CBTC_CORE = 2;
        uint32 COARSE_MKT = 6;
        hub.registerToken(CBTC_CORE, address(cbtc), 8, 2, 8, "CBTC");
        hub.registerSpotMarket(COARSE_MKT, CBTC_CORE, USDC_CORE);
        hub.setSpotPx(COARSE_MKT, uint64(100_000 * 1e6)); // (8−2)=6 px decimals ⇒ $100k

        CoreTypes.AssetDescriptor memory dir = CoreTypes.AssetDescriptor({
            evmToken: address(cbtc),
            evmDecimals: 8,
            coreToken: CBTC_CORE,
            spotMarket: COARSE_MKT,
            perpMarket: PERP_MKT,
            coreWeiDecimals: 8,
            spotSzDecimals: 2,
            perpSzDecimals: 4,
            perpMaxLeverage: 40,
            fixedUsd: false
        });

        EngineHarness g = new EngineHarness();
        g.setup(dir, usdcDescriptor(), address(oracle));
        g.setTargets(int256(15e17), int256(15e17)); // n = 1.5 ⇒ spot 1, perp +0.5
        hub.setUserExists(address(g), true);
        hub.setPosition(address(g), PERP_MKT, 0, 0); // flat
        hub.setWithdrawable(address(g), 50e6); // == recorded margin ⇒ no reconcile write-down

        // $400 directional + $500 rotated USDC on Core = $900 strategy value; target is
        // 100% spot, so the $500 rotated residual wants to buy dir — but $500 < $1,000 lot,
        // so the buy floors to zero lots (a no-op), while $500 > the $10 band.
        g.setBuckets(0, 0, 0, 400_000, 50e8, 0, 50e6);

        bool progressed = g.planSync();

        // The fix: the sub-lot no-op is NOT progress, so planning reaches the perp leg and
        // sizes a real long (n−spot = +0.5) instead of short-circuiting.
        assertEq(uint8(g.intentKind()), uint8(B4VaultStorage.IntentKind.PerpOrder));
        assertGt(uint256(g.intentAmount()), 0);
        assertTrue(progressed);
        // Confirm we truly exercised the dead zone: no spot order fired, rotated balance
        // untouched (a real fill would have created a SpotOrder intent, not a PerpOrder).
        assertEq(g.coreUsdcRotatedWei(), 50e8);
    }

    function readPos(address who) internal view returns (CoreTypes.Position memory) {
        return abi.decode(
            _staticRead(CoreTypes.PRECOMPILE_POSITION, abi.encode(who, uint16(PERP_MKT))),
            (CoreTypes.Position)
        );
    }

    function _staticRead(address precompile, bytes memory data)
        internal
        view
        returns (bytes memory)
    {
        (bool ok, bytes memory ret) = precompile.staticcall(data);
        require(ok, "read");
        return ret;
    }
}
