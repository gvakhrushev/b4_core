// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {B4Pool} from "src/core/B4Pool.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {B4VaultStorage} from "src/core/B4VaultStorage.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {Phi} from "src/libraries/Phi.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";

/// @notice SECOND stateful campaign, complementing `Protocol.invariant.t.sol`. That one runs
///         a LEGACY pool (`policyMask == 0`) on a fully SYNCHRONOUS venue with the price
///         bounded to [20k, 500k], and asserts nothing about the weight layer. Four whole
///         classes of the 2026-07-25 audit are therefore unreachable there:
///
///           1. the strict Product-Pool domain — sleeves, per-policy `penaltyEscrow`,
///              `escrowHeld` and the `capturePenalty` receipt split (H-1) — never executes;
///           2. `setAuto(true,true,true)` collapses the emitted-but-unexecuted window that
///              ALL of HAZARDS class A defends, so no resend/completion complement is fuzzed;
///           3. a ZERO price is unreachable, so the H-2/H-3 dead-feed class is unreachable;
///           4. `entryLedgerWad`, `rewardBaseWad`, `weightOf` and `totalWeight` — the exact
///              accounting layer C-1 attacked — are unasserted.
///
///         This campaign closes all four: an AGGREGATE (mask 15) product pool with four live
///         sleeves, a venue whose sync/async mode is itself fuzzed (`advVenueMode` /
///         `advPump`), a price handler that reaches 0 and both extremes, and a weight-layer
///         invariant set. It also adds the LOSS half of invariant 18 that
///         `invariant_crank_never_reverts` is structurally incapable of testing: a
///         permissionless crank on a non-exiting vault must never pay ANY recipient.
contract StrictPoolHandler is VaultTestBase {
    uint256 internal constant DIR = 1; // the single directional asset index
    uint256 internal constant HALVING_PERIOD = 210_000;

    B4Pool public spool; // strict aggregate pool, policyMask == 15
    B4Vault public vPro; // policy 3, WITH a fee route (exercises the in-kind operator cut)
    B4Vault public vMax; // policy 4, zero route, a second independent owner
    address public owner2 = address(0xB0B);
    mapping(uint8 => B4Vault) public sleeveOf; // policy → pool-owned sleeve

    // ---------------------------------------------------------------- ghosts
    // Handler-observed violations are ALWAYS flags asserted by an invariant function, never
    // handler-local requires: with fail_on_revert = false a reverting handler is silently
    // tolerated and its assertion would be discarded (RAW-E-001).
    bool public unexpectedCrankRevert;
    bool public poolAdvanceReverted;
    bool public policyMovedFunds;
    /// C-1 half A: a settle credited more client share than the measured NAV gain allows.
    bool public weightExceededLegitimate;
    /// The weight the pool recorded is not the base the vault holds, immediately after settle.
    bool public reportedWeightMismatch;
    /// C-1 half B / `B4Pool.scaleWeight`: a FULLY exited vault kept an in-window claim.
    bool public weightSurvivedFullExit;
    /// B4: the entry ledger was credited by a permissionless crank (no capital arrived).
    bool public entryLedgerGrewOnCrank;
    /// B1/B4: a deposit credited the ledger by something other than its measured value.
    bool public depositLedgerMismatch;
    /// H-3: a directional deposit booked a cost basis while the spot feed read zero.
    bool public zeroPxDepositAccepted;
    /// Invariant 18, LOSS half: a crank moved value to an outside recipient.
    bool public crankPaidOut;
    /// Adversarial venue-loss ghost, per vault (1e6).
    mapping(address => uint256) public wdDrained;
    mapping(address => bool) internal _fullExitPending;

    // ---------------------------------------------------------------- exercise counters
    // Reported, not asserted: a campaign that never reaches a lane proves nothing about it,
    // and a silent zero here is exactly the failure mode this file exists to correct.
    uint256 public asyncPendingObserved;
    uint256 public zeroPxCranks;
    uint256 public settlesObserved;
    uint256 public claimsObserved;
    uint256 public fullExitsObserved;
    uint256 public foldsObserved;
    uint256 public sleeveExitsObserved;
    uint256 public halvingsAccepted;
    uint256 public weightsReported;

    constructor() {
        setUpProtocol();
        spool = createStrictPool(15);
        vPro = createStrictVault(spool, address(pro), user, defaultRoute());
        vMax = createStrictVault(
            spool, address(proMax), owner2, B4VaultStorage.FeeRoute(address(0), 0, address(0), 0)
        );
        for (uint8 policy = 1; policy <= 4; policy++) {
            sleeveOf[policy] = B4Vault(spool.sleeveOf(policy, DIR));
        }
        fundAndDepositFor(vPro, user, 1e8, 50_000e6);
        fundAndDepositFor(vMax, owner2, 1e8, 50_000e6);
    }

    // ================================================================= time & price

    /// @dev The venue does not hold an EMITTED action across an hour of wall clock: on a
    ///      funded network a CoreWriter action is consumed within a block or two, and a
    ///      permanent non-execution is an ecosystem-wide failure modeled separately and
    ///      explicitly by `setDropNext` (HAZARDS A7/A8). Every warp here crosses
    ///      RESEND_TIMEOUT, so the queue is drained first. Without this the campaign would
    ///      model an action that sits unexecuted for HOURS and then executes — the union of
    ///      "delayed" and "dropped", outside the documented venue model. The HAZARDS-A window
    ///      is untouched: it is about CRANKS observing a not-yet-effected action, and EVM->Core
    ///      credits and the Core->EVM debit-then-deliver window (A7) are deliberately NOT
    ///      drained here — the engine polls those forever by design, so a long delay there is
    ///      delayed liveness and squarely in scope.
    function _venueDrainsBeforeTime() internal {
        hub.executeActions(); // dropped actions stay dropped
    }

    /// Half the lane steps in HOURS, not weeks. Every window that matters here is narrow —
    /// the 24h snapshot window, the 2-day report window, the life of a claimable interval —
    /// and a single uniform [1h, 30d] step blows past all three far more often than not,
    /// which is a second, independent reason the weight layer went unobserved.
    function warp(uint32 dt) external {
        _venueDrainsBeforeTime();
        uint256 step = dt % 2 == 0
            ? bound(uint256(dt), 1 hours, 18 hours)
            : bound(uint256(dt), 1 hours, 30 days);
        vm.warp(block.timestamp + step);
    }

    /// Same F12 reasoning as the legacy campaign: a [1h, 30d] warp cannot reach the first
    /// calendar boundary inside a bounded run, so every transition would be vacuous.
    function warpPivot(uint8 sel) external {
        _venueDrainsBeforeTime();
        uint256 t = oracle.timeSinceHalving();
        uint256[6] memory marks = [
            Calendar.P - Calendar.H - 1,
            Calendar.P + 1,
            Calendar.P + Calendar.H + 5 days,
            Calendar.T - Calendar.H - 1,
            Calendar.T + Calendar.H + 5 days,
            Calendar.T + Calendar.W + 60 days
        ];
        uint256 target = marks[sel % 6];
        if (target > t) vm.warp(block.timestamp + (target - t));
    }

    /// Land INSIDE the 24h snapshot window of the next settlement point.
    ///
    /// Without this the whole weight layer is effectively fuzz-unreachable, which is the
    /// mechanical reason blind spot 4 exists: `lockPrices` only commits inside
    /// `[pointTime, pointTime + SNAPSHOT_WINDOW]` — 24 hours, recurring roughly once a year —
    /// and `reportWeight`/`claimFor` are both gated behind `lockedAt != 0`. The coarsest
    /// handler warp moves 30 days and `warpPivot` lands 10 days off the point, so a bounded
    /// run essentially never hits the window: no lock ⇒ no report ⇒ no weight ⇒ no claim, and
    /// every weight invariant would be silently vacuous.
    /// It therefore also performs the checkpoint duty the shipped `Keeper` exists for —
    /// materialize the point and lock its prices — because a bare warp is not enough: any of
    /// the other time-moving handlers fired next leaves the 24h window again, so splitting
    /// "be in the window" from "lock" across two fuzz calls reduced the reachable-lock rate
    /// to a few percent of runs, and the reported weight to zero in 65 of 66. `poolCrank`
    /// still exists un-timed, so the MISSED-window lane (advance without a lock, an
    /// unreportable interval, H3 liveness) is explored exactly as before.
    function warpToSettlementPoint(uint8 sel) external {
        _venueDrainsBeforeTime();
        uint256 next = Calendar.nextSettlementPoint(oracle.halvingTs(), spool.lastPointTime());
        if (next == 0 || next <= block.timestamp) return; // monotone: never rewind
        vm.warp(next + (uint256(sel) % 24) * 1 hours); // anywhere in the window, jittered
        // Capture BEFORE materializing: `advance` freezes `accruing` into the interval's
        // bucket, so an uncaptured penalty/donation would leave an EMPTY bucket and every
        // claim would be a no-op — `remaining <= bucket` and the shortfall arithmetic would
        // then be asserted only over zeros.
        try spool.capture() {} catch {}
        try spool.advance() {}
        catch {
            poolAdvanceReverted = true;
        }
        uint256 count = spool.intervalCount();
        if (count > 0) {
            try spool.lockPrices(count - 1) {} catch {}
        }
    }

    /// Close the report window of the newest interval, then claim: `claimFor` reverts
    /// `ReportWindowOpen` until `reportDeadline` passes, so without this the claim path never
    /// executes at all. Same reachability reasoning as `warpToSettlementPoint` — the claim
    /// window opens the instant the report window closes, and any other time handler fired
    /// next can push past the whole life of the interval; split across two fuzz calls,
    /// `claimsObserved` was 0 in every run. The standalone `claim` handler below stays, so
    /// out-of-order, repeated and sleeve-targeted claims are still fuzzed independently.
    function warpPastReportDeadline() external {
        _venueDrainsBeforeTime();
        uint256 count = spool.intervalCount();
        if (count == 0) return;
        uint256 dl = spool.reportDeadline(count - 1);
        if (block.timestamp <= dl) vm.warp(dl + 1);
        _claimFor(count - 1, address(vPro));
        _claimFor(count - 1, address(vMax));
    }

    function _claimFor(uint256 id, address target) internal {
        try spool.claimFor(id, target) {
            claimsObserved++;
        } catch {}
    }

    /// A new proven halving fact: resets the calendar, opens the post-fact free-exit window,
    /// fires the anchor halving flip and yields two FRESH settlement points — without it
    /// `Calendar.nextSettlementPoint` caps the campaign at two intervals ever, so sweep,
    /// expiry and multi-interval weight behaviour are unreachable.
    function acceptNextHalving() external {
        _venueDrainsBeforeTime();
        (uint256 h, uint256 ts0,) = oracle.latest();
        if (block.timestamp <= ts0 || block.timestamp > type(uint32).max) return;
        acceptHalving(h + HALVING_PERIOD, uint32(block.timestamp));
        halvingsAccepted++;
    }

    /// Blind spot 3: the legacy campaign clamps px into [20k, 500k], so the H-2/H-3
    /// dead-feed class is unreachable. Here 0 is a first-class lane (both directions: a
    /// feed that dies AND one that comes back), together with both extremes.
    function movePrice(uint16 seed) external {
        uint256 s = uint256(seed);
        uint64 next;
        uint256 lane = s % 32;
        if (lane < 2) {
            next = 0; // dead spot feed (H-2 held-position resize, H-3 ledger writers)
        } else if (lane == 2) {
            next = 1; // one raw unit — the extreme low end of the conversion range
        } else if (lane == 3) {
            next = 10_000_000e4; // extreme high end
        } else {
            uint64 px = hub.spotPxOf(SPOT_MKT);
            if (px == 0) px = SPOT_PX; // the feed returns from the dead
            uint256 nxt = uint256(px) * (50 + (s % 151)) / 100; // ×[0.5, 2.0]
            if (nxt == 0) nxt = 1;
            if (nxt > 10_000_000e4) nxt = 10_000_000e4;
            next = uint64(nxt);
        }
        hub.setSpotPx(SPOT_MKT, next);
        // next/100 is 0 for the smallest prices: a live spot feed with a DEAD perp feed is
        // itself a state the engine must hold through (V8-L-1), not a harness accident.
        hub.setMarkPx(PERP_MKT, next / 100);
        hub.setOraclePx(PERP_MKT, next / 100);
    }

    // ================================================================= cranks

    function crankPro(uint8 n) external {
        _crankVault(vPro, n);
    }

    function crankMax(uint8 n) external {
        _crankVault(vMax, n);
    }

    function _crankVault(B4Vault v, uint8 n) internal {
        Payees memory before_ = _snapPayees(v);
        uint256 ledger0 = v.entryLedgerWad();
        bool anyExit;
        bool anyRecovery;
        for (uint256 i = 0; i < bound(uint256(n), 1, 6); i++) {
            if (v.exitShareWad() != 0) anyExit = true;
            if (_isRecovery(intentKindOf(v))) anyRecovery = true;
            bool progressed;
            try v.crank() returns (bool p) {
                progressed = p;
            } catch {
                // crank() has no expected-revert guards: any revert is a finding.
                unexpectedCrankRevert = true;
                return;
            }
            if (!progressed) break;
        }
        _observe(v, before_, ledger0, anyExit, anyRecovery);
    }

    /// The only addresses a vault is ever allowed to pay, split by WHO may authorise it.
    struct Payees {
        uint256 fees; // operator + referrer + the pool (exit waterfall only)
        uint256 own; // this vault's fixed owner (exit waterfall or owner-started recovery)
    }

    function _snapPayees(B4Vault v) internal view returns (Payees memory s) {
        address o = v.owner();
        s.own = usdc.balanceOf(o) + ubtc.balanceOf(o);
        s.fees = usdc.balanceOf(operator) + ubtc.balanceOf(operator) + usdc.balanceOf(referrer)
            + ubtc.balanceOf(referrer);
        // A sleeve's owner IS the pool; counting it twice would charge an owner payout to
        // the fee bucket and misreport it.
        if (o != address(spool)) {
            s.fees += usdc.balanceOf(address(spool)) + ubtc.balanceOf(address(spool));
        }
    }

    function _isRecovery(B4VaultStorage.IntentKind k) internal pure returns (bool) {
        return k == B4VaultStorage.IntentKind.RecoverSpotDir
            || k == B4VaultStorage.IntentKind.RecoverSpotUsdc
            || k == B4VaultStorage.IntentKind.RecoverPerpPhase1
            || k == B4VaultStorage.IntentKind.RecoverPerpPhase2;
    }

    /// Post-crank ghost sweep, shared by user vaults and pool sleeves.
    function _observe(
        B4Vault v,
        Payees memory before_,
        uint256 ledger0,
        bool anyExit,
        bool anyRecovery
    ) internal {
        Payees memory now_ = _snapPayees(v);
        if (!anyExit) {
            // B4: only `deposit` may credit the entry ledger, and only for capital that
            // physically arrived. A crank moves value between custody sides and can only
            // ever scale the ledger DOWN (`_finalizeExit`), which `anyExit` excludes.
            if (v.entryLedgerWad() > ledger0) entryLedgerGrewOnCrank = true;
            // Invariant 18, LOSS half. `invariant_crank_never_reverts` is a revert proxy: it
            // can only ever witness a FREEZE. This is the other half — what a permissionless
            // caller can make the vault PAY. Two separate rules, because two different
            // parties authorise them:
            //   * operator, referrer and pool are paid ONLY by the settle / exit-finalize
            //     waterfall. No crank may ever increase them;
            //   * the fixed owner is additionally paid by an owner-STARTED surplus recovery,
            //     whose last leg (RecoverSpotX / RecoverPerpPhase2) does finalize on the
            //     crank and sends bounded unaccounted surplus straight to the owner (B6).
            //     That is authorised by the owner, not by the keeper, so it is carved out —
            //     and only for the owner, never for anyone else.
            if (now_.fees > before_.fees) crankPaidOut = true;
            if (!anyRecovery && now_.own > before_.own) crankPaidOut = true;
        }
        if (
            intentKindOf(v) != B4VaultStorage.IntentKind.None
                && hub.pendingActions() + hub.pendingCredits() + hub.pendingDeliveries() > 0
        ) asyncPendingObserved++;
        if (hub.spotPxOf(SPOT_MKT) == 0) zeroPxCranks++;
        if (_fullExitPending[address(v)] && v.exitShareWad() == 0) {
            _fullExitPending[address(v)] = false;
            fullExitsObserved++;
            // C-1 half B: the vault now holds no capital, so it must hold no claim on the
            // basket leavers fund for stayers — for as long as the weight is still mutable.
            // Past `reportDeadline` the weights are final and claims are open, and forfeiting
            // there would move `totalWeight` under live claimants (D2/D3): that window is the
            // documented residual, not a violation, so it is excluded here.
            uint256 k = v.lastSettledPlusOne();
            if (
                k != 0 && block.timestamp <= spool.reportDeadline(k - 1)
                    && spool.weightOf(k - 1, address(v)) != 0
            ) weightSurvivedFullExit = true;
        }
    }

    // ================================================================= owner actions

    function depositVault(uint8 which, uint64 dirAmt, uint64 usdcAmt) external {
        B4Vault v = _pick(which);
        if (v.exitShareWad() != 0) return;
        uint256 d = bound(uint256(dirAmt), 0, 1e8);
        uint256 u = bound(uint256(usdcAmt), 0, 20_000e6);
        if (d == 0 && u == 0) return;
        address o = v.owner();
        if (d > 0) ubtc.mint(o, d);
        if (u > 0) usdc.mint(o, u);
        uint256 pxWad = _pxWad();
        uint256 ledger0 = v.entryLedgerWad();
        vm.startPrank(o);
        if (d > 0) ubtc.approve(address(v), d);
        if (u > 0) usdc.approve(address(v), u);
        try v.deposit(d, u) {
            // H-3: a zero read is not a cost basis. A directional deposit must REVERT at a
            // dead feed, never book principal at 0 (which would then read as pure profit and
            // mint the matching pool weight out of the depositor's own capital).
            if (pxWad == 0 && d > 0) zeroPxDepositAccepted = true;
            // B1/B4: the credit is EXACTLY the measured receipt valued at the live price.
            uint256 expected =
                Phi.wmul(Phi.mulDiv(d, Phi.WAD, 1e8), pxWad) + Phi.mulDiv(u, Phi.WAD, 1e6);
            uint256 ledger1 = v.entryLedgerWad();
            if (ledger1 < ledger0 || ledger1 - ledger0 != expected) depositLedgerMismatch = true;
        } catch {}
        vm.stopPrank();
    }

    /// Strict pools only admit a monotone product upgrade (3 → 4); a downgrade must revert.
    function selectPolicy(uint8 which, uint8 sel) external {
        B4Vault v = _pick(which);
        if (v.exitShareWad() != 0) return;
        address strat = [address(mini), address(b4), address(pro), address(proMax)][sel % 4];
        uint256 balDir = ubtc.balanceOf(address(v));
        uint256 balUsdc = usdc.balanceOf(address(v));
        vm.prank(v.owner());
        try v.selectPolicy(strat, 1e18) {} catch {}
        // Invariant 12: a policy change never invokes exit or penalty logic — no outflow.
        if (ubtc.balanceOf(address(v)) != balDir || usdc.balanceOf(address(v)) != balUsdc) {
            policyMovedFunds = true;
        }
    }

    function initiateExitVault(uint8 which, uint16 xBps) external {
        B4Vault v = _pick(which);
        if (v.exitShareWad() != 0) return;
        // A quarter of the lane is a FULL exit. Left to `bound(xBps, 1, 10_000) == 10_000`
        // it is a 1-in-10^4 draw, and `fullExitsObserved` was 0 across every run — so the
        // `scaleWeight` property this campaign exists to assert was never once evaluated.
        uint256 x = xBps % 4 == 0 ? Phi.WAD : bound(uint256(xBps), 1, 9_999) * 1e14;
        vm.prank(v.owner());
        try v.initiateExit(x) {
            if (x == Phi.WAD) _fullExitPending[address(v)] = true;
        } catch {}
    }

    /// The H-3 escape hatch: an exit deferred forever by a dead feed must be withdrawable.
    function cancelExitVault(uint8 which) external {
        B4Vault v = _pick(which);
        vm.prank(v.owner());
        try v.cancelExit() {
            _fullExitPending[address(v)] = false;
        } catch {}
    }

    function recover(uint8 which, uint8 sel) external {
        B4Vault v = _pick(which);
        vm.startPrank(v.owner());
        if (sel % 3 == 0) {
            try v.recoverCoreSpot(sel % 2 == 0) {} catch {}
        } else if (sel % 3 == 1) {
            try v.recoverPerpSurplus() {} catch {}
        } else {
            try v.emergencyClearRecovery() {} catch {}
        }
        vm.stopPrank();
    }

    // ================================================================= pool + sleeves

    function poolCrank(uint8 sel) external {
        // advance() is a permissionless liveness step (invariant 18 / H3): it must never
        // revert. Guarded as a GHOST so the rest of the crank still runs.
        try spool.advance() {}
        catch {
            poolAdvanceReverted = true;
        }
        uint256 count = spool.intervalCount();
        if (count > 0) {
            try spool.lockPrices(count - 1) {} catch {}
            try spool.sweep(count >= 2 ? count - 2 : 0) {} catch {}
        }
        if (sel & 1 != 0) {
            try spool.capture() {} catch {}
        }
        if (sel & 2 != 0) {
            try spool.sampleAnchor(DIR) {} catch {}
        }
    }

    /// Both vaults per call, deliberately: the reportable window is ~3 days wide and the
    /// fuzzer only reaches it occasionally, so settling one arbitrarily-chosen vault halves
    /// an already scarce lane — and `totalWeight` is only interesting with two reporters.
    function settleVault(uint8) external {
        _settleOne(vPro);
        _settleOne(vMax);
    }

    function _settleOne(B4Vault v) internal {
        (bool ok, uint256 id) = spool.currentReportable();
        if (!ok) return;
        uint256 e = v.entryLedgerWad();
        uint256 base0 = v.rewardBaseWad();
        uint256 navBefore = v.navWad();
        (, uint16 opBps,,) = v.route();
        try v.settle(id) {
            settlesObserved++;
            // C-1 half A, recomputed INDEPENDENTLY of the module under test: weight is the
            // client share of measured interval profit and nothing else. `navBefore` is read
            // before `_reconcile`, which only ever writes recorded margin DOWN, so this is a
            // sound UPPER bound on what the settle could legitimately have produced.
            uint256 profit = navBefore > e ? navBefore - e : 0;
            uint256 virtualFee = Phi.wmul(profit, Phi.FEE_F);
            uint256 budget = base0 + (virtualFee - Phi.bps(virtualFee, opBps));
            if (v.rewardBaseWad() > budget) weightExceededLegitimate = true;
            if (spool.weightOf(id, address(v)) != v.rewardBaseWad()) reportedWeightMismatch = true;
            if (v.rewardBaseWad() > 0) weightsReported++;
        } catch {}
    }

    function claim(uint8 which) external {
        uint256 count = spool.intervalCount();
        if (count == 0) return;
        // Claiming for a SLEEVE is deliberately reachable: sleeves are registered with
        // `registerSleeve`, never `registerVault`, so they must never hold weight.
        address target =
            which % 3 == 2 ? address(sleeveOf[uint8(1 + (which % 4))]) : address(_pick(which));
        _claimFor(count - 1, target);
    }

    function foldPenalty(uint8 policy) external {
        uint8 p = uint8(bound(uint256(policy), 1, 4));
        try spool.foldPenalty(p, DIR) returns (bool folded) {
            if (folded) foldsObserved++;
        } catch {}
    }

    function initiateSleeveExit(uint8 policy) external {
        uint8 p = uint8(bound(uint256(policy), 1, 4));
        try spool.initiateSleeveExit(p, DIR) returns (bool started) {
            if (started) sleeveExitsObserved++;
        } catch {}
    }

    function crankSleeve(uint8 policy, uint8 n) external {
        uint8 p = uint8(bound(uint256(policy), 1, 4));
        B4Vault s = sleeveOf[p];
        Payees memory before_ = _snapPayees(s);
        uint256 ledger0 = s.entryLedgerWad();
        bool anyExit;
        bool anyRecovery;
        for (uint256 i = 0; i < bound(uint256(n), 1, 6); i++) {
            if (s.exitShareWad() != 0) anyExit = true;
            if (_isRecovery(intentKindOf(s))) anyRecovery = true;
            bool progressed;
            try spool.crankSleeve(p, DIR) returns (bool prog) {
                progressed = prog;
            } catch {
                unexpectedCrankRevert = true;
                return;
            }
            if (!progressed) break;
        }
        // `crankSleeve` also runs the pool's `_captureToAccruing`, which only ACCOUNTS a
        // balance already sitting in the pool — it moves no tokens, so the fee/pool payee
        // rule below still binds on this path.
        _observe(s, before_, ledger0, anyExit, anyRecovery);
    }

    // ================================================================= adversaries

    function advVenueMode(uint8 m) external {
        // Blind spot 2: `setAuto(true,true,true)` collapses the emitted-but-unexecuted
        // window to zero. Fuzzing the three flags independently is what makes the resend
        // predicate and its exact completion complement (HAZARDS A) reachable at all.
        hub.setAuto(m & 1 != 0, m & 2 != 0, m & 4 != 0);
    }

    /// The venue eventually gets around to it — in an arbitrary, adversarial order.
    function advPump(uint8 sel) external {
        if (sel & 1 != 0) hub.applyCredits();
        if (sel & 2 != 0) hub.executeActions();
        if (sel & 4 != 0) hub.deliverEvm();
    }

    function advCoreTopUp(uint8 whichV, uint8 tokenSel, uint64 amt) external {
        hub.coreTopUp(
            address(_pickAny(whichV)),
            tokenSel % 2 == 0 ? USDC_CORE : UBTC_CORE,
            uint64(bound(uint256(amt), 1, 1_000e8))
        );
    }

    function advEvmDonation(uint8 whichV, uint8 tokenSel, uint64 amt) external {
        address t = address(_pickAny(whichV));
        if (tokenSel % 2 == 0) {
            usdc.mint(t, bound(uint256(amt), 1, 1_000e6));
        } else {
            ubtc.mint(t, bound(uint256(amt), 1, 1e8));
        }
    }

    /// A donation straight into the pool: it must become ordinary claim inventory (D2),
    /// never sleeve escrow.
    function advPoolDonation(uint8 tokenSel, uint64 amt) external {
        if (tokenSel % 2 == 0) {
            usdc.mint(address(spool), bound(uint256(amt), 1, 1_000e6));
        } else {
            ubtc.mint(address(spool), bound(uint256(amt), 1, 1e8));
        }
    }

    function advWdTopUp(uint8 whichV, uint64 amt) external {
        hub.addWithdrawable(address(_pickAny(whichV)), uint64(bound(uint256(amt), 1, 1_000e6)));
    }

    function advWdDrain(uint8 whichV, uint64 amt) external {
        address t = address(_pickAny(whichV));
        uint64 cut = uint64(bound(uint256(amt), 0, hub.wd(t)));
        hub.subWithdrawable(t, cut);
        wdDrained[t] += cut;
    }

    /// Liquidation-style external position cut: only ever toward zero, with a wd haircut.
    function advLiquidation(uint8 whichV, uint8 frac) external {
        address t = address(_pickAny(whichV));
        (int64 szi, uint64 entryNtl,) = hub.positions(t, PERP_MKT);
        if (szi == 0) return;
        int64 cut = szi / int64(uint64(bound(uint256(frac), 2, 4)));
        hub.setPosition(t, PERP_MKT, szi - cut, uint64(uint256(entryNtl) / 2));
        uint64 haircut = hub.wd(t) / 4;
        hub.subWithdrawable(t, haircut);
        wdDrained[t] += haircut;
    }

    function advVenueBehavior(uint8 dropN, uint16 fill) external {
        hub.setDropNext(bound(uint256(dropN), 0, 2));
        hub.setFillRatio(PERP_MKT, uint16(bound(uint256(fill), 0, 10_000)));
        hub.setFillRatio(
            uint32(CoreTypes.SPOT_ASSET_OFFSET + SPOT_MKT), uint16(bound(uint256(fill), 0, 10_000))
        );
    }

    // ================================================================= helpers

    function _pick(uint8 which) internal view returns (B4Vault) {
        return which % 2 == 0 ? vPro : vMax;
    }

    /// Every vault in the world, sleeves included — adversaries target all six.
    function _pickAny(uint8 which) internal view returns (B4Vault) {
        uint8 i = which % 6;
        if (i == 0) return vPro;
        if (i == 1) return vMax;
        return sleeveOf[i - 1];
    }

    function _pxWad() internal view returns (uint256) {
        // UBTC spot px carries (8 − szDecimals) = 4 decimals.
        return Phi.mulDiv(uint256(hub.spotPxOf(SPOT_MKT)), Phi.WAD, 1e4);
    }

    function vaultAt(uint256 i) external view returns (B4Vault) {
        if (i == 0) return vPro;
        if (i == 1) return vMax;
        return sleeveOf[uint8(i - 1)];
    }
}

