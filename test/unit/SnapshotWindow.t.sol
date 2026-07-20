// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {B4Pool} from "src/core/B4Pool.sol";
import {B4VaultStorage} from "src/core/B4VaultStorage.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {Phi} from "src/libraries/Phi.sol";

/// @notice The checkpoint snapshot window — its width, its boundaries, and (most
///         importantly) what missing it actually costs.
///
///         `SNAPSHOT_WINDOW` is the **settlement day**: the first 24h of the opening
///         half-transition, sitting between the closing leg `[P−W, P−H)` and the opening
///         leg `[P−H, P)`. The width is a deliberate liveness/discretion trade-off — a
///         one-hour window recurring once every ~1–1.5 years leaves no room for a human to
///         react to a dead cron, while a wider window gives a late caller more choice over
///         WHICH price becomes canonical. The discretion is bounded because the party
///         harmed by a high lock (the owner, who pays the fee) can lock at `pointTime`
///         themselves — `lockPrices` is permissionless.
///
///         The load-bearing property pinned here: **missing the window defers settlement,
///         it does not destroy the fee or the reward weight.**
contract SnapshotWindowTest is VaultTestBase {
    function setUp() public {
        setUpProtocol();
    }

    function p1() internal pure returns (uint256) {
        return Calendar.P - Calendar.H;
    }

    function p2() internal pure returns (uint256) {
        return Calendar.T + Calendar.H;
    }

    // --------------------------------------------------------------- window geometry

    /// The window is exactly the settlement day, and it is inclusive at both ends.
    function test_window_is_the_settlement_day() public {
        assertEq(Calendar.SNAPSHOT_WINDOW, 24 hours, "settlement day");
        // It opens AT the point and closes 24h later, entirely inside the 10-day opening
        // half-transition — so locking never spills into the next zone.
        assertLt(Calendar.SNAPSHOT_WINDOW, Calendar.H, "window fits inside the opening leg");
        // Report deadline trails the window, not the raw point.
        warpTo(p1());
        pool.advance();
        assertEq(
            pool.reportDeadline(0),
            GENESIS_TS + p1() + Calendar.SNAPSHOT_WINDOW + Calendar.REPORT_WINDOW
        );
    }

    /// Boundary sweep: before the point, at the point, at the last legal second, and one
    /// second past it.
    function test_window_boundaries_inclusive() public {
        warpTo(p1());
        pool.advance();

        warpTo(p1() - 1);
        vm.expectRevert(B4Pool.OutsideSnapshotWindow.selector);
        pool.lockPrices(0);

        warpTo(p1() + Calendar.SNAPSHOT_WINDOW + 1);
        vm.expectRevert(B4Pool.OutsideSnapshotWindow.selector);
        pool.lockPrices(0);

        // The far edge is legal — a keeper that reacts a full day late still succeeds.
        warpTo(p1() + Calendar.SNAPSHOT_WINDOW);
        pool.lockPrices(0);
        (, uint64 lockedAt,,) = pool.intervalInfo(0);
        assertEq(lockedAt, block.timestamp);
    }

    /// The whole point of widening: a lock ~a working day late still lands.
    function test_late_but_within_the_day_still_locks() public {
        warpTo(p1());
        pool.advance();
        warpTo(p1() + 18 hours); // cron died, a human noticed and ran it by hand
        pool.lockPrices(0);
        (bool ok, uint256 id) = pool.currentReportable();
        assertTrue(ok, "interval reportable after a late manual lock");
        assertEq(id, 0);
    }

    // ------------------------------------------- missing it DEFERS, never destroys

    /// A missed interval is not a burned interval. `opsSettle` may skip it, the entry
    /// ledger never re-anchored, so the next checkpoint measures profit over the COMBINED
    /// span and charges the fee on all of it. Reward weight accrues the same way.
    function test_missed_interval_defers_fee_and_weight_not_lost() public {
        B4Vault v = createVault(address(mini)); // Mini never trades: NAV is pure price
        fundAndDeposit(v, 1e8, 0); // entry = 100_000e18
        assertEq(v.entryLedgerWad(), 100_000e18);

        hub.setSpotPx(SPOT_MKT, 120_000e4); // +20% before the first checkpoint

        // Interval 0 materializes, but nobody locks in time.
        warpTo(p1());
        pool.advance();
        warpTo(p1() + Calendar.SNAPSHOT_WINDOW + 1);
        vm.expectRevert(B4Pool.OutsideSnapshotWindow.selector);
        pool.lockPrices(0);

        // Interval 0 can never be settled...
        vm.expectRevert(B4VaultStorage.NotSettleable.selector);
        v.settle(0);
        // ...and nothing has been charged or re-anchored.
        assertEq(v.entryLedgerWad(), 100_000e18, "entry untouched");
        assertEq(v.rewardBaseWad(), 0);
        assertEq(v.lastSettledPlusOne(), 0);

        // Next checkpoint: interval 1, same price.
        warpTo(p2());
        pool.advance();
        uint256 id1 = pool.intervalCount() - 1;
        pool.lockPrices(id1);
        v.settle(id1);

        // The fee was charged on the FULL 20k span — deferred, not forfeited.
        uint256 profit = 20_000e18;
        uint256 vf = Phi.wmul(profit, Phi.FEE_F);
        uint256 oc = Phi.bps(vf, 3000);
        assertEq(v.rewardBaseWad(), vf - oc, "client share for the whole span");
        assertEq(pool.weightOf(id1, address(v)), vf - oc, "weight reported, not lost");
        assertGt(ubtc.balanceOf(operator) + ubtc.balanceOf(referrer), 0, "operator got paid");
        assertEq(v.entryLedgerWad(), 120_000e18 - oc, "re-anchored only now");
        // Skipping is explicitly allowed: the ledger jumps past the missed interval.
        assertEq(v.lastSettledPlusOne(), id1 + 1);
    }

    /// Control: the same vault settling on time yields the same fee on the same span —
    /// the deferral changes WHEN it is charged, not WHETHER.
    function test_control_ontime_settle_charges_the_same_span() public {
        B4Vault v = createVault(address(mini));
        fundAndDeposit(v, 1e8, 0);
        hub.setSpotPx(SPOT_MKT, 120_000e4);

        warpTo(p1());
        pool.advance();
        pool.lockPrices(0); // locked promptly this time
        v.settle(0);

        uint256 vf = Phi.wmul(20_000e18, Phi.FEE_F);
        uint256 oc = Phi.bps(vf, 3000);
        assertEq(v.rewardBaseWad(), vf - oc);
        assertEq(v.entryLedgerWad(), 120_000e18 - oc);
    }

    /// Unclaimed pool inventory of a missed interval is not stranded either: it sweeps
    /// forward into the next basket once a later interval exists.
    function test_missed_interval_inventory_sweeps_forward() public {
        usdc.mint(address(pool), 1_000e6);
        pool.capture();

        warpTo(p1());
        pool.advance(); // interval 0 — never locked
        warpTo(p2());
        pool.advance(); // interval 1 exists, so interval 0 is sweepable
        uint256 id1 = pool.intervalCount() - 1;

        warpTo(p2() + Calendar.SNAPSHOT_WINDOW + Calendar.REPORT_WINDOW + 1);
        pool.sweep(0);
        assertEq(pool.remainingOf(0, 0), 0, "missed interval drained");
        assertGt(pool.liability(address(usdc)), 0, "inventory still owed, not burned");
        id1; // the swept inventory lands in the accruing basket for a later interval
    }
}
