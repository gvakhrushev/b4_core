// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {MockERC20} from "../mocks/MockCore.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {B4Pool} from "src/core/B4Pool.sol";
import {B4VaultStorage} from "src/core/B4VaultStorage.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";
import {IStrategy} from "src/interfaces/IStrategy.sol";

/// @notice Constant 0.5/0.5 base target — hunts ping-pong across the band during clamped
///         chunked rotation (V4 adversarial pass on the V3-ACCT-2 fix).
contract HalfStrategy is IStrategy {
    function targets() external pure returns (int256, int256) {
        return (5e17, 5e17);
    }
}

/// @notice V4 adversarial verification of the V3-ACCT-2 clamp fix. The fix clamps the
///         SELL sizing to the uint64 ceiling and chunks the rotation across cranks. This
///         suite attacks the chunking itself: convergence/monotonicity, the tightest
///         chunk boundary, sub-lot Core dust, round-trip dust, and — critically — whether
///         the clamped FUND sizing respects the existing Core balance (a Core spot
///         balance is itself uint64; spotBal + funded chunk must never exceed 2^64−1).
contract V4EngCastConvergenceTest is VaultTestBase {
    MockERC20 micro;
    uint64 constant MICRO_CORE = 12;
    uint32 constant MICRO_MKT = 12;
    uint256 constant U64 = uint256(type(uint64).max) + 1; // 2^64

    function setUp() public {
        setUpProtocol();
    }

    function microDescriptor() internal returns (CoreTypes.AssetDescriptor memory d) {
        micro = new MockERC20("MICRO", 8);
        hub.registerToken(MICRO_CORE, address(micro), 8, 0, 8, "MICRO");
        hub.registerSpotMarket(MICRO_MKT, MICRO_CORE, USDC_CORE);
        hub.setSpotPx(MICRO_MKT, 100); // $1e-6
        d = CoreTypes.AssetDescriptor({
            evmToken: address(micro),
            evmDecimals: 8,
            coreToken: MICRO_CORE,
            spotMarket: MICRO_MKT,
            perpMarket: CoreTypes.NO_MARKET,
            coreWeiDecimals: 8,
            spotSzDecimals: 0,
            perpSzDecimals: 0,
            perpMaxLeverage: 0,
            fixedUsd: false
        });
    }

    function _microVault(address strategy) internal returns (B4Vault v) {
        CoreTypes.AssetDescriptor memory d = microDescriptor();
        CoreTypes.AssetDescriptor[] memory dirs = new CoreTypes.AssetDescriptor[](1);
        dirs[0] = d;
        B4Pool p2 = B4Pool(factory.createPool(dirs));
        vm.prank(user);
        v = B4Vault(
            factory.createVault(
                address(p2), CoreTypes.descriptorHash(d), strategy, 1e18, 100, defaultRoute()
            )
        );
    }

    function _deposit(B4Vault v, uint256 amount) internal {
        micro.mint(user, amount);
        vm.startPrank(user);
        micro.approve(address(v), amount);
        v.deposit(amount, 0);
        vm.stopPrank();
    }

    /// CONTROL: reproduce the pass-after scenario (2e19, inside (2^64, 2·2^64−15)) with a
    /// full per-crank trace, asserting monotonic convergence (any buy leg / ping-pong
    /// would show up as dirWei increasing at an idle checkpoint).
    function test_V4_trace_2e19_converges_monotonically() public {
        B4Vault v = _microVault(address(b4));
        _deposit(v, 2e19);
        warpTo(Calendar.P);

        uint256 prevDir = type(uint256).max;
        uint256 steps;
        bool progress = true;
        while (progress && steps < 200) {
            progress = v.crank();
            steps++;
            if (intentKindOf(v) == B4VaultStorage.IntentKind.None) {
                uint256 d = v.dirEvm() + v.coreDirWei();
                assertLe(d, prevDir, "dir increased at an idle checkpoint (oscillation)");
                prevDir = d;
            }
        }
        assertFalse(progress, "did not converge within 200 cranks");
        emit log_named_uint("steps", steps);
        emit log_named_uint("final dirEvm", v.dirEvm());
        emit log_named_uint("final coreDirWei", v.coreDirWei());
        emit log_named_uint("final usdcRotatedEvm", v.usdcRotatedEvm());
        assertEq(v.coreDirWei(), 0);
        assertLe(v.dirEvm(), 1e8, "residual above one lot");
    }

    /// ATTACK 1 (chunk-boundary): a >2·2^64−15 position. After the first clamped chunk
    /// leaves a sub-lot residue on Core, the next fall-through fund is sized
    /// min(clampedSell, dirEvm) with NO regard for the Core balance already present. If
    /// residue + chunk > uint64.max the Core credit itself is arithmetically impossible.
    function test_V4_second_chunk_respects_core_balance_ceiling() public {
        B4Vault v = _microVault(address(b4));
        // 4e19 wei ≈ $400k at $1e-6 — above 2·2^64−15, the point where clamped chunk 2
        // plus the chunk-1 residue exceeds the uint64 Core balance ceiling.
        _deposit(v, 4e19);
        warpTo(Calendar.P);

        // Crank 1: clamped FundDir (uint64.max) — fits: Core balance was 0.
        assertTrue(v.crank());
        assertEq(uint8(intentKindOf(v)), uint8(B4VaultStorage.IntentKind.FundDir));
        // Crank 2: credit completes (Core balance now exactly uint64.max).
        assertTrue(v.crank());
        // Crank 3: clamped sell fills whole lots, leaving a sub-lot residue on Core.
        assertTrue(v.crank());
        assertEq(uint8(intentKindOf(v)), uint8(B4VaultStorage.IntentKind.SpotOrder));
        assertTrue(v.crank()); // verify sell → residue + USDC credit
        uint64 residue = v.coreDirWei();
        emit log_named_uint("residue after chunk 1 sell", residue);
        assertGt(residue, 0, "test premise: clamped chunk must leave a sub-lot residue");
        assertEq(v.dirEvm(), 4e19 - type(uint64).max, "chunk 2 still on EVM");

        // Crank 5 (the attack): sell leg no-ops on the sub-lot residue, falls through to
        // _startFund(min(clampedSell, dirEvm)) = uint64.max — while the Core spot balance
        // already holds `residue` wei. The EVM→Core credit of uint64.max would push the
        // Core balance to residue + uint64.max > uint64.max. A correct engine caps the
        // fund at uint64.max − coreDirWei.
        try v.crank() returns (bool progressed) {
            (,, uint64 amount,,,,,,,,,) = v.intent();
            emit log_named_uint("crank5 progressed (1=yes)", progressed ? 1 : 0);
            emit log_named_uint("crank5 fund amount", amount);
            assertLe(
                uint256(amount) + residue, type(uint64).max, "fund exceeds Core balance headroom"
            );
        } catch (bytes memory err) {
            emit log_named_bytes("crank5 reverted", err);
            revert("V4-ENG-1: sync machine reverts on chunk 2 (fix incomplete > 2*2^64-15)");
        }
    }

    /// ATTACK 1b: full rotation of the same 4e19 position must converge, not die.
    function test_V4_oversized_4e19_rotation_converges() public {
        B4Vault v = _microVault(address(b4));
        _deposit(v, 4e19);
        warpTo(Calendar.P);

        uint256 steps;
        bool progress = true;
        bool sawRevert;
        while (progress && steps < 300) {
            steps++;
            try v.crank() returns (bool p) {
                progress = p;
            } catch {
                sawRevert = true;
                break;
            }
        }
        assertFalse(sawRevert, "V4-ENG-1: crank reverted mid-rotation, sync machine dead");
        assertFalse(progress, "no convergence within 300 cranks");
        assertEq(v.coreDirWei(), 0);
        assertLe(v.dirEvm(), 1e8, "residual above one lot");
        assertGt(v.usdcRotatedEvm(), 399_000e6, "rotation proceeds did not come home");
    }

    /// ATTACK 2 (oscillation hunt): mid-band target 0.5 with an oversized position. The
    /// clamp undershoots by construction (sellWei ≤ needed), so dirWei must approach the
    /// band monotonically (any buy leg would show as an idle-checkpoint increase).
    function test_V4_mid_target_no_pingpong() public {
        HalfStrategy half = new HalfStrategy();
        B4Vault v = _microVault(address(half));
        _deposit(v, 6e19); // $600k — t = 0 growth: target 0.5 both regimes.

        uint256 prevDir = type(uint256).max;
        uint256 steps;
        bool progress = true;
        bool sawRevert;
        while (progress && steps < 300) {
            steps++;
            try v.crank() returns (bool p) {
                progress = p;
            } catch {
                sawRevert = true;
                break;
            }
            if (intentKindOf(v) == B4VaultStorage.IntentKind.None) {
                uint256 d = v.dirEvm() + v.coreDirWei();
                assertLe(d, prevDir, "dir increased at idle (ping-pong)");
                prevDir = d;
            }
        }
        assertFalse(sawRevert, "crank reverted mid-rotation");
        assertFalse(progress, "did not converge within 300 cranks");
        emit log_named_uint("steps", steps);
        emit log_named_uint("final dirWei", prevDir);
    }

    /// ATTACK 3 (tightest boundary): exactly 2^64+1 wei. The old code bricked at
    /// balances ≡ 0 (mod 2^64); the clamp must not leave ANY residue attractor.
    function test_V4_exactly_2pow64_plus_one() public {
        B4Vault v = _microVault(address(b4));
        _deposit(v, U64 + 1);
        warpTo(Calendar.P);

        uint256 steps;
        bool progress = true;
        while (progress && steps < 300) {
            progress = v.crank();
            steps++;
        }
        assertFalse(progress, "did not converge");
        assertEq(v.coreDirWei(), 0, "Core residue stranded");
        assertLe(v.dirEvm(), 1e8, "residual above one lot");
        assertGt(v.usdcRotatedEvm(), 184_000e6);
    }

    /// ATTACK 4 (round-trip dust): evmDecimals(18) > coreWeiDecimals(8). The evmToCore
    /// clamp + coreToEvm re-normalization floors to whole wei each fund; assert the loop
    /// TERMINATES with EVM dust < 1 lot (1e18 evm units) shipped home.
    function test_V4_evm18_roundtrip_dust_terminates() public {
        micro = new MockERC20("MICRO18", 18);
        uint64 C18 = 13;
        uint32 M18 = 13;
        hub.registerToken(C18, address(micro), 8, 0, 18, "MICRO18");
        hub.registerSpotMarket(M18, C18, USDC_CORE);
        hub.setSpotPx(M18, 100); // $1e-6
        CoreTypes.AssetDescriptor memory d = CoreTypes.AssetDescriptor({
            evmToken: address(micro),
            evmDecimals: 18,
            coreToken: C18,
            spotMarket: M18,
            perpMarket: CoreTypes.NO_MARKET,
            coreWeiDecimals: 8,
            spotSzDecimals: 0,
            perpSzDecimals: 0,
            perpMaxLeverage: 0,
            fixedUsd: false
        });
        CoreTypes.AssetDescriptor[] memory dirs = new CoreTypes.AssetDescriptor[](1);
        dirs[0] = d;
        B4Pool p2 = B4Pool(factory.createPool(dirs));
        vm.prank(user);
        B4Vault v = B4Vault(
            factory.createVault(
                address(p2), CoreTypes.descriptorHash(d), address(b4), 1e18, 100, defaultRoute()
            )
        );
        // 3e11 whole tokens = 3e29 evm units = 3e19 core wei ≈ $300k.
        _deposit(v, 3e29);
        warpTo(Calendar.P);

        uint256 steps;
        bool progress = true;
        bool sawRevert;
        while (progress && steps < 300) {
            steps++;
            try v.crank() returns (bool p) {
                progress = p;
            } catch {
                sawRevert = true;
                break;
            }
        }
        assertFalse(sawRevert, "crank reverted mid-rotation");
        assertFalse(progress, "no convergence within 300 cranks (dust loop)");
        assertEq(v.coreDirWei(), 0, "Core dust stranded");
        assertLe(v.dirEvm(), 1e18, "EVM dust above one lot");
        assertGt(v.usdcRotatedEvm(), 299_000e6);
        emit log_named_uint("final dirEvm dust (evm units)", v.dirEvm());
    }
}

