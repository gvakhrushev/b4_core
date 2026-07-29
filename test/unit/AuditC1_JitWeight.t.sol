// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {B4VaultStorage} from "src/core/B4VaultStorage.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {Phi} from "src/libraries/Phi.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";
import {B4Pool} from "src/core/B4Pool.sol";

/// @notice Regression for AUDIT-2026-07-25 C-1 — just-in-time checkpoint weight.
///
/// `opsSettle` used to value the vault's CURRENT composition at the interval's LOCKED
/// checkpoint price. Since `_navWad` reads composition at call time, every composition
/// change inside the ≤3-day report window was measured against a stale reference and the
/// gap read as interval profit that no capital earned — `FEE_F` of it minting a pro-rata
/// claim on the shared basket. The original exploit in this file took $833,333 of a
/// $1,000,000 basket for $676.
///
/// The fix is on the VALUATION side, not the deposit side: NAV and the entry ledger are
/// always taken on the same basis. A deposit-side rule cannot work, because
/// `Calendar.targetAt` is exactly 0 at the settlement point and ramps immediately after, so
/// the calendar itself forces the permissionless crank to change composition inside that
/// same window — which is what tests 2 and 3 below pin down.
///
/// Every test here MUST crank between the deposit and the settle. A version of these tests
/// that skips the crank passes while the exploit is live.
contract AuditC1_JitWeightTest is VaultTestBase {
    function setUp() public {
        setUpProtocol();
    }

    function _p1() internal pure returns (uint256) {
        return GENESIS_TS + Calendar.P - Calendar.H;
    }

    /// Sets up an honest vault that held 1 BTC across a real 100k → 110k move, a
    /// $1,000,000 basket, and a materialized+locked interval. Returns the interval id and
    /// the honest vault's earned weight.
    function _honestInterval() internal returns (uint256 id, uint256 wHonest) {
        B4Vault honest = createVault(address(mini));
        fundAndDeposit(honest, 1e8, 0);
        crankUntilIdle(honest, 20);

        hub.setSpotPx(SPOT_MKT, 110_000 * 1e4);
        usdc.mint(address(pool), 1_000_000e6);
        pool.capture();

        vm.warp(_p1());
        pool.advance();
        id = pool.intervalCount() - 1;
        pool.lockPrices(id);
        honest.settle(id);
        wHonest = pool.weightOf(id, address(honest));
        assertGt(wHonest, 0, "honest vault earned real weight");
    }

    // ---------------------------------------------------------------- the original C-1

    /// The committed exploit, inverted. A clone created after the checkpoint deposits BTC
    /// at a live price far below the locked one and settles the same interval. It now
    /// measures its own real P&L — zero — instead of the gap to a stale reference.
    function test_C1_post_lock_directional_deposit_mints_no_weight() public {
        (uint256 id, uint256 wHonest) = _honestInterval();

        hub.setSpotPx(SPOT_MKT, 60_000 * 1e4);
        B4Vault attacker = createVault(address(mini));
        fundAndDeposit(attacker, 1e8, 0);
        crankUntilIdle(attacker, 50);
        assertEq(attacker.entryLedgerWad(), 60_000e18, "basis is what was actually paid");

        attacker.settle(id);
        assertEq(pool.weightOf(id, address(attacker)), 0, "zero exposure earns zero weight");

        // With no weight there is nothing to claim at all — the basket stays with the
        // honest vault, whose claim is undiluted.
        vm.warp(pool.reportDeadline(id) + 1);
        vm.expectRevert(B4Pool.NothingToClaim.selector);
        pool.claimFor(id, address(attacker));
        assertGt(wHonest, 0);
    }

    // ---------------------------------------------------- the USDC leg (critic probe P-1)

    /// USDC is neutral only while it STAYS USDC. It lands in the rotation bucket, which
    /// `_strategyValueWad` counts, so the permissionless crank buys the directional asset
    /// at the live price — and the old rule then valued those tokens at the locked price.
    /// This is why "the phantom vector is the directional leg only" was wrong.
    function test_C1_usdc_deposit_then_crank_rotation_mints_no_weight() public {
        (uint256 id, uint256 wHonest) = _honestInterval();

        hub.setSpotPx(SPOT_MKT, 60_000 * 1e4);
        B4Vault attacker = createVault(address(mini));
        fundAndDeposit(attacker, 0, 60_000e6); // USDC only
        assertEq(attacker.entryLedgerWad(), 60_000e18, "USDC books at a fixed 1 USD");

        crankUntilIdle(attacker, 50); // rotates into BTC at the live 60k
        assertGt(attacker.dirEvm(), 0, "the crank really did buy the directional asset");

        attacker.settle(id);
        assertEq(pool.weightOf(id, address(attacker)), 0, "rotation earns no phantom weight");
        assertGt(wHonest, 0);
    }

    // ------------------------------------------- settle/exit basis agreement (probe P-3)

    /// `_finalizeExit` values NAV at the live price (decision C2). Any settle-side rule that
    /// used a different basis handed a depositor an instantly realisable gap, and because
    /// the whole report window sits inside a free-exit zone, a deposit → free partial exit →
    /// re-deposit loop harvested it for gas. Both sides must share one basis.
    function test_C1_deposit_free_exit_loop_mints_no_weight() public {
        (uint256 id,) = _honestInterval();
        hub.setSpotPx(SPOT_MKT, 100_000 * 1e4);

        // Zero-fee route: the loop's only possible cost is the operator cut, so at 0 bps a
        // surviving gap would be free money.
        vm.prank(user);
        B4Vault a = B4Vault(
            factory.createVault(
                address(pool),
                CoreTypes.descriptorHash(ubtcDescriptor()),
                address(mini),
                1e18,
                100,
                B4VaultStorage.FeeRoute(address(0), 0, address(0), 0)
            )
        );

        hub.setSpotPx(SPOT_MKT, 110_000 * 1e4);
        ubtc.mint(user, 1e8);
        uint256 btcStart = ubtc.balanceOf(user);
        for (uint256 i = 0; i < 12; i++) {
            uint256 bal = ubtc.balanceOf(user);
            if (bal == 0) break;
            vm.startPrank(user);
            ubtc.approve(address(a), bal);
            a.deposit(bal, 0);
            a.initiateExit(Phi.WAD / 2); // free: the window is inside OpeningFall
            vm.stopPrank();
            crankUntilIdle(a, 10);
        }

        assertEq(a.rewardBaseWad(), 0, "no weight accrued from a zero-cost round trip");
        assertLe(ubtc.balanceOf(user) + a.dirEvm(), btcStart, "and no value was created");
        assertEq(pool.weightOf(id, address(a)), 0);
    }

    // ---------------------------------------------------------------- positive control

    /// The fix must not silence honest measurement: a vault that really held the asset
    /// across a real move still earns weight proportional to that move.
    function test_C1_real_holding_still_earns_weight() public {
        B4Vault v = createVault(address(mini));
        fundAndDeposit(v, 1e8, 0); // 1 BTC at 100k
        crankUntilIdle(v, 20);

        hub.setSpotPx(SPOT_MKT, 150_000 * 1e4); // a real +50k move while held
        vm.warp(_p1());
        pool.advance();
        uint256 id = pool.intervalCount() - 1;
        pool.lockPrices(id);
        v.settle(id);

        uint256 fee = Phi.wmul(50_000e18, Phi.FEE_F);
        assertEq(pool.weightOf(id, address(v)), fee - Phi.bps(fee, 3000), "real P&L, real weight");
    }
}
