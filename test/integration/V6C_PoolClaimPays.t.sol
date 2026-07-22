// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {B4Pool} from "src/core/B4Pool.sol";
import {Keeper} from "src/periphery/Keeper.sol";
import {Calendar} from "src/libraries/Calendar.sol";

/// @notice V6 Scope C — the missing F13 integration proof: a pool claim pays REAL value
///         to a real vault's owner, end to end (deposit → profit → settle → weight →
///         penalized exit funds the pool via capture → next point buckets it → claim).
///         Plus the V5-recorded keeper question: sweep-before-claim rolls value forward,
///         it does not lose it.
contract V6C_PoolClaimPaysTest is VaultTestBase {
    Keeper keeper;
    B4Vault v1; // stays in, earns weight, claims
    B4Vault v2; // exits with a penalty — funds the pool
    B4Vault v3; // second claimant (pro-rata + conservation)
    address[] vaults;

    function setUp() public {
        setUpProtocol();
        keeper = new Keeper();
        v1 = createVault(address(mini));
        v2 = createVault(address(mini));
        v3 = createVault(address(mini));
        vaults = [address(v1), address(v2), address(v3)];
        fundAndDeposit(v1, 1e8, 0);
        fundAndDeposit(v2, 1e8, 0);
        fundAndDeposit(v3, 1e8, 0);
    }

    function kcrank() internal {
        keeper.crank(pool, vaults, 20);
    }

    function pump() internal {
        hub.setSpotPx(SPOT_MKT, 120_000e4);
        hub.setMarkPx(PERP_MKT, 120_000e2);
        hub.setOraclePx(PERP_MKT, 120_000e2);
    }

    /// Drive to just after settlement point 1 (P−H): interval 0 materialized, locked,
    /// all three vaults settled with weight reported.
    function settleInterval0() internal {
        pump();
        warpTo(Calendar.P - Calendar.H + 10 minutes);
        kcrank();
        kcrank();
        kcrank();
        assertEq(pool.intervalCount(), 1);
        (, uint64 lockedAt,,) = pool.intervalInfo(0);
        assertGt(lockedAt, 0);
        assertGt(pool.weightOf(0, address(v1)), 0);
    }

    /// v2 fully exits OUTSIDE a free window (Fall zone) → in-kind penalty rides to the
    /// pool and is captured as measured inventory.
    function penalizedExitFundsPool() internal returns (uint256 penalty) {
        warpTo(Calendar.P + 1 days); // Fall: not a free-exit zone
        vm.prank(user);
        v2.initiateExit(1e18);
        for (uint256 i = 0; i < 8 && v2.exitShareWad() != 0; i++) {
            kcrank();
        }
        assertEq(v2.exitShareWad(), 0, "exit finalized");
        penalty = pool.accruing(1); // UBTC sits in the accruing basket
        assertGt(penalty, 0, "penalty captured into the pool");
        assertEq(pool.liability(address(ubtc)), penalty, "D2: liability == measured receipt");
        assertEq(ubtc.balanceOf(address(pool)), pool.liability(address(ubtc)), "books == balance");
    }

    /// Materialize + lock interval 1 (T+H); the accrued penalty becomes its bucket.
    function settleInterval1() internal {
        warpTo(Calendar.T + Calendar.H + 10 minutes);
        kcrank();
        kcrank();
        kcrank();
        assertEq(pool.intervalCount(), 2);
        (, uint64 lockedAt,,) = pool.intervalInfo(1);
        assertGt(lockedAt, 0);
        assertGt(pool.weightOf(1, address(v1)), 0, "v1 reported for interval 1");
        assertGt(pool.weightOf(1, address(v3)), 0, "v3 reported for interval 1");
    }

    // ------------------------------------------------------------------ F13

    /// F13: a pool claim pays real tokens to a real vault's fixed owner, pro-rata by
    /// reported weight, with bucket/remaining/liability conservation.
    function test_F13_claim_pays_owner_real_value() public {
        settleInterval0();
        uint256 penalty = penalizedExitFundsPool();
        settleInterval1();

        uint256 bucket = pool.bucketOf(1, 1);
        assertEq(bucket, penalty, "bucket == accrued penalty");
        uint256 w1 = pool.weightOf(1, address(v1));
        uint256 w3 = pool.weightOf(1, address(v3));
        assertEq(w1, w3, "identical Mini paths => identical cumulative weight");

        // Claims open only after the report window closes.
        warpTo(Calendar.T + Calendar.H + Calendar.SNAPSHOT_WINDOW + Calendar.REPORT_WINDOW + 1);
        uint256 ownerBefore = ubtc.balanceOf(user);
        uint256 v1Before = ubtc.balanceOf(address(v1));

        pool.claimFor(1, address(v1)); // permissionless
        uint256 mid = ubtc.balanceOf(user);
        pool.claimFor(1, address(v3));
        uint256 total = ubtc.balanceOf(user) - ownerBefore;

        uint256 n1 = pool.bucketOf(1, 1) * w1 / (w1 + w3); // expected nominal (floor)
        assertEq(mid - ownerBefore, n1, "v1 claim pays the OWNER exact pro-rata nominal");
        assertEq(ubtc.balanceOf(address(v1)), v1Before, "paid to owner, never the vault");
        assertTrue(pool.claimedOf(1, address(v1), 1) && pool.claimedOf(1, address(v3), 1));
        // Conservation: Σ claims ≤ bucket (≤1 wei flooring dust), and the pool's remaining
        // balance exactly equals outstanding liability (D-series discipline).
        assertGe(total, bucket - 1, "sum claims >= bucket - dust");
        assertLe(total, bucket, "sum claims <= bucket");
        assertEq(pool.remainingOf(1, 1), bucket - total, "remaining == unclaimed dust");
        assertEq(
            ubtc.balanceOf(address(pool)), pool.liability(address(ubtc)), "balance == liability"
        );
        // A second claim is a no-op (already claimed), not a revert, not a double-pay.
        pool.claimFor(1, address(v1));
        assertEq(ubtc.balanceOf(user) - ownerBefore, total, "no double claim");
    }

    // ------------------------------------------------- sweep rolls forward, never loses

    /// V5-recorded keeper question: interval 1 is swept (unclaimed) before its value is
    /// claimed — prove the value rolls into a later interval's bucket and is still paid.
    function test_sweep_rolls_value_forward_not_lost() public {
        settleInterval0();
        uint256 penalty = penalizedExitFundsPool();
        settleInterval1();
        uint256 bucket1 = pool.bucketOf(1, 1);
        assertEq(bucket1, penalty);
        uint256 liabBefore = pool.liability(address(ubtc));

        // Nobody claims interval 1. A late halving fact opens the next epoch; the next
        // keeper crank materializes interval 2 AND sweeps intervals 0 and 1 in the same
        // call (the exact recorded ordering: sweep(count−2) while claim targets count−1).
        uint32 ts2 = uint32(GENESIS_TS + 1_400 days);
        vm.warp(uint256(ts2) + 1);
        acceptHalving(GENESIS_HEIGHT + 210_000, ts2);
        warpTo(1_400 days + Calendar.P - Calendar.H + 1);
        kcrank();
        kcrank();

        (,, bool swept1,) = pool.intervalInfo(1);
        assertTrue(swept1, "interval 1 swept by the keeper");
        assertEq(pool.remainingOf(1, 1), 0, "inventory moved out");
        assertEq(pool.accruing(1), bucket1, "value rolled into accruing (D4)");
        assertEq(pool.liability(address(ubtc)), liabBefore, "liability unchanged by sweep");
        vm.expectRevert(B4Pool.NothingToClaim.selector);
        pool.claimFor(1, address(v1));

        // The next materialized point (epoch-1 T+H) buckets the rolled value; v1 (which
        // keeps settling) claims it there — value deferred, never destroyed.
        warpTo(1_400 days + Calendar.T + Calendar.H + 1);
        kcrank();
        kcrank();
        kcrank();
        assertEq(pool.intervalCount(), 4);
        uint256 bucket3 = pool.bucketOf(3, 1);
        assertEq(bucket3, bucket1, "rolled value re-bucketed intact");
        assertGt(pool.weightOf(3, address(v1)), 0, "v1 reported again");

        warpTo(
            1_400 days + Calendar.T + Calendar.H + Calendar.SNAPSHOT_WINDOW + Calendar.REPORT_WINDOW
                + 1
        );
        uint256 ownerBefore = ubtc.balanceOf(user);
        pool.claimFor(3, address(v1));
        pool.claimFor(3, address(v3));
        uint256 paid = ubtc.balanceOf(user) - ownerBefore;
        assertGe(paid, bucket1 - 1, "rolled value reaches owners");
        assertLe(paid, bucket1, "never more than rolled");
        assertEq(ubtc.balanceOf(address(pool)), pool.liability(address(ubtc)), "books sound at end");
    }
}