/// @notice Sub-lot Core dust above the band (coarse-lot market): the sell leg no-ops,
///         dirEvm == 0, the step must return FALSE (honest no-progress, A13) — and the
///         dust must clear via the in-band repatriation branch once it falls in band.
contract V4EngCoreDustTest is VaultTestBase {
    MockERC20 coarse;
    uint64 constant COARSE_CORE = 14;
    uint32 constant COARSE_MKT = 14;

    function setUp() public {
        setUpProtocol();
    }

    function _coarseVault() internal returns (B4Vault v) {
        coarse = new MockERC20("COARSE", 8);
        // 1 lot = 1 whole token = 1e8 wei; $100/token ⇒ 1 lot ($100) > band floor ($10).
        hub.registerToken(COARSE_CORE, address(coarse), 8, 0, 8, "COARSE");
        hub.registerSpotMarket(COARSE_MKT, COARSE_CORE, USDC_CORE);
        hub.setSpotPx(COARSE_MKT, 100 * 1e8);
        CoreTypes.AssetDescriptor memory d = CoreTypes.AssetDescriptor({
            evmToken: address(coarse),
            evmDecimals: 8,
            coreToken: COARSE_CORE,
            spotMarket: COARSE_MKT,
            perpMarket: CoreTypes.NO_MARKET,
            coreWeiDecimals: 8,
            spotSzDecimals: 0,
            perpSzDecimals: 0,
            perpMaxLeverage: 0,
            fixedUsd: false
        });
        CoreTypes.AssetDescriptor[] memory dirs = new CoreTypes.AssetDescriptor[](1);
        dirs[0] = d;
        B4Pool p2 = B4Pool(factory.createPool(dirs));
        vm.prank(user);
        v = B4Vault(
            factory.createVault(
                address(p2), CoreTypes.descriptorHash(d), address(b4), 1e18, 100, defaultRoute()
            )
        );
        coarse.mint(user, 19e7); // 1.9 tokens
        vm.startPrank(user);
        coarse.approve(address(v), 19e7);
        v.deposit(19e7, 0);
        vm.stopPrank();
    }

    /// 1.9 lots at fall target 0: sells 1 lot, leaving 0.9 lot ($90) sub-lot Core dust
    /// ABOVE the $10 band floor. The step returns false (honest stall — it cannot sell a
    /// sub-lot amount, a venue granularity constraint). Recovery: price drops so the dust
    /// falls inside the band → the in-band branch repatriates the FULL dust amount.
    function test_V4_sublot_dust_stall_then_inband_repatriation() public {
        B4Vault v = _coarseVault();
        warpTo(Calendar.P);

        crankUntilIdle(v, 20);
        assertEq(v.coreDirWei(), 9e7, "0.9 lot dust on Core");
        assertEq(v.dirEvm(), 0);
        assertGt(v.coreUsdcRotatedWei(), 0, "1 lot sold, proceeds on Core");

        // Out of band by $90 > band ($10 floor) but unsellable (sub-lot): honest false.
        assertFalse(v.crank(), "must report no-progress, not spin (A13/M-1)");
        assertEq(uint8(intentKindOf(v)), uint8(B4VaultStorage.IntentKind.None));

        // Price drop pulls the dust inside the band → in-band branch repatriates in full
        // (USDC leg first per :741-748, then the dir dust).
        hub.setSpotPx(COARSE_MKT, 5 * 1e8); // $5/token: dust = $4.50 < band
        assertTrue(v.crank(), "in-band repatriation must fire");
        assertEq(uint8(intentKindOf(v)), uint8(B4VaultStorage.IntentKind.ReturnUsdc));
        crankUntilIdle(v, 10);
        assertEq(v.coreDirWei(), 0, "dust did not clear from Core");
        assertEq(v.dirEvm(), 9e7, "full dust amount repatriated");

        // And the vault remains fully exit-able throughout (custody never at risk).
        warpTo(Calendar.T); // free window
        vm.prank(user);
        v.initiateExit(1e18);
        crankUntilIdle(v, 20);
        assertEq(v.exitShareWad(), 0, "exit must finalize");
    }

    /// Same stall state, resolved through the exit machine instead of a price move: the
    /// exit planner repatriates the dust and pays the owner (custody path unaffected).
    function test_V4_sublot_dust_exit_machine_clears() public {
        B4Vault v = _coarseVault();
        warpTo(Calendar.P);
        crankUntilIdle(v, 20);
        assertEq(v.coreDirWei(), 9e7);
        assertFalse(v.crank());

        vm.prank(user);
        v.initiateExit(1e18); // penalized at P, but must WORK
        crankUntilIdle(v, 20);
        assertEq(v.exitShareWad(), 0, "exit must finalize from the dust-stall state");
        assertGt(coarse.balanceOf(user) + usdc.balanceOf(user), 0, "owner paid");
    }
}
