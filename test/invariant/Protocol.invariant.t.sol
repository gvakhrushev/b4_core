// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {B4VaultStorage} from "src/core/B4VaultStorage.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";

/// @notice Stateful invariant campaign over SECURITY_MODEL §2 (see INVARIANTS.md for the
///         full invariant → test traceability map, including which invariants are
///         asserted here at runtime vs covered structurally by unit regressions).
///         Handlers respect the state machine so the campaign makes forward progress
///         (TEST_PLAN §1), while adversarial handlers inject Core/EVM top-ups,
///         withdrawable drift, liquidation-style position cuts, dropped actions and
///         no-fill liquidity.
contract ProtocolHandler is VaultTestBase {
    B4Vault public vA; // Pro Max: exercises spot + perp + margin + harvest
    B4Vault public vB; // B4: rotation only — independence witness

    // ghosts — handler-observed violations are ALWAYS flags asserted by invariant
    // functions, never handler-local requires: with fail_on_revert = false a reverting
    // handler is silently tolerated and its assertion would be discarded (RAW-E-001).
    bool public unexpectedCrankRevert;
    bool public signFlipObserved;
    bool public policyMovedFunds;
    bool public reconcileHealFailed;
    bool public poolAdvanceReverted; // invariant 18 / H3: advance() is a permissionless step
    uint256 public totalWdDrainedA; // adversarial venue-loss ghost (1e6)
    int256 public vBGrowthSnap;
    int256 public vBFallSnap;
    address public routeOperatorSnap;
    uint16 public routeBpsSnap;

    constructor() {
        setUpProtocol();
        vA = createVault(address(proMax));
        vB = createVault(address(b4));
        fundAndDeposit(vA, 1e8, 20_000e6);
        fundAndDeposit(vB, 1e8, 0);
        vBGrowthSnap = vB.growthTarget();
        vBFallSnap = vB.fallTarget();
        (routeOperatorSnap, routeBpsSnap,,) = vA.route();
    }

    // ------------------------------------------------------------------ time & price

    function oracleTimeSinceHalving() external view returns (uint256) {
        return oracle.timeSinceHalving();
    }

    function warp(uint32 dt) external {
        vm.warp(block.timestamp + bound(uint256(dt), 1 hours, 30 days));
    }

    /// F12 (audit 2026-07-22): the small [1h, 30d] `warp` cannot reach the first calendar
    /// boundary (~day 538) within a bounded run, so sign-flips, rotations, settlements and
    /// pool distribution were fuzz-unreachable — every run stayed in Zone.Growth of epoch 0.
    /// This jumps the clock to a calendar-significant instant (monotone, never rewinds) so the
    /// campaign actually crosses transitions; subsequent crank/settle handlers then exercise
    /// the fall short, the B4 USDC rotation and the settlement/claim path.
    function warpPivot(uint8 sel) external {
        uint256 t = oracle.timeSinceHalving();
        uint256[6] memory marks = [
            Calendar.P - Calendar.H - 1, // ClosingGrowth (growth→fall transition)
            Calendar.P + 1, // OpeningFall — the fall short opens
            Calendar.P + Calendar.H + 5 days, // deep Fall
            Calendar.T - Calendar.H - 1, // ClosingFall (fall→growth transition)
            Calendar.T + Calendar.H + 5 days, // Terminal growth after the flip
            Calendar.T + Calendar.W + 60 days // deep terminal growth
        ];
        uint256 target = marks[sel % 6];
        if (target > t) vm.warp(block.timestamp + (target - t)); // advance only
    }

    function movePrice(uint16 seed) external {
        // px ∈ [20k, 500k], multiplicative steps of ±20%.
        uint64 px = hub.spotPxOf(SPOT_MKT);
        uint64 next = uint64(bound(uint256(seed), 80, 120)) * px / 100;
        next = uint64(bound(uint256(next), 20_000e4, 500_000e4));
        hub.setSpotPx(SPOT_MKT, next);
        hub.setMarkPx(PERP_MKT, next / 100); // keep conventions aligned (4→2 decimals)
        hub.setOraclePx(PERP_MKT, next / 100);
    }

    // ------------------------------------------------------------------ cranks

    function crankA(uint8 n) external {
        _crank(vA, n);
    }

    function crankB(uint8 n) external {
        _crank(vB, n);
    }

    function _crank(B4Vault v, uint8 n) internal {
        int64 prev = _szi(address(v));
        for (uint256 i = 0; i < bound(uint256(n), 1, 6); i++) {
            try v.crank() returns (bool progressed) {
                int64 cur = _szi(address(v));
                // Invariant 9: no sign flip within a single step — a sign change passes
                // through an observed zero.
                if ((prev > 0 && cur < 0) || (prev < 0 && cur > 0)) signFlipObserved = true;
                prev = cur;
                if (!progressed) break;
            } catch {
                // crank() has no expected-revert guards: any revert is a finding.
                unexpectedCrankRevert = true;
                break;
            }
        }
    }

    // ------------------------------------------------------------------ owner actions

    function deposit(uint64 dirAmt, uint64 usdcAmt) external {
        uint256 t = oracle.timeSinceHalving();
        if (!Calendar.depositOpen(t)) return;
        if (vA.exitShareWad() != 0) return;
        uint256 d = bound(uint256(dirAmt), 1e6, 1e8);
        uint256 u = bound(uint256(usdcAmt), 1e6, 10_000e6);
        ubtc.mint(user, d);
        usdc.mint(user, u);
        vm.startPrank(user);
        ubtc.approve(address(vA), d);
        usdc.approve(address(vA), u);
        vA.deposit(d, u);
        vm.stopPrank();
    }

    function selectPolicy(uint8 which) external {
        if (vA.exitShareWad() != 0) return;
        address strat = [address(mini), address(b4), address(pro), address(proMax)][which % 4];
        uint256 balDir = ubtc.balanceOf(address(vA));
        uint256 balUsdc = usdc.balanceOf(address(vA));
        vm.prank(user);
        vA.selectPolicy(strat, 1e18);
        // Invariant 12: policy change never invokes exit or penalty logic — no outflow.
        // Recorded as a GHOST, not a require: with fail_on_revert = false a handler-local
        // revert would be silently tolerated and the assertion would never fire.
        if (ubtc.balanceOf(address(vA)) != balDir || usdc.balanceOf(address(vA)) != balUsdc) {
            policyMovedFunds = true;
        }
    }

    function initiateExit(uint16 xBps) external {
        if (vA.exitShareWad() != 0) return;
        uint256 x = bound(uint256(xBps), 100, 10_000) * 1e14;
        vm.prank(user);
        try vA.initiateExit(x) {} catch {}
    }

    function recover(uint8 which) external {
        vm.startPrank(user);
        if (which % 3 == 0) {
            try vA.recoverCoreSpot(which % 2 == 0) {} catch {}
        } else if (which % 3 == 1) {
            try vA.recoverPerpSurplus() {} catch {}
        } else {
            try vA.emergencyClearRecovery() {} catch {}
        }
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ pool cranks

    function poolCrank() external {
        // advance() is a permissionless liveness step (invariant 18 / H3): it must never
        // revert. Guard it as a GHOST rather than letting a revert roll back the whole
        // handler call — with fail_on_revert = false that would be silently tolerated and
        // the rest of the pool crank (lock/sweep/capture) would be skipped unobserved.
        try pool.advance() {}
        catch {
            poolAdvanceReverted = true;
        }
        uint256 count = pool.intervalCount();
        if (count > 0) {
            try pool.lockPrices(count - 1) {} catch {}
            try pool.sweep(count >= 2 ? count - 2 : 0) {} catch {}
        }
        try pool.capture() {} catch {}
    }

    function settle(uint8 whichVault) external {
        (bool ok, uint256 id) = pool.currentReportable();
        if (!ok) return;
        B4Vault v = whichVault % 2 == 0 ? vA : vB;
        try v.settle(id) {} catch {}
    }

    function claim(uint8 whichVault) external {
        uint256 count = pool.intervalCount();
        if (count == 0) return;
        address v = whichVault % 2 == 0 ? address(vA) : address(vB);
        try pool.claimFor(count - 1, v) {} catch {}
    }

    // ------------------------------------------------------------------ adversaries

    function advCoreTopUp(uint8 tokenSel, uint64 amt) external {
        uint64 token = tokenSel % 2 == 0 ? USDC_CORE : UBTC_CORE;
        hub.coreTopUp(address(vA), token, uint64(bound(uint256(amt), 1, 1_000e8)));
    }

    function advEvmDonation(uint8 tokenSel, uint64 amt) external {
        if (tokenSel % 2 == 0) {
            usdc.mint(address(vA), bound(uint256(amt), 1, 1_000e6));
        } else {
            ubtc.mint(address(vA), bound(uint256(amt), 1, 1e8));
        }
    }

    function advWdTopUp(uint64 amt) external {
        hub.addWithdrawable(address(vA), uint64(bound(uint256(amt), 1, 1_000e6)));
    }

    function advWdDrain(uint64 amt) external {
        uint64 cur = hub.wd(address(vA));
        uint64 cut = uint64(bound(uint256(amt), 0, cur));
        hub.subWithdrawable(address(vA), cut);
        totalWdDrainedA += cut;
    }

    /// Liquidation-style external position cut: only ever toward zero, with a wd haircut.
    function advLiquidation(uint8 frac) external {
        int64 szi = _szi(address(vA));
        if (szi == 0) return;
        int64 cut = szi / int64(uint64(bound(uint256(frac), 2, 4)));
        (, uint64 entryNtl,) = hub.positions(address(vA), PERP_MKT);
        uint64 newEntry = szi == 0 ? 0 : uint64(uint256(entryNtl) / 2);
        hub.setPosition(address(vA), PERP_MKT, szi - cut, newEntry);
        uint64 cur = hub.wd(address(vA));
        uint64 haircut = cur / 4;
        hub.subWithdrawable(address(vA), haircut);
        totalWdDrainedA += haircut;
    }

    function advVenueBehavior(uint8 dropN, uint16 fill) external {
        hub.setDropNext(bound(uint256(dropN), 0, 2));
        hub.setFillRatio(PERP_MKT, uint16(bound(uint256(fill), 0, 10_000)));
        hub.setFillRatio(
            uint32(CoreTypes.SPOT_ASSET_OFFSET + SPOT_MKT), uint16(bound(uint256(fill), 0, 10_000))
        );
    }

    /// B2 self-healing witness: whenever the vault is flat, idle, and has no pending
    /// harvest, ONE crank must reconcile recorded perp margin down to the live
    /// withdrawable — the sync planner runs `_reconcile` (step 3) before creating any
    /// intent. The pending-harvest gate is required: a harvest-settle crank runs BEFORE
    /// reconcile and may zero-settle without healing, which is the designed one-crank
    /// delay, not a violation.
    function reconcileHeals() external {
        if (intentKindOf(vA) != B4VaultStorage.IntentKind.None) return;
        if (_szi(address(vA)) != 0) return;
        if (vA.pendingHarvest6() != 0) return;
        try vA.crank() {}
        catch {
            unexpectedCrankRevert = true;
            return;
        }
        // Ghost, not require (invariant-revert masking): asserted by
        // invariant_reconcile_heals. Only meaningful when the crank left the engine idle
        // — a crank may legitimately CREATE an in-flight margin return, whose designed wd
        // dip is not a loss.
        if (
            intentKindOf(vA) == B4VaultStorage.IntentKind.None
                && vA.perpMargin6() > hub.wd(address(vA))
        ) {
            reconcileHealFailed = true;
        }
    }

    function _szi(address who) internal view returns (int64) {
        (int64 szi,,) = hub.positions(who, PERP_MKT);
        return szi;
    }
}

contract ProtocolInvariantTest is VaultTestBase {
    ProtocolHandler handler;

    function setUp() public {
        handler = new ProtocolHandler();
        // Share the handler's world (everything lives at fixed/etched addresses).
        hub = handler.hub();
        usdc = handler.usdc();
        ubtc = handler.ubtc();
        pool = handler.pool();
        targetContract(address(handler));
    }

    /// F12 reachability proof (deterministic, not fuzzed): the `warpPivot` handler action the
    /// fuzzer now has makes the fall regime — and the sign flip through it — reachable and
    /// safe. Before this handler the [1h,30d] warp could not reach day ~538 in a bounded run,
    /// so every campaign stayed in Zone.Growth of epoch 0 and the transition invariants were
    /// vacuous. Here we drive the exact path the fuzzer can now explore and confirm the vault
    /// crosses into the fall with a negative target and cranks without reverting.
    function test_F12_fall_regime_reachable_via_pivot_handler() public {
        // Start in growth: Pro Max target is a positive (leveraged long) exposure.
        assertGt(handler.vA().growthTarget(), int256(0));
        // The fuzzer's warpPivot(1) jumps to OpeningFall; crankA then rotates.
        handler.warpPivot(1);
        uint256 t = handler.oracleTimeSinceHalving();
        assertGe(t, Calendar.P, "clock reached the fall regime (>= 38.2% pivot)");
        assertLt(t, Calendar.T, "still before the 62% pivot");
        assertLt(handler.vA().fallTarget(), int256(0), "Pro Max fall target is a short");
        handler.crankA(6); // must not revert in the transition
        assertFalse(handler.unexpectedCrankRevert(), "crank safe across the transition");
    }

    /// Invariants 3/4/5/6/17 (operational form): recorded books never exceed real assets
    /// on any custody side when the engine is idle (mid-intent, recorded values are
    /// deliberately conservative and re-measured at completion).
    function invariant_books_never_exceed_assets() public view {
        _checkBooks(handler.vA(), handler.totalWdDrainedA());
        _checkBooks(handler.vB(), 0);
    }

    function _checkBooks(B4Vault v, uint256 drained) internal view {
        if (intentKindOf(v) != B4VaultStorage.IntentKind.None) return;
        assertGe(ubtc.balanceOf(address(v)), v.dirEvm(), "dir EVM phantom");
        assertGe(
            usdc.balanceOf(address(v)), v.usdcRotatedEvm() + v.usdcMarginEvm(), "usdc EVM phantom"
        );
        assertGe(hub.spotBal(address(v), UBTC_CORE), v.coreDirWei(), "dir core phantom");
        assertGe(
            hub.spotBal(address(v), USDC_CORE),
            uint256(v.coreUsdcRotatedWei()) + v.coreUsdcMarginWei(),
            "usdc core phantom"
        );
        // Perp margin may exceed live withdrawable only by real venue losses (realized
        // trading loss, adversarial drain, liquidation haircut) that reconcile at the
        // next flat valuation (B2) — NEVER by protocol action minting phantom margin.
        assertGe(
            uint256(hub.wd(address(v))) + drained + hub.realizedLoss6(address(v)),
            v.perpMargin6(),
            "perp phantom margin"
        );
    }

    /// Invariant 10: pool token balance ≥ recorded liability, always.
    function invariant_pool_balance_ge_liability() public view {
        assertGe(usdc.balanceOf(address(pool)), pool.liability(address(usdc)));
        assertGe(ubtc.balanceOf(address(pool)), pool.liability(address(ubtc)));
    }

    /// Invariant 9: a derivative sign change always passes through an observed zero.
    function invariant_no_sign_flip() public view {
        assertFalse(handler.signFlipObserved());
    }

    /// Invariant 18 / H3 (proxy): the permissionless crank never reverts — the worst
    /// case of every async/gate path is delayed liveness, not a stuck entrypoint.
    function invariant_crank_never_reverts() public view {
        assertFalse(handler.unexpectedCrankRevert());
    }

    /// Invariant 12 (via handler ghost): a policy change never moves funds out.
    function invariant_policy_never_moves_funds() public view {
        assertFalse(handler.policyMovedFunds());
    }

    /// B2 self-healing (via handler ghost): one crank on a flat, idle vault reconciles
    /// recorded perp margin down to the live withdrawable.
    function invariant_reconcile_heals() public view {
        assertFalse(handler.reconcileHealFailed());
    }

    /// Invariants 15/16: the fee route never changes after creation; an owner's second
    /// vault keeps its own stored policy untouched by the first vault's activity.
    function invariant_config_immutable() public view {
        (address op, uint16 bps,,) = handler.vA().route();
        assertEq(op, handler.routeOperatorSnap());
        assertEq(bps, handler.routeBpsSnap());
        assertEq(handler.vB().growthTarget(), handler.vBGrowthSnap());
        assertEq(handler.vB().fallTarget(), handler.vBFallSnap());
    }

    /// Invariant 18 / H3: the permissionless calendar-advance step never reverts. Unlike
    /// the removed `invariant_harvest_claim_not_blocking` (which only re-asserted the
    /// crank-revert ghost and whose harvest-quota state the adversarial campaign never
    /// reaches — that A5 discipline is proven deterministically by SyncMachine's R3 harness
    /// tests instead), this ghost IS exercised: every `poolCrank()` call drives advance().
    function invariant_pool_advance_never_reverts() public view {
        assertFalse(handler.poolAdvanceReverted());
    }
}
