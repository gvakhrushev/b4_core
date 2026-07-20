// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {EngineHarness} from "../utils/EngineHarness.sol";
import {MockERC20} from "../mocks/MockCore.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {B4Pool} from "src/core/B4Pool.sol";
import {Keeper} from "src/periphery/Keeper.sol";
import {B4VaultStorage} from "src/core/B4VaultStorage.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {Phi} from "src/libraries/Phi.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";

/// @notice A pool directional token that reenters the pool from its transfer callback
///         (the reentrancy vector the audit found: claimFor's payout calls an
///         attacker-controlled ERC20). It records whether the reentrant call reverted.
contract ReentrantPoolToken {
    B4Pool public pool;
    bool public reentryReverted;
    bool public tried;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function setPool(B4Pool p) external {
        pool = p;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        if (address(pool) != address(0)) {
            tried = true;
            // Attempt to reenter a sibling state-mutating entrypoint mid-payout.
            try pool.advance() returns (bool) {
                reentryReverted = false; // guard absent: reentrancy succeeded (fail-before)
            } catch {
                reentryReverted = true; // guard present: reentrancy blocked (pass-after)
            }
        }
        return true;
    }
}

contract MockVaultOwner {
    address public owner;

    constructor(address o) {
        owner = o;
    }
}

/// @notice Regressions for the first-principles security audit (see AUDIT.md).
contract AuditRegressionTest is VaultTestBase {
    function setUp() public {
        setUpProtocol();
    }

    function readSzi(address who) internal view returns (int64) {
        (bool ok, bytes memory ret) =
            CoreTypes.PRECOMPILE_POSITION.staticcall(abi.encode(who, uint16(PERP_MKT)));
        require(ok, "read");
        return abi.decode(ret, (CoreTypes.Position)).szi;
    }

    // =====================================================================
    // AUDIT-1 (HIGH): opsRecoverPerpSurplus must RESERVE the pending harvest claim, so
    // the owner can't sweep realized perp profit out untaxed (bypassing the operator/
    // referrer performance fee and under-reporting NAV/rewardBase — decision C1).
    // =====================================================================

    function test_AUDIT1_recoverPerpSurplus_reserves_harvest_claim() public {
        B4Vault v = createVault(address(pro));
        fundAndDeposit(v, 1e8, 20_000e6);
        warpTo(Calendar.P); // fall: open the short with margin
        crankUntilIdle(v, 40);
        assertLt(readSzi(address(v)), 0);
        uint64 margin = v.perpMargin6();

        // Short becomes profitable; drive the flatten at the crossing so the reduces
        // record a harvest claim, and stop BEFORE the harvest-settle crank.
        hub.setSpotPx(SPOT_MKT, 80_000e4);
        hub.setMarkPx(PERP_MKT, 80_000e2);
        hub.setOraclePx(PERP_MKT, 80_000e2);
        warpTo(Calendar.T + Calendar.H);
        // Crank until flat + idle + harvest RECORDED — i.e. through the reduce's verify
        // crank, but stop before the harvest-settle step (which needs pendingHarvest6>0).
        for (uint256 i = 0; i < 10; i++) {
            if (
                readSzi(address(v)) == 0 && intentKindOf(v) == B4VaultStorage.IntentKind.None
                    && v.pendingHarvest6() > 0
            ) break;
            v.crank();
        }
        assertEq(readSzi(address(v)), 0); // strictly flat, idle
        uint64 h = v.pendingHarvest6();
        assertGt(h, 0); // realized perp profit recorded as a harvest claim

        // withdrawable == margin + claim exactly: NOTHING is the owner's untaxed surplus.
        hub.setWithdrawable(address(v), margin + h);
        vm.prank(user);
        vm.expectRevert(B4VaultStorage.NothingToRecover.selector); // fail-before: recovered h
        v.recoverPerpSurplus();
        assertEq(v.pendingHarvest6(), h); // claim preserved for the taxed harvest path

        // A genuine funding surplus above (margin + claim) IS recoverable — but only it.
        hub.setWithdrawable(address(v), margin + h + 100e6);
        vm.prank(user);
        v.recoverPerpSurplus();
        v.crank(); // verify phase 1 → phase 2
        v.crank(); // verify phase 2 → pay owner
        assertEq(usdc.balanceOf(user), 100e6); // only the funding surplus, not the claim
        assertEq(v.pendingHarvest6(), h); // claim still reserved

        // The reserved claim later settles into the TAXED strategy ledger.
        uint64 rotBefore = v.coreUsdcRotatedWei();
        v.crank(); // sync step 2: harvest settle
        v.crank(); // verify
        assertEq(v.pendingHarvest6(), 0);
        assertGt(v.coreUsdcRotatedWei(), rotBefore); // profit entered accounted NAV
    }

    // =====================================================================
    // AUDIT-2 (MEDIUM): pool sweep/capture/advance must be nonReentrant so a malicious
    // pool token cannot reenter them from claimFor's payout callback (F4).
    // =====================================================================

    function test_AUDIT2_pool_siblings_nonreentrant_during_claim() public {
        ReentrantPoolToken evil = new ReentrantPoolToken();
        hub.registerToken(9, address(evil), 8, 2, 18, "EVIL");
        hub.registerSpotMarket(9, 9, USDC_CORE);
        hub.setSpotPx(9, 4000e6);

        CoreTypes.AssetDescriptor[] memory ds = new CoreTypes.AssetDescriptor[](2);
        ds[0] = usdcDescriptor();
        ds[1] = CoreTypes.AssetDescriptor({
            evmToken: address(evil),
            evmDecimals: 18,
            coreToken: 9,
            spotMarket: 9,
            perpMarket: CoreTypes.NO_MARKET,
            coreWeiDecimals: 8,
            spotSzDecimals: 2,
            perpSzDecimals: 0,
            perpMaxLeverage: 0,
            fixedUsd: false
        });
        B4Pool p = new B4Pool(address(oracle), ds); // this test acts as factory
        evil.setPool(p);
        MockVaultOwner mv = new MockVaultOwner(user);
        p.registerVault(address(mv));

        evil.mint(address(p), 50e18);
        p.capture();
        warpTo(Calendar.P - Calendar.H);
        p.advance();
        p.lockPrices(0);
        vm.prank(address(mv));
        p.reportWeight(0, 1e18);
        vm.warp(block.timestamp + Calendar.SNAPSHOT_WINDOW + Calendar.REPORT_WINDOW + 1);

        // Claim pays the evil token to the owner, triggering the reentrant callback.
        p.claimFor(0, address(mv));

        assertTrue(evil.tried()); // the callback fired…
        assertTrue(evil.reentryReverted()); // …and the reentrant advance() was blocked
        assertEq(evil.balanceOf(user), 50e18); // the legitimate claim still paid out
        assertTrue(p.claimedOf(0, address(mv), 1));
    }

    /// The guard does not break the LEGITIMATE cross-contract call: the vault's exit
    /// finalize calls pool.capture() from outside any pool function, which must succeed.
    function test_AUDIT2_exit_capture_still_works() public {
        // A plain (non-reentrant) directional token; exit outside a free window sends the
        // penalty to the pool and calls capture().
        B4Vault v = createVault(address(mini));
        warpTo(100 days);
        fundAndDeposit(v, 1e8, 0);
        hub.setSpotPx(SPOT_MKT, 110_000e4);
        vm.prank(user);
        v.initiateExit(1e18);
        crankUntilIdle(v, 10); // finalize calls pool.capture() for the penalty
        assertEq(v.exitShareWad(), 0);
        assertGt(pool.liability(address(ubtc)), 0); // capture() ran, penalty is inventory
    }

    // =====================================================================
    // V2-1 (MEDIUM, codex RAW-POOL-*-BALANCEOF): a malicious basket token whose
    // balanceOf reverts must NOT freeze claimFor / capture for the settlement token, the
    // healthy tokens, or co-resident vaults (D5 / invariant 18). Only its own claim
    // defers, retryable once the token behaves.
    // =====================================================================

    function _malignPool() internal returns (B4Pool p, MalignBalanceToken bad, MockVaultOwner mv) {
        bad = new MalignBalanceToken();
        hub.registerToken(9, address(bad), 8, 2, 18, "BAD");
        hub.registerSpotMarket(9, 9, USDC_CORE);
        hub.setSpotPx(9, 4000e6);

        CoreTypes.AssetDescriptor[] memory ds = new CoreTypes.AssetDescriptor[](3);
        ds[0] = usdcDescriptor();
        ds[1] = ubtcDescriptor();
        ds[2] = CoreTypes.AssetDescriptor({
            evmToken: address(bad),
            evmDecimals: 18,
            coreToken: 9,
            spotMarket: 9,
            perpMarket: CoreTypes.NO_MARKET,
            coreWeiDecimals: 8,
            spotSzDecimals: 2,
            perpSzDecimals: 0,
            perpMaxLeverage: 0,
            fixedUsd: false
        });
        p = new B4Pool(address(oracle), ds); // this test acts as factory
        mv = new MockVaultOwner(user);
        p.registerVault(address(mv));

        usdc.mint(address(p), 1_000e6);
        ubtc.mint(address(p), 1e8);
        bad.mint(address(p), 50e18);
        p.capture(); // books all three tokens while balanceOf is healthy
    }

    function test_V2_pool_claim_survives_reverting_balanceof() public {
        (B4Pool p, MalignBalanceToken bad, MockVaultOwner mv) = _malignPool();
        warpTo(Calendar.P - Calendar.H);
        p.advance();
        p.lockPrices(0);
        vm.prank(address(mv));
        p.reportWeight(0, 1e18);
        vm.warp(block.timestamp + Calendar.SNAPSHOT_WINDOW + Calendar.REPORT_WINDOW + 1);

        // Attacker flips balanceOf to revert AFTER the interval is locked and owed.
        bad.setReverting(true);

        // Fail-before: raw balanceOf reverted the whole claimFor, freezing USDC + UBTC.
        // Pass-after: settlement + healthy tokens pay; only the malicious token defers.
        p.claimFor(0, address(mv));
        assertEq(usdc.balanceOf(user), 1_000e6);
        assertEq(ubtc.balanceOf(user), 1e8);
        assertTrue(p.claimedOf(0, address(mv), 0));
        assertTrue(p.claimedOf(0, address(mv), 1));
        assertFalse(p.claimedOf(0, address(mv), 2)); // deferred, retryable

        // Token behaves again → its claim is retryable and pays out.
        bad.setReverting(false);
        p.claimFor(0, address(mv));
        assertEq(bad.balanceOf(user), 50e18);
        assertTrue(p.claimedOf(0, address(mv), 2));
    }

    function test_V2_capture_survives_reverting_balanceof() public {
        (B4Pool p,, MockVaultOwner mv) = _malignPool();
        MalignBalanceToken bad = MalignBalanceToken(address(p.asset(2).evmToken));
        // A fresh donation of the healthy tokens after the malicious token is flipped.
        usdc.mint(address(p), 100e6);
        bad.setReverting(true);
        // Fail-before: capture() reverted on the malicious token, freezing the exit path.
        // Pass-after: the healthy USDC donation is captured; the malicious token skipped.
        uint256 liabBefore = p.liability(address(usdc));
        p.capture();
        assertEq(p.liability(address(usdc)), liabBefore + 100e6);
        mv; // silence
    }

    // =====================================================================
    // V2-2 (defense, codex overflow candidates): a near-uint64-max spot balance must not
    // overflow-revert the FromPerp completion check — worst case stays delayed liveness.
    // =====================================================================

    function test_V2_fromPerp_completion_no_overflow_at_max_balance() public {
        EngineHarnessAccess he = new EngineHarnessAccess();
        he.setup(ubtcDescriptor(), usdcDescriptor(), address(oracle));
        hub.setUserExists(address(he), true);
        hub.setAuto(false, true, true); // hold the transfer: cur stays at the snapshot

        // Drive the vault's USDC Core-spot balance to near uint64.max, then snapshot a
        // FromPerp(Margin) — snapSrcWei is now near-max, so snapSrcWei + weiNeeded exceeds
        // uint64 and, in the old code, overflow-reverted the completion check.
        he.setBuckets(0, 0, 0, 0, 0, 500e6, 0);
        hub.coreTopUp(address(he), USDC_CORE, type(uint64).max - 1e10);
        he.startFromPerp(B4VaultStorage.Purpose.Margin, 500e6); // queued, not executed

        // Fail-before: uint64 (snapSrcWei + weiNeeded) panics (0x11) here, reverting the
        // crank forever (a freeze). Pass-after: the uint256 comparison never reverts; the
        // check is simply false (cur < snapSrcWei + weiNeeded) and the intent stays live
        // for the normal resend/timeout — worst case delayed liveness, never a freeze (H3).
        assertFalse(he.verify());
        assertEq(uint8(he.intentKind()), uint8(B4VaultStorage.IntentKind.FromPerp)); // alive
    }

    // =====================================================================
    // V2-3 (keeper completeness, codex RAW-KEEPER-SWEEP-CATCHUP): when several intervals
    // materialize between keeper runs, the keeper must sweep ALL expired-unswept ones
    // (G2 — crank every step), not only count-2, so no inventory is stranded.
    // =====================================================================

    function test_V2_keeper_sweeps_catchup_window() public {
        Keeper keeper = new Keeper();
        address[] memory none = new address[](0);

        // Epoch 0: two settlement points, each seeded with unclaimed inventory.
        usdc.mint(address(pool), 100e6);
        pool.capture();
        warpTo(Calendar.P - Calendar.H);
        pool.advance(); // interval 0 (bucket 100)
        usdc.mint(address(pool), 100e6);
        pool.capture();
        warpTo(Calendar.T + Calendar.H);
        pool.advance(); // interval 1 (bucket 100)

        // Epoch 1: a fresh halving, two more points → count reaches 4.
        uint32 ts = uint32(GENESIS_TS + 1_400 days);
        vm.warp(uint256(ts) + 1);
        acceptHalving(GENESIS_HEIGHT + 210_000, ts);
        vm.warp(ts + Calendar.P - Calendar.H);
        pool.advance(); // interval 2
        vm.warp(ts + Calendar.T + Calendar.H);
        pool.advance(); // interval 3
        assertEq(pool.intervalCount(), 4);

        // Fail-before: the keeper swept only count-2 = interval 2, stranding 0 and 1.
        // Pass-after: the catch-up window sweeps every expired-unswept interval.
        keeper.crank(pool, none, 5);
        (,, bool s0,) = pool.intervalInfo(0);
        (,, bool s1,) = pool.intervalInfo(1);
        (,, bool s2,) = pool.intervalInfo(2);
        assertTrue(s0);
        assertTrue(s1);
        assertTrue(s2);
        // The stranded inventory rolled forward into the accruing basket (D4).
        assertEq(pool.accruing(0), 200e6);
    }
}

/// A pool token whose balanceOf can be flipped to revert (the codex balanceOf vector).
contract MalignBalanceToken {
    bool public reverting;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balances;

    function setReverting(bool v) external {
        reverting = v;
    }

    function mint(address to, uint256 a) external {
        balances[to] += a;
    }

    function balanceOf(address a) external view returns (uint256) {
        require(!reverting, "balanceOf blocked");
        return balances[a];
    }

    function transfer(address to, uint256 a) external returns (bool) {
        if (reverting) return false;
        balances[msg.sender] -= a;
        balances[to] += a;
        return true;
    }
}

/// EngineHarness with the exact entrypoints this file needs (verify + startFromPerp +
/// setup/setBuckets), re-declared to keep the test self-contained.
contract EngineHarnessAccess is EngineHarness {}
