// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {MockERC20} from "../mocks/MockCore.sol";
import {B4Pool} from "src/core/B4Pool.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {B4VaultStorage} from "src/core/B4VaultStorage.sol";
import {Keeper} from "src/periphery/Keeper.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {Phi} from "src/libraries/Phi.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";

/// @notice Minimal pool vault for the MAX_DIRECTIONAL cycle (the invariant-audit PoC
///         acts as its own factory, mirroring B4Pool.t.sol).
contract V3MockVault {
    address public owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function report(B4Pool pool, uint256 id, uint256 weight) external {
        pool.reportWeight(id, weight);
    }
}

/// @title V3Cov — verification-audit PoCs for scenarios the suite CLAIMS or SHOULD
///        cover but does not pin anywhere (see audit report, coverage-gap section):
///        1. an exit penalty whose pool transfer DEFERS (pool blacklisted as token
///           recipient) — the deferred-payout × pool-capture × keeper heal chain;
///        2. two real vaults of one owner exiting the SAME pool in the SAME window
///           (concurrent in-flight exits, penalties captured interleaved);
///        3. a pool at the MAX_DIRECTIONAL cap through a full distribution cycle, and
///           the cap revert itself (INVARIANTS.md row 18 cites "pool bounded-asset
///           loops (MAX_DIRECTIONAL)" with no test ever building such a pool).
contract V3CovCoverageDemoTest is VaultTestBase {
    function setUp() public {
        setUpProtocol();
    }

    // =====================================================================
    // 1. Deferred POOL penalty: pay-or-defer covers the operator/referrer/owner
    //    recipients (DeferredPayout.t.sol) but never the POOL leg of an exit penalty.
    //    The penalty must stay accounted, heal via claimDeferred, and become pool
    //    inventory on the next capture — liveness only, never loss or freeze (H3).
    // =====================================================================
    function test_V3Cov_pool_penalty_deferral_heals_via_keeper() public {
        warpTo(100 days); // deep growth: deposits open, exits NOT free
        B4Vault v = createVault(address(mini));
        fundAndDeposit(v, 1e8, 0);
        hub.setSpotPx(SPOT_MKT, 110_000e4); // +10%

        // The pool is blacklisted as a UBTC recipient: the penalty leg defers.
        ubtc.setBlockedTo(address(pool), true);
        vm.prank(user);
        v.initiateExit(1e18);
        crankUntilIdle(v, 10);
        assertEq(v.exitShareWad(), 0); // exit completed — pay-or-defer, no freeze (H3)

        uint256 gross = 110_000e18;
        uint256 vf = Phi.wmul(10_000e18, Phi.FEE_F);
        uint256 ocx = Phi.bps(vf, 3000);
        uint256 poolWad = Phi.wmul(gross, Phi.EXIT_Q) - ocx;
        uint256 expectedPenalty = Phi.mulDiv(1e8, poolWad, gross);
        assertGt(expectedPenalty, 0);

        // The penalty is accounted as a deferred payout to the pool; it is NOT
        // inventory yet and the owner cannot sweep it as surplus (deferred exclusion).
        assertEq(v.deferredPayout(address(pool), address(ubtc)), expectedPenalty);
        assertEq(pool.liability(address(ubtc)), 0);
        assertEq(pool.accruing(1), 0);
        vm.prank(user);
        vm.expectRevert(B4VaultStorage.NothingToRecover.selector);
        v.recoverEvm(address(ubtc));

        // Heal: unblacklist; the keeper's crank retries the deferred payout (G2)…
        ubtc.setBlockedTo(address(pool), false);
        Keeper keeper = new Keeper();
        address[] memory vaults = new address[](1);
        vaults[0] = address(v);
        keeper.crank(pool, vaults, 5); // claimDeferred lands the tokens at the pool
        assertEq(v.deferredPayout(address(pool), address(ubtc)), 0);
        assertEq(pool.liability(address(ubtc)), 0); // not yet captured
        keeper.crank(pool, vaults, 5); // …and the next crank's capture() books it
        assertEq(pool.liability(address(ubtc)), expectedPenalty);
        assertEq(pool.accruing(1), expectedPenalty);
        assertGe(ubtc.balanceOf(address(pool)), pool.liability(address(ubtc)));
    }

    // =====================================================================
    // 2. Concurrent exits: two real vaults of one owner in the SAME pool initiate
    //    exits in the same window and are cranked interleaved to completion. The
    //    integration lifecycle only ever exits one vault at a time.
    // =====================================================================
    function test_V3Cov_concurrent_exits_same_pool_same_window() public {
        warpTo(100 days);
        B4Vault vMini = createVault(address(mini));
        B4Vault vB4 = createVault(address(b4));
        fundAndDeposit(vMini, 1e8, 0);
        fundAndDeposit(vB4, 1e8, 0);
        hub.setSpotPx(SPOT_MKT, 110_000e4);

        vm.startPrank(user);
        vMini.initiateExit(1e18);
        vB4.initiateExit(1e18); // both exits in flight simultaneously
        vm.stopPrank();

        // Interleaved cranks: neither vault's exit machinery may disturb the other.
        for (uint256 i = 0; i < 12; i++) {
            vMini.crank();
            vB4.crank();
        }
        assertEq(vMini.exitShareWad(), 0);
        assertEq(vB4.exitShareWad(), 0);

        // Both penalties entered the pool as measured inventory exactly once; the
        // operator/referrer were paid from each vault's own penalty only.
        uint256 gross = 110_000e18;
        uint256 vf = Phi.wmul(10_000e18, Phi.FEE_F);
        uint256 ocx = Phi.bps(vf, 3000);
        uint256 poolWad = Phi.wmul(gross, Phi.EXIT_Q) - ocx;
        uint256 penaltyEach = Phi.mulDiv(1e8, poolWad, gross);
        assertEq(pool.liability(address(ubtc)), 2 * penaltyEach);
        assertEq(pool.accruing(1), 2 * penaltyEach);

        // Global conservation: every deposited wei is accounted across all recipients.
        uint256 total = ubtc.balanceOf(user) + ubtc.balanceOf(operator) + ubtc.balanceOf(referrer)
            + ubtc.balanceOf(address(pool)) + ubtc.balanceOf(address(vMini))
            + ubtc.balanceOf(address(vB4));
        assertEq(total, 2e8);
        assertGe(ubtc.balanceOf(address(pool)), pool.liability(address(ubtc)));
        // Both vaults fully drained their in-kind bucket modulo B5 flooring dust:
        // the per-recipient mulDiv splits floor, so ≤ 2 wei stays accounted per vault
        // (included in the conservation sum above — dust remains protocol property).
        assertLe(vMini.dirEvm(), 2);
        assertLe(vB4.dirEvm(), 2);
    }

    // =====================================================================
    // 3. MAX_DIRECTIONAL: a pool at the 8-directional cap runs a full distribution
    //    cycle (capture → advance → lock → report → claims for two vaults), and a
    //    9th directional reverts. No existing test ever builds such a pool, despite
    //    INVARIANTS.md row 18 citing the cap as the loop bound under invariant 18.
    // =====================================================================
    function test_V3Cov_max_directional_pool_lifecycle_and_cap() public {
        uint256 n = 8;
        CoreTypes.AssetDescriptor[] memory ds = new CoreTypes.AssetDescriptor[](n + 1);
        ds[0] = usdcDescriptor();
        MockERC20[] memory toks = new MockERC20[](n);
        for (uint256 i = 0; i < n; i++) {
            toks[i] = new MockERC20("D", i == 0 ? 6 : 18); // one sub-wei-decimals asset
            uint64 id = uint64(2 + i);
            uint32 mkt = uint32(6 + i);
            hub.registerToken(id, address(toks[i]), 8, 2, i == 0 ? 6 : 18, "D");
            hub.registerSpotMarket(mkt, id, USDC_CORE);
            hub.setSpotPx(mkt, 4000e6);
            ds[i + 1] = CoreTypes.AssetDescriptor({
                evmToken: address(toks[i]),
                evmDecimals: i == 0 ? 6 : 18,
                coreToken: id,
                spotMarket: mkt,
                perpMarket: CoreTypes.NO_MARKET,
                coreWeiDecimals: 8,
                spotSzDecimals: 2,
                perpSzDecimals: 0,
                perpMaxLeverage: 0,
                fixedUsd: false
            });
        }

        // The cap itself: a 9th directional reverts (F2: loops bounded by the cap).
        CoreTypes.AssetDescriptor[] memory over = new CoreTypes.AssetDescriptor[](n + 2);
        for (uint256 i = 0; i < n + 1; i++) {
            over[i] = ds[i];
        }
        over[n + 1] = ubtcDescriptor();
        vm.expectRevert(B4Pool.TooManyAssets.selector);
        new B4Pool(address(oracle), over);

        B4Pool p = new B4Pool(address(oracle), ds); // this PoC acts as factory
        V3MockVault vA = new V3MockVault(address(0xA));
        V3MockVault vB = new V3MockVault(address(0xB));
        p.registerVault(address(vA));
        p.registerVault(address(vB));

        // Seed every one of the 9 basket assets, then run the full cycle.
        usdc.mint(address(p), 1_000e6);
        for (uint256 i = 0; i < n; i++) {
            uint256 unit = 10 ** toks[i].decimals();
            toks[i].mint(address(p), (100 + 10 * i) * unit);
        }
        p.capture();
        warpTo(Calendar.P - Calendar.H);
        p.advance();
        p.lockPrices(0); // loops all 8 directionals — must price every one
        vA.report(p, 0, 3e18);
        vB.report(p, 0, 1e18);
        vm.warp(block.timestamp + Calendar.SNAPSHOT_WINDOW + Calendar.REPORT_WINDOW + 1);

        p.claimFor(0, address(vA));
        p.claimFor(0, address(vB));
        assertEq(usdc.balanceOf(address(0xA)), 750e6);
        assertEq(usdc.balanceOf(address(0xB)), 250e6);
        for (uint256 i = 0; i < n; i++) {
            uint256 unit = 10 ** toks[i].decimals();
            uint256 minted = (100 + 10 * i) * unit;
            // Pro-rata within 4 wei of flooring dust per claimant (D3/B5).
            assertApproxEqAbs(toks[i].balanceOf(address(0xA)), (minted * 3) / 4, 4);
            assertApproxEqAbs(toks[i].balanceOf(address(0xB)), minted / 4, 4);
            assertGe(toks[i].balanceOf(address(p)), p.liability(address(toks[i])));
        }
        assertGe(usdc.balanceOf(address(p)), p.liability(address(usdc)));
    }
}