contract StrictPoolInvariantTest is VaultTestBase {
    StrictPoolHandler handler;
    B4Pool p;
    B4Vault[6] v; // [0]=vPro, [1]=vMax, [2..5]=sleeves 1..4

    uint256 internal constant DIR = 1;

    function setUp() public {
        handler = new StrictPoolHandler();
        // Share the handler's world (everything lives at fixed/etched addresses).
        hub = handler.hub();
        usdc = handler.usdc();
        ubtc = handler.ubtc();
        p = handler.spool();
        for (uint256 i = 0; i < 6; i++) {
            v[i] = handler.vaultAt(i);
        }
        targetContract(address(handler));
    }

    // ---------------------------------------------------------------- reachability proofs
    // Deterministic, not fuzzed: each proves that a lane the legacy campaign cannot enter is
    // genuinely reachable from this handler's action set. An invariant over an unreachable
    // state is vacuous, and a silently vacuous campaign is precisely the defect being fixed.

    function test_campaign_runs_a_strict_product_pool_with_four_sleeves() public view {
        assertEq(p.policyMask(), 15, "aggregate product pool, not the legacy basket");
        assertEq(p.policyOfVault(address(v[0])), 3, "Pro vault bound to its product");
        assertEq(p.policyOfVault(address(v[1])), 4, "Pro Max vault bound to its product");
        for (uint8 policy = 1; policy <= 4; policy++) {
            address s = p.sleeveOf(policy, DIR);
            assertTrue(s != address(0), "sleeve deployed");
            assertTrue(p.isSleeve(s), "sleeve registered");
            assertFalse(p.isVault(s), "a sleeve is never a reward-reporting vault");
        }
    }

    function test_async_venue_mode_leaves_intents_pending() public {
        handler.advVenueMode(0); // exec/credit/deliver all OFF
        handler.crankPro(1);
        assertTrue(
            hub.pendingActions() + hub.pendingCredits() > 0,
            "an emitted action sits unexecuted: the HAZARDS A window exists"
        );
        assertTrue(
            intentKindOf(handler.vPro()) != B4VaultStorage.IntentKind.None,
            "the vault is mid-intent, not collapsed to synchronous"
        );
        // Crank into the pending window repeatedly: no progress, no revert (delayed liveness).
        handler.crankPro(6);
        assertFalse(handler.unexpectedCrankRevert(), "async cranks never revert");
        handler.advPump(7); // the venue finally processes everything
        handler.crankPro(6);
        assertFalse(handler.unexpectedCrankRevert(), "completion after the delay never reverts");
    }

    function test_zero_price_is_reachable_and_every_step_holds() public {
        handler.advVenueMode(7);
        handler.warpPivot(0);
        handler.crankPro(6);
        handler.movePrice(0); // lane 0 ⇒ px = 0
        assertEq(hub.spotPxOf(SPOT_MKT), 0, "the spot feed is dead");
        (int64 sziBefore,,) = hub.positions(address(handler.vPro()), PERP_MKT);
        handler.crankPro(6);
        (int64 sziAfter,,) = hub.positions(address(handler.vPro()), PERP_MKT);
        assertFalse(handler.unexpectedCrankRevert(), "H-2/H-3: a dead feed holds, never reverts");
        assertEq(sziAfter, sziBefore, "H-2: a held structural perp is not re-sized at px 0");
        handler.depositVault(0, 1e7, 0);
        assertFalse(handler.zeroPxDepositAccepted(), "H-3: no cost basis is booked at px 0");
        handler.movePrice(4); // the feed returns
        assertGt(hub.spotPxOf(SPOT_MKT), 0, "and the campaign recovers from it");
    }

    /// The whole weight pipeline, driven deterministically and NON-VACUOUSLY: a real profit,
    /// a real reported weight, then `B4Pool.scaleWeight` taking it away on a full exit.
    /// Every step is asserted, so this test cannot silently degrade into a no-op the way an
    /// unasserted fuzz lane can.
    function test_settle_reports_weight_and_a_full_exit_forfeits_it() public {
        B4Vault vp = handler.vPro();
        handler.advVenueMode(7); // fully synchronous venue for a deterministic path
        handler.crankPro(6); // deploy the product
        handler.movePrice(150); // x2.0 lane: real interval profit
        handler.crankPro(6);
        handler.warpToSettlementPoint(3); // capture + advance + lockPrices, inside the window
        handler.crankPro(6); // back to idle so settle can value an exact ledger
        assertEq(p.intervalCount(), 1, "the checkpoint materialized");
        (, uint64 lockedAt,,) = p.intervalInfo(0);
        assertTrue(lockedAt != 0, "prices locked inside the 24h snapshot window");

        handler.settleVault(0);
        uint256 k = vp.lastSettledPlusOne();
        assertEq(k, 1, "the interval settled");
        uint256 w = p.weightOf(0, address(vp));
        assertGt(w, 0, "a profitable settle actually reported weight");
        assertEq(w, vp.rewardBaseWad(), "pool weight is the vault's reward base");
        (,,, uint256 total) = p.intervalInfo(0);
        assertEq(total, w + p.weightOf(0, address(handler.vMax())), "totalWeight is closed");

        handler.initiateExitVault(0, 10_000); // exactly WAD
        for (uint256 i = 0; i < 40; i++) {
            handler.crankPro(6);
            if (vp.exitShareWad() == 0) break;
        }
        assertEq(vp.exitShareWad(), 0, "the full exit finalized");
        assertLe(block.timestamp, p.reportDeadline(0), "still inside the mutable-weight window");
        assertEq(vp.rewardBaseWad(), 0, "SPEC 9: a full exit zeroes the standing base");
        assertEq(p.weightOf(0, address(vp)), 0, "and the pool-side claim with it");
        (,,, uint256 totalAfter) = p.intervalInfo(0);
        assertEq(
            totalAfter,
            p.weightOf(0, address(handler.vMax())),
            "totalWeight fell by exactly the forfeited weight"
        );
        assertFalse(handler.weightSurvivedFullExit(), "no in-window claim survived");
    }

    /// The claim half of the weight layer: two reporters share a real bucket and the sum of
    /// what they take never exceeds it (D2/D3).
    function test_claims_never_exceed_the_bucket() public {
        handler.advVenueMode(7);
        handler.crankPro(6);
        handler.crankMax(6);
        handler.movePrice(150); // x2.0: both vaults are in profit
        handler.crankPro(6);
        handler.crankMax(6);
        handler.advPoolDonation(0, type(uint64).max); // basket inventory to claim
        handler.warpToSettlementPoint(3);
        handler.crankPro(6);
        handler.crankMax(6);
        handler.settleVault(0); // settles BOTH vaults
        uint256 bucket = p.bucketOf(0, 0);
        assertGt(bucket, 0, "the checkpoint has a non-empty settlement bucket");
        (,,, uint256 total) = p.intervalInfo(0);
        assertGt(total, 0, "and non-zero reported weight to share it by");

        handler.warpPastReportDeadline(); // closes the report window and claims for both
        assertGt(handler.claimsObserved(), 0, "claims actually executed");
        assertLe(p.remainingOf(0, 0), bucket, "sum of nominal claims never exceeds the bucket");
        assertEq(
            p.liability(address(usdc)),
            p.accruing(0) + p.remainingOf(0, 0),
            "liability stayed exactly the claim inventory"
        );
        assertGe(
            usdc.balanceOf(address(p)),
            p.liability(address(usdc)) + p.escrowHeld(address(usdc)),
            "pool still covers liability + escrow"
        );
    }

    // ---------------------------------------------------------------- state invariants

    /// Pool custody rule: balance >= liability + escrowHeld, on every basket token. The
    /// legacy campaign asserts only the `liability` half, which a mis-attributed sleeve
    /// escrow (H-1) passes trivially.
    function invariant_pool_balance_covers_liability_and_escrow() public view {
        assertGe(
            usdc.balanceOf(address(p)),
            p.liability(address(usdc)) + p.escrowHeld(address(usdc)),
            "usdc: balance < liability + escrow"
        );
        assertGe(
            ubtc.balanceOf(address(p)),
            p.liability(address(ubtc)) + p.escrowHeld(address(ubtc)),
            "ubtc: balance < liability + escrow"
        );
    }

    /// D2/D4 conservation: recorded liability is EXACTLY the claim inventory that still has
    /// a drain path — accruing plus every interval's unclaimed remainder. A capture that
    /// booked liability without inventory (or a claim that decremented one and not the
    /// other) shows up here and nowhere else.
    function invariant_liability_is_exactly_claim_inventory() public view {
        uint256 n = p.intervalCount();
        for (uint256 i = 0; i < 2; i++) {
            uint256 sum = p.accruing(i);
            for (uint256 id = 0; id < n; id++) {
                sum += p.remainingOf(id, i);
            }
            assertEq(
                p.liability(i == 0 ? address(usdc) : address(ubtc)),
                sum,
                "liability != claim inventory"
            );
        }
    }

    /// H-1: every escrowed token is committed to exactly one (policy, direction) slot.
    function invariant_escrow_slots_sum_to_escrow_held() public view {
        for (uint256 i = 0; i < 2; i++) {
            uint256 sum;
            for (uint8 policy = 1; policy <= 4; policy++) {
                sum += p.penaltyEscrow(policy, DIR, i);
            }
            assertEq(
                p.escrowHeld(i == 0 ? address(usdc) : address(ubtc)),
                sum,
                "escrowHeld != sum of policy escrow slots"
            );
        }
    }

    /// The weight layer C-1 attacked, asserted as a closed ledger:
    ///   * `totalWeight` is exactly the sum of the registered reporters' weights — no third
    ///     party, and no leftover after a `scaleWeight`. Because `claimFor` computes
    ///     nominal = bucket·w/totalWeight AT CLAIM TIME, this identity is what bounds
    ///     Σ nominal by the bucket independently of the per-claim `remaining` clamp;
    ///   * a pool-owned sleeve never holds weight (it is registered as a sleeve, never as a
    ///     vault, so its realised value returns to the basket before weights are used);
    ///   * `remaining <= bucket` on every asset: claims never exceed what was materialized.
    function invariant_weight_ledger_is_closed() public view {
        uint256 n = p.intervalCount();
        for (uint256 id = 0; id < n; id++) {
            (,,, uint256 total) = p.intervalInfo(id);
            uint256 sum = p.weightOf(id, address(v[0])) + p.weightOf(id, address(v[1]));
            assertEq(sum, total, "totalWeight != sum of reported participant weights");
            for (uint256 s = 2; s < 6; s++) {
                assertEq(p.weightOf(id, address(v[s])), 0, "a sleeve reported weight");
            }
            for (uint256 i = 0; i < 2; i++) {
                assertLe(
                    p.remainingOf(id, i), p.bucketOf(id, i), "sum of claims exceeds the bucket"
                );
            }
        }
    }

    /// Invariants 3/4/5/6/17: recorded books never exceed real assets on any custody side,
    /// for the user vaults AND the four pool-owned sleeves.
    function invariant_books_never_exceed_assets() public view {
        for (uint256 i = 0; i < 6; i++) {
            _checkBooks(v[i]);
        }
    }

    function _checkBooks(B4Vault vault) internal view {
        if (intentKindOf(vault) != B4VaultStorage.IntentKind.None) return;
        address a = address(vault);
        assertGe(ubtc.balanceOf(a), vault.dirEvm(), "dir EVM phantom");
        assertGe(
            usdc.balanceOf(a), vault.usdcRotatedEvm() + vault.usdcMarginEvm(), "usdc EVM phantom"
        );
        assertGe(hub.spotBal(a, UBTC_CORE), vault.coreDirWei(), "dir core phantom");
        assertGe(
            hub.spotBal(a, USDC_CORE),
            uint256(vault.coreUsdcRotatedWei()) + vault.coreUsdcMarginWei(),
            "usdc core phantom"
        );
        // Recorded perp margin may exceed live withdrawable only by REAL venue losses
        // (realized trading loss, adversarial drain, liquidation haircut) that reconcile at
        // the next flat valuation (B2) — never by protocol action minting phantom margin.
        assertGe(
            uint256(hub.wd(a)) + handler.wdDrained(a) + hub.realizedLoss6(a),
            vault.perpMargin6(),
            "perp phantom margin"
        );
    }

    // ---------------------------------------------------------------- ghost invariants

    /// Invariant 18 / H3, FREEZE half: the permissionless crank never reverts.
    function invariant_crank_never_reverts() public view {
        assertFalse(handler.unexpectedCrankRevert());
    }

    /// Invariant 18, LOSS half — the half a revert proxy cannot reach: a permissionless
    /// crank on a vault with no exit pending must never pay owner, operator, referrer or
    /// pool. Liveness callers move value between custody sides; they never move it out.
    function invariant_crank_never_pays_out() public view {
        assertFalse(handler.crankPaidOut());
    }

    function invariant_pool_advance_never_reverts() public view {
        assertFalse(handler.poolAdvanceReverted());
    }

    /// Invariant 12: a policy change never invokes exit or penalty logic.
    function invariant_policy_never_moves_funds() public view {
        assertFalse(handler.policyMovedFunds());
    }

    /// C-1 half A: reported weight never exceeds the client share of MEASURED interval
    /// profit, recomputed independently from (nav, entryLedger, operatorBps) at settle time.
    function invariant_weight_never_exceeds_measured_client_share() public view {
        assertFalse(handler.weightExceededLegitimate());
    }

    /// The pool records exactly the base the vault holds — no drift between the two ledgers.
    function invariant_reported_weight_matches_vault_base() public view {
        assertFalse(handler.reportedWeightMismatch());
    }

    /// C-1 half B / `B4Pool.scaleWeight`: a fully-exited vault holds no in-window weight.
    function invariant_full_exit_holds_no_weight() public view {
        assertFalse(handler.weightSurvivedFullExit());
    }

    /// B4: the entry ledger is never credited for capital that was not present — a crank
    /// cannot raise it, and a deposit raises it by exactly the measured receipt's value.
    function invariant_entry_ledger_never_grows_on_a_crank() public view {
        assertFalse(handler.entryLedgerGrewOnCrank());
    }

    function invariant_deposit_credits_exactly_measured_value() public view {
        assertFalse(handler.depositLedgerMismatch());
    }

    /// H-3: no directional cost basis is ever booked against a zero price read.
    function invariant_no_cost_basis_at_zero_price() public view {
        assertFalse(handler.zeroPxDepositAccepted());
    }
}
