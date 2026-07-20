// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VenueTestBase} from "../utils/VenueTestBase.sol";
import {EngineHarness} from "../utils/EngineHarness.sol";
import {MockLzEndpoint} from "../mocks/MockLzEndpoint.sol";
import {HalvingOracle} from "src/core/HalvingOracle.sol";
import {B4VaultStorage} from "src/core/B4VaultStorage.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";

/// @notice TEST_PLAN §2 regressions 1, 2, 7 — the exact async traps that survived audit
///         rounds in the earlier build — plus per-leg completion proofs (A7/A8/A11).
contract AsyncEngineTest is VenueTestBase {
    EngineHarness h;
    HalvingOracle oracle;

    uint256 constant HOUR = 1 hours;

    function setUp() public {
        vm.warp(1_713_571_767 + 100 days);
        setUpVenue();
        oracle = new HalvingOracle(
            address(new MockLzEndpoint()),
            1,
            bytes32(uint256(1)),
            840_000,
            1_713_571_767,
            address(this)
        );
        h = new EngineHarness();
        h.setup(ubtcDescriptor(), usdcDescriptor(), address(oracle));
        hub.setUserExists(address(h), true);
        hub.setAuto(false, true, true); // manual action execution: full async control
    }

    function kind() internal view returns (B4VaultStorage.IntentKind) {
        return h.intentKind();
    }

    // =====================================================================
    // Regression 1 (A2): completion keys on the RELIABLE balance only.
    // =====================================================================

    /// perp→spot release completes while the perp withdrawable drifts adversely or is
    /// externally topped up — it must not freeze. The completion proof is the Core-spot
    /// net-increase, never the withdrawable.
    function test_R1_fromPerp_completes_under_withdrawable_drift() public {
        hub.setWithdrawable(address(h), 500e6);
        h.setBuckets(0, 0, 0, 0, 0, 0, 500e6);
        h.startFromPerp(B4VaultStorage.Purpose.Margin, 500e6);
        hub.executeActions(); // spot +500e8, wd → 0

        // Adverse drift + external top-up of the UNRELIABLE balance after execution.
        hub.setWithdrawable(address(h), 3); // PnL-style drift
        assertTrue(h.verify()); // completes despite wd garbage
        assertEq(h.perpMargin6(), 0);
        assertEq(h.coreUsdcMarginWei(), 500e8);
        assertEq(uint8(kind()), uint8(B4VaultStorage.IntentKind.None));
    }

    /// Fuzz: NO withdrawable value can change the completion verdict (the fail-before
    /// implementation keyed on wd and froze under drift).
    function testFuzz_R1_fromPerp_completion_ignores_withdrawable(uint64 wdNoise) public {
        hub.setWithdrawable(address(h), 500e6);
        h.setBuckets(0, 0, 0, 0, 0, 0, 500e6);
        h.startFromPerp(B4VaultStorage.Purpose.Margin, 500e6);
        hub.executeActions();
        hub.setWithdrawable(address(h), wdNoise);
        assertTrue(h.verify());
        assertEq(h.coreUsdcMarginWei(), 500e8);
    }

    /// spot→perp completes on a spot net-decrease despite a small external spot top-up.
    function test_R1_toPerp_completes_despite_small_topUp() public {
        hub.coreTopUp(address(h), USDC_CORE, 1_000e8);
        h.setBuckets(0, 0, 0, 0, 0, 1_000e8, 0);
        h.startToPerp(400e6); // snap = 1000e8
        hub.coreTopUp(address(h), USDC_CORE, 50e8); // attacker adds mid-flight
        hub.executeActions(); // −400e8 ⇒ 650e8 < snap: net decrease
        assertTrue(h.verify());
        assertEq(h.perpMargin6(), 400e6);
        assertEq(h.coreUsdcMarginWei(), 600e8);
        // Books ≤ actual: the 50e8 top-up is unaccounted surplus.
        assertGe(hub.spotBal(address(h), USDC_CORE), h.coreUsdcMarginWei());
    }

    /// spot→EVM completes on net-decrease + full EVM receipt despite a small top-up.
    function test_R1_return_completes_despite_small_topUp() public {
        hub.coreTopUp(address(h), USDC_CORE, 500e8);
        h.setBuckets(0, 0, 0, 0, 500e8, 0, 0);
        h.startReturn(false, B4VaultStorage.Purpose.Generic, 300e8);
        hub.coreTopUp(address(h), USDC_CORE, 20e8);
        hub.executeActions(); // debit + deliver
        assertTrue(h.verify());
        assertEq(h.usdcRotatedEvm(), 300e6);
        assertEq(h.coreUsdcRotatedWei(), 200e8);
    }

    // =====================================================================
    // Regression 2 (A3): resend is the EXACT complement of completion.
    // =====================================================================

    /// A sub-amount external top-up MUST NOT block the resend of a genuinely dropped
    /// transfer. (The fail-before gate "source unchanged" froze forever here.)
    function test_R2_subAmount_topUp_does_not_block_resend() public {
        hub.coreTopUp(address(h), USDC_CORE, 1_000e8);
        h.setBuckets(0, 0, 0, 0, 0, 1_000e8, 0);
        hub.setDropNext(1);
        h.startToPerp(400e6);
        hub.executeActions(); // dropped: no effect

        hub.coreTopUp(address(h), USDC_CORE, 50e8); // perturbation: balance ≠ snapshot
        assertFalse(h.verify()); // not complete, not yet resendable
        vm.warp(block.timestamp + HOUR);
        assertTrue(h.verify()); // resend fires despite the perturbation
        hub.executeActions();
        assertTrue(h.verify()); // net decrease vs original snapshot ⇒ complete
        assertEq(h.perpMargin6(), 400e6);
        assertGe(hub.spotBal(address(h), USDC_CORE), h.coreUsdcMarginWei());
    }

    /// A merely delayed action MUST NOT be double-applied: no resend before the timeout,
    /// and a single completion afterward.
    function test_R2_delayed_action_not_doubleApplied() public {
        hub.coreTopUp(address(h), USDC_CORE, 1_000e8);
        h.setBuckets(0, 0, 0, 0, 0, 1_000e8, 0);
        h.startToPerp(400e6);
        assertEq(hub.pendingActions(), 1); // queued, not yet executed

        vm.warp(block.timestamp + HOUR - 1);
        assertFalse(h.verify()); // before timeout: wait, no resend
        assertEq(hub.pendingActions(), 1); // nothing re-emitted

        hub.executeActions();
        assertTrue(h.verify());
        assertEq(h.perpMargin6(), 400e6); // credited exactly once
        assertFalse(h.verify()); // idle: nothing further to apply
        assertEq(h.perpMargin6(), 400e6);
    }

    /// Same complement discipline on the perp→spot side: a dropped release resends after
    /// the timeout with an A4 re-clamp, and a drained withdrawable can never freeze it.
    function test_R2_fromPerp_dropped_resend_reclamps() public {
        hub.setWithdrawable(address(h), 500e6);
        h.setBuckets(0, 0, 0, 0, 0, 0, 500e6);
        hub.setDropNext(1);
        h.startFromPerp(B4VaultStorage.Purpose.Margin, 500e6);
        hub.executeActions(); // dropped

        // Venue now reports less margin available (drift while in flight).
        hub.setWithdrawable(address(h), 200e6);
        vm.warp(block.timestamp + HOUR);
        assertTrue(h.verify()); // resend re-clamped to 200e6
        assertEq(h.intentAmount(), 200e6);
        hub.executeActions();
        assertTrue(h.verify());
        assertEq(h.coreUsdcMarginWei(), 200e8);
        assertEq(h.perpMargin6(), 300e6); // unreturned principal still recorded on perp
    }

    // =====================================================================
    // Regression 7 (A11): external top-up == amount and > amount.
    // =====================================================================

    /// Source-side mask, top-up EXACTLY == amount: each resend is attacker-funded; the
    /// machine progresses, never over-credits, and books stay ≤ real assets.
    function test_R7_source_topUp_equal_amount() public {
        hub.coreTopUp(address(h), USDC_CORE, 1_000e8);
        h.setBuckets(0, 0, 0, 0, 0, 1_000e8, 0);
        hub.setDropNext(1);
        h.startToPerp(400e6);
        hub.executeActions(); // dropped
        hub.coreTopUp(address(h), USDC_CORE, 400e8); // == amount: masks one full send

        vm.warp(block.timestamp + HOUR);
        assertTrue(h.verify()); // resend #1 (attacker-funded)
        hub.executeActions(); // balance back to exactly the snapshot: still no net decrease
        assertFalse(h.verify());
        vm.warp(block.timestamp + HOUR);
        assertTrue(h.verify()); // resend #2
        hub.executeActions(); // now a genuine net decrease
        assertTrue(h.verify());

        // Credited exactly once; perp holds 800e6 real vs 400e6 recorded — the attacker's
        // 400 is OUR recoverable surplus; spot books equal actual.
        assertEq(h.perpMargin6(), 400e6);
        assertEq(hub.wd(address(h)), 800e6);
        assertEq(hub.spotBal(address(h), USDC_CORE), 600e8);
        assertEq(h.coreUsdcMarginWei(), 600e8);
    }

    /// Destination-side fake, top-up ≥ amount: completion fires once (attacker-funded),
    /// credit is capped at the intended amount (never an over-credit), and the stranded
    /// principal becomes recoverable perp surplus. Non-freeze, non-theft.
    function test_R7_destination_topUp_fakes_completion_once_benign() public {
        hub.setWithdrawable(address(h), 500e6);
        h.setBuckets(0, 0, 0, 0, 0, 0, 500e6);
        hub.setDropNext(1);
        h.startFromPerp(B4VaultStorage.Purpose.Margin, 500e6);
        hub.executeActions(); // dropped: perp still holds the 500

        hub.coreTopUp(address(h), USDC_CORE, 600e8); // > amount fake
        assertTrue(h.verify()); // faked completion (the documented A11 residual)

        // Cap: credited exactly 500e8, not 600e8 (A11: never over-credit).
        assertEq(h.coreUsdcMarginWei(), 500e8);
        assertEq(h.perpMargin6(), 0);
        // Real assets ≥ books on every side; the 500e6 still on the perp and the 100e8
        // spot excess are recoverable surplus.
        assertEq(hub.wd(address(h)), 500e6);
        assertGe(hub.spotBal(address(h), USDC_CORE), h.coreUsdcMarginWei());
    }

    /// EVM→Core funding: a concurrent top-up can only accelerate the threshold, and the
    /// credit is capped at the intended amount (excess stays unaccounted).
    function test_R7_fund_credit_capped() public {
        hub.setAuto(false, false, true); // hold credits too
        usdc.mint(address(h), 400e6);
        h.setBuckets(0, 0, 400e6, 0, 0, 0, 0);
        h.startFund(false, B4VaultStorage.Purpose.Margin, 400e6);
        assertEq(h.usdcMarginEvm(), 0); // removed from accounting at send (SPEC §7)

        hub.coreTopUp(address(h), USDC_CORE, 300e8); // attacker races the bridge
        hub.applyCredits(); // bridge credit lands: +400e8
        assertTrue(h.verify());
        assertEq(h.coreUsdcMarginWei(), 400e8); // capped: attacker's 300e8 not absorbed
        assertGe(hub.spotBal(address(h), USDC_CORE), h.coreUsdcMarginWei());
    }

    // =====================================================================
    // A7: debit-then-deliver — never resend once the source decreased.
    // =====================================================================

    function test_A7_return_never_resends_after_debit() public {
        hub.setAuto(false, true, false); // hold EVM deliveries
        hub.coreTopUp(address(h), USDC_CORE, 500e8);
        h.setBuckets(0, 0, 0, 0, 500e8, 0, 0);
        h.startReturn(false, B4VaultStorage.Purpose.Generic, 300e8);
        hub.executeActions(); // debited on Core; delivery in flight

        vm.warp(block.timestamp + 10 * HOUR); // far past any timeout
        assertFalse(h.verify()); // waiting for delivery — NOT resending
        assertEq(hub.pendingActions(), 0); // nothing was re-emitted

        hub.deliverEvm();
        assertTrue(h.verify());
        assertEq(h.usdcRotatedEvm(), 300e6);
    }

    // =====================================================================
    // A8: EVM→Core deposits are polled, never re-emitted, never abandoned.
    // =====================================================================

    function test_A8_fund_pollOnly_no_timeout_no_abandon() public {
        hub.setAuto(false, false, true); // credits frozen: simulated bridge outage
        usdc.mint(address(h), 400e6);
        h.setBuckets(0, 0, 400e6, 0, 0, 0, 0);
        h.startFund(false, B4VaultStorage.Purpose.Margin, 400e6);

        vm.warp(block.timestamp + 30 days);
        assertFalse(h.verify()); // still polling: no resend, no discard
        assertEq(uint8(kind()), uint8(B4VaultStorage.IntentKind.FundUsdc));
        assertEq(hub.pendingActions(), 0);

        hub.applyCredits(); // bridge recovers
        assertTrue(h.verify());
        assertEq(h.coreUsdcMarginWei(), 400e8);
    }

    /// A9: the fresh-account activation fee is tolerated on the first credit.
    function test_A9_first_credit_tolerates_activation_fee() public {
        hub.setUserExists(address(h), false);
        hub.setActivationFee(USDC_CORE, 1e8); // $1 fee
        usdc.mint(address(h), 400e6);
        h.setBuckets(0, 0, 400e6, 0, 0, 0, 0);
        h.startFund(false, B4VaultStorage.Purpose.Margin, 400e6);
        // Credit arrives short by the fee; completion tolerates it (threshold − allowance)
        // and credits only the measured delta.
        assertTrue(h.verify());
        assertEq(h.coreUsdcMarginWei(), 400e8 - 1e8);
        assertGe(hub.spotBal(address(h), USDC_CORE), h.coreUsdcMarginWei());
    }

    // =====================================================================
    // Spot order: measured deltas, envelope caps, favorable overfill unaccounted.
    // =====================================================================

    function test_spotOrder_partialFill_measured() public {
        hub.setAuto(true, true, true);
        hub.coreTopUp(address(h), UBTC_CORE, 1e8);
        h.setBuckets(0, 0, 0, 1e8, 0, 0, 0);
        hub.setFillRatio(CoreTypes.SPOT_ASSET_OFFSET + SPOT_MKT, 4000); // 40% fill
        h.startSpotOrder(false, 1e8); // sell 1 BTC
        assertTrue(h.verify());
        // 40% filled: 0.4 BTC sold for 40,000 USDC; the rest stays recorded on Core.
        assertEq(h.coreDirWei(), 6e7);
        assertEq(h.coreUsdcRotatedWei(), 40_000e8);
    }

    function test_spotOrder_favorable_overfill_stays_unaccounted() public {
        hub.setAuto(true, true, true);
        hub.coreTopUp(address(h), UBTC_CORE, 5e7);
        h.setBuckets(0, 0, 0, 5e7, 0, 0, 0);
        // Venue executes at $110k — better than the $100k snapshot for a seller.
        hub.setExecPx(CoreTypes.SPOT_ASSET_OFFSET + SPOT_MKT, 110_000e4);
        h.startSpotOrder(false, 5e7); // sell 0.5 BTC
        assertTrue(h.verify());
        // Credit capped at measured input × snapshot price: 0.5 × 100k = 50k.
        assertEq(h.coreUsdcRotatedWei(), 50_000e8);
        // The favorable 5k stays on Core as unaccounted, recoverable surplus.
        assertEq(hub.spotBal(address(h), USDC_CORE), 55_000e8);
    }

    function test_spotOrder_noFill_clears_after_timeout() public {
        hub.setAuto(true, true, true);
        hub.coreTopUp(address(h), UBTC_CORE, 1e8);
        h.setBuckets(0, 0, 0, 1e8, 0, 0, 0);
        hub.setFillRatio(CoreTypes.SPOT_ASSET_OFFSET + SPOT_MKT, 0); // no liquidity
        h.startSpotOrder(false, 1e8);
        assertFalse(h.verify()); // could still be a delayed fill: wait
        vm.warp(block.timestamp + HOUR);
        assertTrue(h.verify()); // declared no-fill; intent cleared, nothing accounted
        assertEq(uint8(kind()), uint8(B4VaultStorage.IntentKind.None));
        assertEq(h.coreDirWei(), 1e8);
        assertEq(h.coreUsdcRotatedWei(), 0);
    }
}
