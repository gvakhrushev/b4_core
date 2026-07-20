// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VenueTestBase} from "../utils/VenueTestBase.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {EngineHarness} from "../utils/EngineHarness.sol";
import {MockLzEndpoint} from "../mocks/MockLzEndpoint.sol";
import {HalvingOracle} from "src/core/HalvingOracle.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {B4VaultStorage} from "src/core/B4VaultStorage.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";

/// @notice V3-ENG-1 PoC — a first EVM→Core funding whose amount is ≤ the fresh-account
///         activation fee is consumed entirely by the fee (zero Core credit). The Fund
///         intent then polls forever: completion needs a non-zero measured delta, A8
///         forbids resend/abandon, and every escape hatch (exit machine, settle,
///         recovery, emergency clear) is gated on the pending intent. The protocol's own
///         planner reaches this state for small vaults: the first margin deficit has no
///         floor (marginNeed = notional·φ/maxLev can be < $1), unlike spot funds which
///         are floored by the $10 band.
contract V3EngActivationFreezeHarnessTest is VenueTestBase {
    EngineHarness h;
    HalvingOracle oracle;

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
        // NOTE: account deliberately NOT activated — fresh Core account (firstCredit).
    }

    function kind() internal view returns (B4VaultStorage.IntentKind) {
        return h.intentKind();
    }

    /// PASS-AFTER (V3-ENG-1 fix): a first fund the activation fee could consume entirely
    /// (weiAmount ≤ the allowance) is REFUSED at creation — no intent, no transfer, the
    /// funds stay accounted on EVM. The planner therefore never enters the poll-forever
    /// wedge; it just holds (H3 delayed liveness).
    function test_V3ENG1_firstFund_below_allowance_refused_not_wedged() public {
        hub.setActivationFee(USDC_CORE, 1e8); // $1 fee
        usdc.mint(address(h), 750_000); // $0.75 margin fund (7.5e7 wei ≤ $5 allowance)
        h.setBuckets(0, 0, 750_000, 0, 0, 0, 0);

        h.startFund(false, B4VaultStorage.Purpose.Margin, 750_000);
        assertEq(uint8(kind()), uint8(B4VaultStorage.IntentKind.None)); // no doomed intent
        assertEq(h.usdcMarginEvm(), 750_000); // funds untouched, still on EVM
        assertEq(hub.pendingActions(), 0); // nothing was ever emitted
    }

    /// Boundary: a fund at exactly the allowance is refused; one wei above it proceeds
    /// (the account activates and the fee — pinned ≤ allowance by the funded gate — leaves
    /// a non-zero measured credit).
    function test_V3ENG1_allowance_boundary() public {
        hub.setActivationFee(USDC_CORE, 5e7); // $0.50 fee ≤ $5 allowance (funded gate)
        uint64 allowance = 5e8; // $5 in 8-decimal wei
        // At the allowance: refused.
        usdc.mint(address(h), 5e6); // $5 = 5e8 wei == allowance
        h.setBuckets(0, 0, 5e6, 0, 0, 0, 0);
        h.startFund(false, B4VaultStorage.Purpose.Margin, 5e6);
        assertEq(uint8(kind()), uint8(B4VaultStorage.IntentKind.None));
        allowance;

        // Just above the allowance: proceeds and completes with the fee tolerated.
        usdc.mint(address(h), 5_000_001); // $5.000001 ⇒ 5e8+100 wei > allowance
        h.setBuckets(0, 0, 5_000_001, 0, 0, 0, 0);
        h.startFund(false, B4VaultStorage.Purpose.Margin, 5_000_001);
        assertEq(uint8(kind()), uint8(B4VaultStorage.IntentKind.FundUsdc));
        assertTrue(h.verify()); // credit = amount − $0.50 fee ≥ threshold ⇒ completes
        assertGt(h.coreUsdcMarginWei(), 0);
    }

    /// Funded-gate residual (documented): if the LIVE fee exceeds the $5 allowance, a
    /// first fund between the allowance and the fee still can't complete — SECURITY_MODEL
    /// §5.3 requires the deploy to pin the live fee ≤ the allowance. This test pins that
    /// requirement; an out-of-protocol top-up remains the only escape if it is violated.
    function test_V3ENG1_fee_above_allowance_is_a_funded_gate() public {
        hub.setActivationFee(USDC_CORE, 6e8); // $6 fee > $5 allowance (MISCONFIGURED deploy)
        usdc.mint(address(h), 10e6);
        h.setBuckets(0, 0, 10e6, 0, 0, 0, 0);
        h.startFund(false, B4VaultStorage.Purpose.Margin, 10e6); // $10 > allowance ⇒ created
        assertFalse(h.verify()); // credit $4 < threshold $5 — the §5.3 gate violation
        // Rescue via a Core top-up (the funded gate must prevent needing this).
        hub.coreTopUp(address(h), USDC_CORE, 1e8);
        assertTrue(h.verify());
    }
}

/// @notice End-to-end: the vault's own sync planner emits the doomed first margin fund.
contract V3EngActivationFreezeVaultTest is VaultTestBase {
    function setUp() public {
        setUpProtocol();
    }

    /// PASS-AFTER: the planner refuses the sub-allowance first margin fund instead of
    /// creating a doomed poll-forever intent. The vault stays fully operable (idle, no
    /// pending intent) — it just doesn't open the tiny perp until it grows — and the owner
    /// can exit and be paid without any out-of-protocol rescue.
    function test_V3ENG1_planner_refuses_tiny_first_margin_fund() public {
        hub.setActivationFee(USDC_CORE, 1e8); // $1 fresh-account fee (quote token, A9)
        B4Vault v = createVault(address(proMax)); // growth φ ⇒ perp leg +0.618 at t = 0
        fundAndDeposit(v, 30_000, 10e6); // $30 dir + $10 margin

        // Crank: spot in-band; the perp leg's ~$0.75 margin fund is REFUSED (≤ allowance),
        // so no intent is created and the crank simply reports no progress.
        assertFalse(v.crank());
        assertEq(uint8(intentKindOf(v)), uint8(B4VaultStorage.IntentKind.None), "idle, not wedged");
        assertEq(hub.pendingActions(), 0);
        assertEq(v.usdcMarginEvm(), 10e6, "margin untouched on EVM"); // nothing debited
        assertEq(v.dirEvm(), 30_000);

        // The vault is NOT bricked: the owner can exit right now and gets paid, no rescue.
        vm.prank(user);
        v.initiateExit(1e18);
        crankUntilIdle(v, 20);
        assertEq(v.exitShareWad(), 0, "exit finalized without any top-up");
        assertGt(usdc.balanceOf(user), 0, "owner paid USDC margin back");
        assertGt(ubtc.balanceOf(user), 0, "owner paid directional");
    }
}
