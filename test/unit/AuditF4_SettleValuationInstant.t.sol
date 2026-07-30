// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {B4VaultStorage} from "src/core/B4VaultStorage.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {Phi} from "src/libraries/Phi.sol";

/// @notice Regression for AUDIT-2026-07-29 F4 — a third party chose the VALUATION INSTANT for a
///         vault it did not own.
///
/// `settle` is permissionless and one-shot per interval, and since the C-1 remediation it valued
/// the vault at the price of the instant it ran — anywhere in the three-day report window. So an
/// attacker settled every OTHER vault in the pool at a local trough, pinning each victim's minted
/// weight at a minimum, and settled their own at a peak; the victims had no second attempt,
/// because `lastSettledPlusOne` had already advanced. The mitigation the `Calendar` docstring
/// records for `lockPrices` — "the harmed party can call it at `pointTime` and remove all
/// discretion" — did not transfer, because since C-1 the locked price feeds no valuation at all.
///
/// The valuation instant is now a separate, one-shot, permissionless act confined to the
/// settlement day, so the owner can pre-empt it. Reporting liveness is untouched: the weight
/// report still has until `reportDeadline`, and a keeper that settles inside the window still
/// makes exactly one call.
contract AuditF4_SettleValuationInstantTest is VaultTestBase {
    address constant FRONT_RUNNER = address(0xF4EEE);
    uint256 constant OPERATOR_BPS = 3000;

    function setUp() public {
        setUpProtocol();
    }

    function _pointTime() internal pure returns (uint256) {
        return GENESIS_TS + Calendar.P - Calendar.H;
    }

    function _vaultWithProfit() internal returns (B4Vault v) {
        v = createVault(address(mini));
        fundAndDeposit(v, 1e8, 0); // 1 BTC at 100k
        crankUntilIdle(v, 20);
    }

    function _openInterval() internal returns (uint256 id) {
        vm.warp(_pointTime());
        pool.advance();
        id = pool.intervalCount() - 1;
        pool.lockPrices(id);
    }

    /// The settlement identity, expressed against a KNOWN nav: `entryAfter = nav − operatorCut`
    /// and `rewardBase += virtualFee − operatorCut`. Asserting it against the snapshot nav is what
    /// makes these tests non-vacuous — had settle valued at the live price instead, `nav` would be
    /// a different number and both equalities would fail.
    function _assertSettledAgainst(B4Vault v, uint256 nav, uint256 entryBefore, uint256 basePre)
        internal
        view
    {
        uint256 profit = nav > entryBefore ? nav - entryBefore : 0;
        uint256 virtualFee = Phi.wmul(profit, Phi.FEE_F);
        uint256 operatorCut = Phi.bps(virtualFee, OPERATOR_BPS);
        assertEq(v.entryLedgerWad(), nav - operatorCut, "entry re-anchored on the snapshot nav");
        assertEq(
            v.rewardBaseWad(), basePre + (virtualFee - operatorCut), "client share from that nav"
        );
    }

    /// THE FIX. The owner takes the valuation instant at `pointTime`; a front-runner then settles
    /// the vault at a trough half a day later and gets nothing for it — the weight is minted at
    /// the pre-empted NAV, not at the price the front-runner chose.
    function test_F4_owner_can_preempt_the_valuation_instant() public {
        B4Vault v = _vaultWithProfit();
        hub.setSpotPx(SPOT_MKT, 130_000 * 1e4); // a real +30k of profit
        uint256 id = _openInterval();

        uint256 entryBefore = v.entryLedgerWad();
        uint256 basePre = v.rewardBaseWad();

        vm.prank(user);
        v.snapshotNav(id);
        uint256 pinned = v.settleNavWad();
        assertGt(pinned, entryBefore, "the owner pinned a NAV carrying real profit");
        assertEq(v.settleNavIdPlusOne(), id + 1, "for this interval");

        // The front-runner waits for a trough and settles someone else's vault.
        vm.warp(_pointTime() + 12 hours);
        hub.setSpotPx(SPOT_MKT, 70_000 * 1e4);
        vm.prank(FRONT_RUNNER);
        v.settle(id);

        _assertSettledAgainst(v, pinned, entryBefore, basePre);
        assertGt(pool.weightOf(id, address(v)), 0, "weight minted at the pinned NAV");
    }

    /// Without the pre-emption the front-runner still cannot reach outside the settlement day: the
    /// choosable span is one day, not the three the report window allows.
    function test_F4_valuation_instant_is_confined_to_the_settlement_day() public {
        B4Vault v = _vaultWithProfit();
        hub.setSpotPx(SPOT_MKT, 130_000 * 1e4);
        uint256 id = _openInterval();

        // Past the snapshot window, with nothing captured, the interval defers rather than
        // valuing at a price two days from the point.
        vm.warp(_pointTime() + Calendar.SNAPSHOT_WINDOW + 1);
        hub.setSpotPx(SPOT_MKT, 70_000 * 1e4);
        vm.prank(FRONT_RUNNER);
        vm.expectRevert(B4VaultStorage.NavNotSnapshotted.selector);
        v.settle(id);

        // And the snapshot itself cannot be taken late either.
        vm.prank(user);
        vm.expectRevert(B4VaultStorage.OutsideSnapshotWindow.selector);
        v.snapshotNav(id);
    }

    /// Reporting liveness is NOT narrowed: once the instant is captured, the weight report still
    /// has the full report window. This is the property that makes the one-day valuation window
    /// affordable.
    function test_F4_report_liveness_survives_the_narrowed_valuation_window() public {
        B4Vault v = _vaultWithProfit();
        hub.setSpotPx(SPOT_MKT, 130_000 * 1e4);
        uint256 id = _openInterval();

        uint256 entryBefore = v.entryLedgerWad();
        uint256 basePre = v.rewardBaseWad();

        vm.prank(user);
        v.snapshotNav(id);
        uint256 pinned = v.settleNavWad();

        // Two days later — past the snapshot window, still inside the report window.
        vm.warp(_pointTime() + Calendar.SNAPSHOT_WINDOW + 2 days);
        assertLe(block.timestamp, pool.reportDeadline(id), "still inside the report window");
        v.settle(id);

        _assertSettledAgainst(v, pinned, entryBefore, basePre);
        assertGt(pool.weightOf(id, address(v)), 0, "reported late, on the captured instant");
    }

    /// The ordinary keeper path is unchanged: one call, no snapshot needed, because settle takes
    /// the instant itself when it runs inside the settlement day.
    function test_F4_single_settle_call_still_works_inside_the_window() public {
        B4Vault v = _vaultWithProfit();
        hub.setSpotPx(SPOT_MKT, 130_000 * 1e4);
        uint256 id = _openInterval();

        v.settle(id); // no snapshotNav call at all
        assertEq(v.settleNavIdPlusOne(), id + 1, "settle captured it itself");
        assertGt(pool.weightOf(id, address(v)), 0, "and reported");
    }

    /// One-shot: the instant cannot be re-chosen once captured, by the owner or by anyone else.
    function test_F4_valuation_instant_is_one_shot() public {
        B4Vault v = _vaultWithProfit();
        hub.setSpotPx(SPOT_MKT, 130_000 * 1e4);
        uint256 id = _openInterval();

        vm.prank(user);
        v.snapshotNav(id);
        uint256 pinned = v.settleNavWad();

        vm.warp(_pointTime() + 6 hours);
        hub.setSpotPx(SPOT_MKT, 200_000 * 1e4);
        vm.prank(FRONT_RUNNER);
        vm.expectRevert(B4VaultStorage.AlreadySettled.selector);
        v.snapshotNav(id);

        vm.prank(user); // not even the owner may re-pick a better one
        vm.expectRevert(B4VaultStorage.AlreadySettled.selector);
        v.snapshotNav(id);
        assertEq(v.settleNavWad(), pinned, "the captured instant stands");
    }

    /// The in-kind operator cut is paid on the SAME basis the NAV was measured on. Paying it at
    /// the live price against a day-old NAV would re-create the C-1 mismatch in miniature: the
    /// fee value and the NAV it is a fraction of would come from different prices.
    function test_F4_in_kind_fee_uses_the_snapshot_basis() public {
        B4Vault v = _vaultWithProfit();
        hub.setSpotPx(SPOT_MKT, 130_000 * 1e4);
        uint256 id = _openInterval();

        uint256 entryBefore = v.entryLedgerWad();
        uint256 basePre = v.rewardBaseWad();

        vm.prank(user);
        v.snapshotNav(id);
        uint256 pinned = v.settleNavWad();

        // Price collapses before settle runs; the fee must still be the snapshot's fee.
        vm.warp(_pointTime() + 20 hours);
        hub.setSpotPx(SPOT_MKT, 60_000 * 1e4);
        v.settle(id);

        _assertSettledAgainst(v, pinned, entryBefore, basePre);
        assertGt(ubtc.balanceOf(operator) + ubtc.balanceOf(referrer), 0, "and it was paid in kind");
    }

    /// The EXIT-side residual of freezing the NAV, and the counterpart of the deposit-side raise
    /// audit A1 added. `settle` re-anchors `entryLedgerWad` from the frozen `settleNavWad`, and
    /// the settlement point sits inside a `freeExit` transition zone — so an exit between
    /// `snapshotNav` and `settle` is both reachable and penalty-free.
    ///
    /// Left stale, the snapshot still values the withdrawn share: `entryLedgerWad` scales by
    /// `keep` while the NAV does not, so the exited notional reads as profit. Pre-fix, a 50% exit
    /// at a 130k NAV over a 100k entry made settle measure 80k of profit where 15k was real —
    /// 5.3x — minting pool weight against a shared basket on capital the vault no longer held.
    function test_F4_exit_between_snapshot_and_settle_does_not_mint_on_withdrawn_capital() public {
        B4Vault v = _vaultWithProfit();
        hub.setSpotPx(SPOT_MKT, 130_000 * 1e4);
        uint256 id = _openInterval();

        uint256 entryBefore = v.entryLedgerWad();

        vm.prank(user);
        v.snapshotNav(id);
        uint256 pinned = v.settleNavWad();
        uint256 realProfit = pinned - entryBefore;

        // Exit half, inside the same settlement window — free, by calendar geometry.
        vm.prank(user);
        v.initiateExit(5e17);
        for (uint256 k = 0; k < 60 && v.exitShareWad() != 0; k++) {
            v.crank();
        }
        assertEq(v.exitShareWad(), 0, "the exit completed inside the window");

        uint256 scaled = v.settleNavWad();
        assertEq(scaled, Phi.wmul(pinned, 5e17), "the frozen NAV scaled by the same keep");

        // The exit itself already scaled the standing base and credited the exiting share's
        // client share, so settle's contribution is measured from where the exit left it.
        uint256 basePre = v.rewardBaseWad();
        uint256 entryAfterExit = v.entryLedgerWad();
        v.settle(id);

        // Settle must measure HALF the profit, not the profit of a position half of which left.
        _assertSettledAgainst(v, scaled, entryAfterExit, basePre);
        assertApproxEqRel(
            scaled - entryAfterExit, realProfit / 2, 0.01e18, "profit tracks what stayed"
        );
    }
}
