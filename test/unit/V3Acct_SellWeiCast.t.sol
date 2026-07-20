// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {MockERC20} from "../mocks/MockCore.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {B4Pool} from "src/core/B4Pool.sol";
import {B4VaultStorage} from "src/core/B4VaultStorage.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";

/// @notice V3-ACCT: `B4VaultEngine._planSpotStep` narrows the desired sell amount with
///         `uint64 sellWei = uint64(_fromWad(sellTokensWad, coreWeiDecimals))` BEFORE any
///         clamping. Solidity TRUNCATES (wraps) narrowing casts — no panic — so for an
///         EVM dir holding above uint64.max wei the engine funds only the wrapped chunk
///         (D mod 2^64), leaving EXACTLY k·2^64 wei behind; the next derivation wraps to
///         0, `_startFund(0)` is a no-op returning false, and `_planSpotStep` reports "no
///         progress" forever. Deterministic, PRICE-INDEPENDENT (a sell-all derives
///         sellWei ≈ dirEvm regardless of px), and silent: crank() returns false, the
///         keeper stops, and the vault's rotation is permanently dead with up to ~$184k+
///         per 2^64-wei multiple stranded on the EVM side (a $1e-6, 8-wei-decimals
///         asset ⇒ 2^64 wei = 1.84e11 tokens ≈ $184k). Violates H3 ("worst case is
///         delayed liveness, self-healing by cranking") — custody survives only via an
///         in-kind exit (penalized outside free windows).
contract V3AcctSellWeiCastTest is VaultTestBase {
    MockERC20 micro;
    uint64 constant MICRO_CORE = 12;
    uint32 constant MICRO_MKT = 12;
    uint256 constant U64 = uint256(type(uint64).max) + 1; // 2^64

    function setUp() public {
        setUpProtocol();
    }

    function microDescriptor() internal returns (CoreTypes.AssetDescriptor memory d) {
        micro = new MockERC20("MICRO", 8);
        // weiDec 8, szDec 0 (1 lot = 1 whole token), evmDec 8 — a HyperCore-style micro asset.
        hub.registerToken(MICRO_CORE, address(micro), 8, 0, 8, "MICRO");
        hub.registerSpotMarket(MICRO_MKT, MICRO_CORE, USDC_CORE);
        hub.setSpotPx(MICRO_MKT, 100); // $1e-6 at (8−0)=8 price decimals
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

    function _microVault() internal returns (B4Vault v) {
        CoreTypes.AssetDescriptor memory d = microDescriptor();
        CoreTypes.AssetDescriptor[] memory dirs = new CoreTypes.AssetDescriptor[](1);
        dirs[0] = d;
        B4Pool p2 = B4Pool(factory.createPool(dirs));
        vm.prank(user);
        v = B4Vault(
            factory.createVault(
                address(p2),
                CoreTypes.descriptorHash(d),
                address(b4), // growth 1 / fall 0: rotates fully to USDC at the fall regime
                1e18,
                100,
                defaultRoute()
            )
        );
    }

    function _deposit(B4Vault v, uint256 amount) internal {
        micro.mint(user, amount);
        vm.startPrank(user);
        micro.approve(address(v), amount);
        v.deposit(amount, 0); // 256-bit ledger: deposits of any size are fine
        vm.stopPrank();
    }

    /// PASS-AFTER (V3-ACCT-2 fix): $200k of a $1e-6 token (D = 2e19 wei > 2^64) now
    /// CLAMPS the sell sizing to the uint64 ceiling instead of wrapping, so the rotation
    /// chunks across cranks and converges — no brick, no stranded 2^64 attractor (H3 held).
    function test_V3ACCT_oversized_micro_position_clamps_and_rotates() public {
        B4Vault v = _microVault();
        uint256 depositAmt = 2e19; // 2e11 whole tokens ≈ $200,000 at $1e-6
        _deposit(v, depositAmt);

        warpTo(Calendar.P); // fall plateau: B4 target 0 ⇒ must sell everything

        // Crank 1: the first fund is CLAMPED to the uint64 ceiling (not wrapped).
        assertTrue(v.crank());
        assertEq(uint8(intentKindOf(v)), uint8(B4VaultStorage.IntentKind.FundDir));
        (,, uint64 amount,,,,,,,,,) = v.intent();
        assertEq(amount, type(uint64).max); // clamp, not the wrapped chunk

        // Crank to convergence: the delta-measured engine chunks the move and the whole
        // $200k rotates to USDC over several cranks — the vault is never stuck.
        crankUntilIdle(v, 60);
        assertEq(uint8(intentKindOf(v)), uint8(B4VaultStorage.IntentKind.None));
        assertEq(v.dirEvm(), 0, "fully rotated, no 2^64 remainder");
        assertEq(v.coreDirWei(), 0);
        assertGt(v.usdcRotatedEvm(), 199_000e6); // ≈ $200k came home as USDC

        // And an ordinary free-window exit pays the owner in full (no penalty needed here).
        warpTo(Calendar.T); // ClosingFall: free window
        vm.prank(user);
        v.initiateExit(1e18);
        crankUntilIdle(v, 20);
        assertEq(v.exitShareWad(), 0);
        assertGt(usdc.balanceOf(user), 199_000e6);
    }

    /// Just below the ceiling the identical code path works — the brick is purely the
    /// truncating cast (downstream _lotsToSz8 clamping/chunking is intact).
    function test_V3ACCT_below_ceiling_rotates_normally() public {
        B4Vault v = _microVault();
        uint256 ok = 1e19; // 1e11 whole tokens ≈ $100,000 — under 2^64
        _deposit(v, ok);

        warpTo(Calendar.P);
        assertTrue(v.crank()); // FundDir for the FULL amount (no wrap)
        (,, uint64 amount,,,,,,,,,) = v.intent();
        assertEq(amount, ok);
        crankUntilIdle(v, 20);
        assertEq(v.dirEvm(), 0);
        assertGt(v.usdcRotatedEvm(), 99_000e6); // rotation completed end-to-end
    }
}
