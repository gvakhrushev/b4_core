// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {EngineHarness} from "../utils/EngineHarness.sol";
import {MockERC20} from "../mocks/MockCore.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {B4Pool} from "src/core/B4Pool.sol";
import {B4VaultStorage} from "src/core/B4VaultStorage.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {Phi} from "src/libraries/Phi.sol";
import {SafeTransfer} from "src/libraries/SafeTransfer.sol";
import {DescriptorLib} from "src/venue/DescriptorLib.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";

/// @notice A token that "succeeds" but returns malformed bytes from transfer — the
///         RAW-B-001 grief shape. It never moves balances, so a deferred claim stays
///         honestly deferred.
contract MalformedToken {
    mapping(address => uint256) public balanceOf;
    uint8 public constant decimals = 18;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address, uint256) external pure returns (bool) {
        assembly {
            mstore(0, 1)
            return(0, 3) // 3 junk bytes: neither empty nor a well-formed bool word
        }
    }
}

contract SafeTransferHarness {
    function tryIt(address token, address to, uint256 amount) external returns (bool) {
        return SafeTransfer.tryTransfer(token, to, amount);
    }
}

contract MockVaultB {
    address public owner;

    constructor(address owner_) {
        owner = owner_;
    }
}

/// @notice Fail-before/pass-after regressions for the adjudicated external discovery
///         findings (see REPORT.md, "External discovery-report adjudication").
contract FindingsRegressionTest is VaultTestBase {
    EngineHarness h;

    function setUp() public {
        setUpProtocol();
        h = new EngineHarness();
        h.setup(ubtcDescriptor(), usdcDescriptor(), address(oracle));
        hub.setUserExists(address(h), true);
    }

    // =====================================================================
    // RAW-A-001: an executed-but-unverified margin return must not corrupt accounting.
    // The fix requires settle to be idle (no mid-flight valuation) and keeps the
    // engine's own reconcile at idle only; here we prove value conservation across the
    // margin-return completion and settle's idle guard (incl. the coincident-loss race
    // the adversarial pass surfaced).
    // =====================================================================

    function test_A001_marginReturn_value_conserved_at_idle() public {
        hub.setWithdrawable(address(h), 500e6);
        h.setBuckets(0, 0, 0, 0, 0, 0, 500e6);
        h.startFromPerp(B4VaultStorage.Purpose.Margin, 500e6);
        assertEq(hub.wd(address(h)), 0); // executed: wd → 0, spot +500e8, unverified

        // Completion moves the value from the perp bucket into the spot bucket, once.
        assertTrue(h.verify());
        assertEq(h.perpMargin6(), 0);
        assertEq(h.coreUsdcMarginWei(), 500e8);
        assertEq(h.navView(1e18), 500e18); // conserved end-to-end, no phantom, no loss

        // A reconcile now (idle, flat, wd already 0, no perp principal recorded) is a
        // no-op — nothing to write down.
        h.reconcile();
        assertEq(h.coreUsdcMarginWei(), 500e8);
    }

    /// Vault-level: settle is REJECTED while a perp-side transfer is in flight, so it can
    /// never over-report NAV by valuing an in-flight margin return (the adversarial
    /// coincident-loss race). Once idle, settle values an exact ledger.
    function test_A001_settle_requires_idle_during_marginReturn() public {
        B4Vault v = createVault(address(pro));
        fundAndDeposit(v, 1e8, 10_000e6);
        warpTo(Calendar.P);
        crankUntilIdle(v, 40); // short open with margin
        warpTo(Calendar.T + Calendar.H);
        // Advance to the margin-return intent (held: no auto-verify because we single-step).
        hub.setAuto(true, false, true);
        for (uint256 i = 0; i < 8; i++) {
            v.crank();
            if (intentKindOf(v) == B4VaultStorage.IntentKind.FromPerp) break;
        }
        assertEq(uint8(intentKindOf(v)), uint8(B4VaultStorage.IntentKind.FromPerp));

        pool.advance();
        pool.advance();
        uint256 id = pool.intervalCount() - 1;
        pool.lockPrices(id);
        // Settle while the transfer is in flight is rejected — no mid-flight valuation.
        vm.expectRevert(B4VaultStorage.IntentPending.selector);
        v.settle(id);

        // Reach idle, then settle values an exact NAV.
        hub.setAuto(true, true, true);
        crankUntilIdle(v, 20);
        v.settle(id);
        assertEq(v.lastSettledPlusOne(), id + 1);
    }

    /// The adversarial coincident-loss scenario made concrete: a real loss occurring
    /// while a transfer is in flight is reconciled once the engine reaches idle, BEFORE
    /// settle values NAV — no over-report, no over-fee.
    function test_A001_coincident_loss_reconciled_at_idle_before_settle() public {
        // Long 1 BTC, margin 2500, +5000 surplus already realized on the perp account
        // (withdrawable 7500) with a 5000 harvest quota recorded.
        hub.setPosition(address(h), PERP_MKT, 1e4, 90_000e6);
        hub.setWithdrawable(address(h), 7_500e6);
        h.setBuckets(0, 0, 0, 0, 0, 0, 2_500e6);
        h.setPendingHarvest(5_000e6);

        // Harvest the surplus to spot (completes: wd 7500 → 2500, +5000 rotated).
        h.startFromPerp(B4VaultStorage.Purpose.Harvest, 0);
        assertTrue(h.verify());
        assertEq(h.coreUsdcRotatedWei(), 5_000e8);
        assertEq(uint8(h.intentKind()), uint8(B4VaultStorage.IntentKind.None));

        // A liquidation now flattens the position and eats into principal while the
        // engine is idle: withdrawable 1000 < recorded margin 2500.
        hub.setPosition(address(h), PERP_MKT, 0, 0);
        hub.setWithdrawable(address(h), 1_000e6);

        // Reconcile at idle writes the real loss down BEFORE any valuation (B2). The
        // legitimately harvested 5000 stays; only the 1500 principal loss is realized.
        h.reconcile();
        assertEq(h.perpMargin6(), 1_000e6); // 2500 → 1000
        assertEq(h.navView(1e18), 6_000e18); // 1000 principal + 5000 harvested surplus
    }

    // =====================================================================
    // RAW-B-001: malformed ERC-20 return data must degrade to a soft failure — one
    // grief token can never revert the whole multi-token claim (D5).
    // =====================================================================

    function test_B001_tryTransfer_never_reverts_on_malformed_return() public {
        MalformedToken bad = new MalformedToken();
        bad.mint(address(this), 100e18);
        SafeTransferHarness st = new SafeTransferHarness();
        // Fail-before: abi.decode reverted the caller. Pass-after: clean false.
        assertFalse(st.tryIt(address(bad), address(0xB0B), 1e18));
    }

    function test_B001_pool_claim_isolates_malformed_token() public {
        // Pool with USDC + UBTC + a malformed-return token admitted as directional.
        MalformedToken bad = new MalformedToken();
        hub.registerToken(9, address(bad), 8, 2, 18, "BAD");
        hub.registerSpotMarket(9, 9, USDC_CORE);
        hub.setSpotPx(9, 4000e6);

        // Malformed token placed FIRST among directionals (index 1) so the test pins the
        // "continue past a failed transfer" property, not merely "last one may fail".
        CoreTypes.AssetDescriptor[] memory ds = new CoreTypes.AssetDescriptor[](3);
        ds[0] = usdcDescriptor();
        ds[1] = CoreTypes.AssetDescriptor({
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
        ds[2] = ubtcDescriptor();
        B4Pool p = new B4Pool(address(oracle), ds); // this test acts as factory
        MockVaultB mv = new MockVaultB(user);
        p.registerVault(address(mv));

        usdc.mint(address(p), 1_000e6);
        bad.mint(address(p), 50e18);
        ubtc.mint(address(p), 1e8);
        p.capture();

        warpTo(Calendar.P - Calendar.H);
        p.advance();
        p.lockPrices(0);
        vm.prank(address(mv));
        p.reportWeight(0, 1e18);
        vm.warp(block.timestamp + Calendar.SNAPSHOT_WINDOW + Calendar.REPORT_WINDOW + 1);

        // Fail-before: the whole claim reverted on the malformed token (index 1), so the
        // healthy UBTC after it (index 2) would never pay. Pass-after: both healthy tokens
        // pay; only the malformed token's claim defers.
        p.claimFor(0, address(mv));
        assertEq(usdc.balanceOf(user), 1_000e6);
        assertEq(ubtc.balanceOf(user), 1e8); // paid DESPITE preceding malformed token
        assertTrue(p.claimedOf(0, address(mv), 0));
        assertFalse(p.claimedOf(0, address(mv), 1)); // malformed: deferred, retryable (D5)
        assertTrue(p.claimedOf(0, address(mv), 2));
    }

    // =====================================================================
    // RAW-D writer scales: CoreWriter order fields are fixed-1e8, not read/lot units.
    // Exact-calldata assertions on the emitted action bytes.
    // =====================================================================

    function decodeOrder(bytes calldata raw)
        external
        pure
        returns (uint32 asset, bool isBuy, uint64 px8, uint64 sz8, bool ro, uint8 tif)
    {
        require(uint8(raw[0]) == 1 && uint8(raw[3]) == 1, "not a v1 limit order");
        (asset, isBuy, px8, sz8, ro, tif,) =
            abi.decode(raw[4:], (uint32, bool, uint64, uint64, bool, uint8, uint128));
    }

    function test_D_spot_order_encodes_fixed_1e8_units() public {
        hub.setAuto(false, true, true);
        hub.coreTopUp(address(h), UBTC_CORE, 1e8);
        h.setBuckets(0, 0, 0, 1e8, 0, 0, 0);
        h.startSpotOrder(false, 1e8); // sell 1 BTC, slippage 100 bps below $100k

        (, bytes memory raw,) = hub.queue(0);
        (uint32 asset, bool isBuy, uint64 px8, uint64 sz8, bool ro, uint8 tif) =
            this.decodeOrder(raw);
        assertEq(asset, CoreTypes.SPOT_ASSET_OFFSET + SPOT_MKT);
        assertFalse(isBuy);
        assertEq(px8, 99_000e8); // $99,000 × 1e8 — NOT the (8−szDec)-decimal read price
        assertEq(sz8, 1e8); // 1.0 BTC × 1e8 — NOT 1e4 lots
        assertFalse(ro);
        assertEq(tif, 3); // IOC
    }

    function test_D_perp_order_encodes_fixed_1e8_units() public {
        hub.setAuto(false, true, true);
        h.startPerpOrder(true, 6180, false); // open long 0.618 BTC at mark $100k

        (, bytes memory raw,) = hub.queue(0);
        (uint32 asset, bool isBuy, uint64 px8, uint64 sz8,,) = this.decodeOrder(raw);
        assertEq(asset, PERP_MKT);
        assertTrue(isBuy);
        assertEq(px8, 100_500e8); // mark +50 bps envelope, × 1e8 — NOT 2-decimal read px
        assertEq(sz8, 6180 * 1e4); // 0.618 BTC × 1e8 — NOT raw lots
    }

    /// Asymmetric szDecimals (≠ 4) so a matched engine+mock exponent bug can't hide at the
    /// self-dual point where 10^szDec == 10^(8−szDec).
    function test_D_writer_units_asymmetric_szDecimals() public {
        // SOL-shaped market: weiDec 8, szDec 2 ⇒ 1 lot = 1e-2 SOL; spot px 6 decimals.
        MockERC20 sol = new MockERC20("SOL", 18);
        hub.registerToken(11, address(sol), 8, 2, 18, "SOL");
        hub.registerSpotMarket(11, 11, USDC_CORE);
        hub.setSpotPx(11, 200e6); // $200, (8−2)=6 px decimals
        CoreTypes.AssetDescriptor memory d = CoreTypes.AssetDescriptor({
            evmToken: address(sol),
            evmDecimals: 18,
            coreToken: 11,
            spotMarket: 11,
            perpMarket: CoreTypes.NO_MARKET,
            coreWeiDecimals: 8,
            spotSzDecimals: 2,
            perpSzDecimals: 0,
            perpMaxLeverage: 0,
            fixedUsd: false
        });
        EngineHarness he = new EngineHarness();
        he.setup(d, usdcDescriptor(), address(oracle));
        hub.setUserExists(address(he), true);
        hub.setAuto(false, true, true);
        hub.coreTopUp(address(he), 11, 100e8); // 100 SOL = 1e4 lots
        he.setBuckets(0, 0, 0, 100e8, 0, 0, 0);
        he.startSpotOrder(false, 100e8); // sell 100 SOL

        (, bytes memory raw,) = hub.queue(0);
        (,, uint64 px8, uint64 sz8,,) = this.decodeOrder(raw);
        // 100.0 SOL ⇒ sz8 = 100e8 (from 1e4 lots × 10^6), NOT 1e4 lots and NOT 100e4.
        assertEq(sz8, 100e8);
        assertEq(px8, 198e8); // $200 − 100 bps = $198, × 1e8
    }

    /// A micro-priced asset held in the tens of millions of USD: the fixed-1e8 size field
    /// would overflow uint64 — the conversion must CLAMP the lots, not revert, so the
    /// crank/flatten still makes progress (chunked across cranks; A10 still reachable).
    function test_D_writer_units_no_overflow_micro_asset() public {
        // PURR-shaped micro asset: coreWei 5, szDec 0 ⇒ sz8 = wei·10^3, so a large
        // (~$18M) balance drives lots·10^8 past uint64.max.
        MockERC20 micro = new MockERC20("MICRO", 6);
        hub.registerToken(12, address(micro), 5, 0, 6, "MICRO");
        hub.registerSpotMarket(12, 12, USDC_CORE);
        hub.setSpotPx(12, 1e4); // $0.0001, (8−0)=8 px decimals
        CoreTypes.AssetDescriptor memory d = CoreTypes.AssetDescriptor({
            evmToken: address(micro),
            evmDecimals: 6,
            coreToken: 12,
            spotMarket: 12,
            perpMarket: CoreTypes.NO_MARKET,
            coreWeiDecimals: 5,
            spotSzDecimals: 0,
            perpSzDecimals: 0,
            perpMaxLeverage: 0,
            fixedUsd: false
        });
        EngineHarness he = new EngineHarness();
        he.setup(d, usdcDescriptor(), address(oracle));
        hub.setUserExists(address(he), true);
        hub.setAuto(false, true, true);
        uint64 huge = 2e16; // 2e16 wei = 2e11 tokens ≈ $20M at $0.0001; sz = 2e11 lots
        hub.coreTopUp(address(he), 12, huge);
        he.setBuckets(0, 0, 0, huge, 0, 0, 0);
        // Fail-before: lots·10^8 (2e11·1e8 = 2e19) Panics(0x11). Pass-after: clamped order.
        he.startSpotOrder(false, huge);
        (, bytes memory raw,) = hub.queue(0);
        (,,, uint64 sz8,,) = this.decodeOrder(raw);
        uint64 maxLots = type(uint64).max / 1e8;
        assertEq(sz8, maxLots * 1e8); // clamped to the sz8 ceiling, no revert
        assertGt(sz8, 0);

        // Execute the clamped order and confirm accounting is exact on the MEASURED
        // delta: coreDir debited by the filled base wei, USDC credited, and the residual
        // (unfilled portion) stays recorded for re-derivation — no over/under-credit.
        hub.executeActions();
        assertTrue(he.verify());
        uint64 filledLots = maxLots; // full fill of the clamped size
        uint64 filledWei = filledLots * uint64(10 ** (5 - 0)); // 1 lot = 10^5 wei (weiDec 5)
        assertEq(he.coreDirWei(), huge - filledWei); // residual left recorded
        // Credit = filledLots·px at $0.0001 (spot px raw 1e4, 8 decimals ⇒ $1e-4).
        assertEq(he.coreUsdcRotatedWei(), uint64(uint256(filledLots) * 1e4));
        assertGe(hub.spotBal(address(he), USDC_CORE), he.coreUsdcRotatedWei()); // books ≤ real
    }

    /// The generic reduce loop reaches RAW ZERO in one clamped-conversion step for a
    /// normal position (A10). The clamp on the PERP side is an unreachable backstop: a
    /// position exceeding maxLots (~1.8e15 lots) would need >$10¹⁶ notional, impossible
    /// under the margin·maxLev/φ reserve — so only the SPOT path (micro-priced assets,
    /// tested above with execution) can actually reach the clamp.
    function test_D_perp_reduce_reaches_raw_zero_normal_size() public {
        hub.setAuto(true, true, true);
        hub.setPosition(address(h), PERP_MKT, 6180, 61_800e6); // ~0.618 BTC long
        hub.setWithdrawable(address(h), 2_500e6);
        h.setBuckets(0, 0, 0, 0, 0, 0, 2_500e6);
        h.startPerpOrder(false, 6180, true); // reduce-only full close
        assertTrue(h.verify());
        (int64 finalSzi,,) = hub.positions(address(h), PERP_MKT);
        assertEq(finalSzi, 0); // exact raw zero — no dust from the 1e8 conversion
    }

    function test_D_binding_rejects_bad_decimals_and_widths() public {
        CoreTypes.AssetDescriptor[] memory one = new CoreTypes.AssetDescriptor[](1);

        // spotSzDecimals > 8
        CoreTypes.AssetDescriptor memory d = ubtcDescriptor();
        d.spotSzDecimals = 9;
        one[0] = d;
        vm.expectRevert(DescriptorLib.DecimalsMismatch.selector);
        factory.createPool(one);

        // perpSzDecimals > 6
        d = ubtcDescriptor();
        d.perpSzDecimals = 7;
        one[0] = d;
        vm.expectRevert(DescriptorLib.PerpMismatch.selector);
        factory.createPool(one);

        // NO_MARKET with nonzero perp fields
        d = ubtcDescriptor();
        d.perpMarket = CoreTypes.NO_MARKET;
        d.perpSzDecimals = 4; // stale, must be zeroed
        one[0] = d;
        vm.expectRevert(DescriptorLib.PerpMismatch.selector);
        factory.createPool(one);
    }

    // =====================================================================
    // RAW-D NO_MARKET: a spot-only descriptor must run every lifecycle path without
    // ever touching the position precompile (the mock now reverts on invalid ids —
    // the fail-before build bricked on the very first crank).
    // =====================================================================

    MockERC20 soltoken;

    function spotOnlyDescriptor() internal returns (CoreTypes.AssetDescriptor memory d) {
        hub.registerToken(7, address(soltoken), 8, 2, 18, "SOL");
        hub.registerSpotMarket(7, 7, USDC_CORE);
        hub.setSpotPx(7, 200e6); // $200, (8−2)=6 px decimals
        d = CoreTypes.AssetDescriptor({
            evmToken: address(soltoken),
            evmDecimals: 18,
            coreToken: 7,
            spotMarket: 7,
            perpMarket: CoreTypes.NO_MARKET,
            coreWeiDecimals: 8,
            spotSzDecimals: 2,
            perpSzDecimals: 0,
            perpMaxLeverage: 0,
            fixedUsd: false
        });
    }

    function test_D_spot_only_vault_full_lifecycle() public {
        soltoken = new MockERC20("SOL", 18); // bridge-aware mock: EVM→Core credits work
        CoreTypes.AssetDescriptor[] memory dirs = new CoreTypes.AssetDescriptor[](1);
        dirs[0] = spotOnlyDescriptor();
        B4Pool p2 = B4Pool(factory.createPool(dirs));

        vm.prank(user);
        B4Vault v = B4Vault(
            factory.createVault(
                address(p2),
                CoreTypes.descriptorHash(dirs[0]),
                address(b4),
                1e18,
                100,
                defaultRoute()
            )
        );
        soltoken.mint(user, 100e18);
        vm.startPrank(user);
        soltoken.approve(address(v), 100e18);
        v.deposit(100e18, 0); // $20,000
        vm.stopPrank();

        // Crank through growth (no-op) and the rotation at the crossing — every step
        // must survive without a position read.
        crankUntilIdle(v, 10);
        warpTo(Calendar.P - Calendar.H);
        crankUntilIdle(v, 30);
        assertEq(v.dirEvm(), 0);
        assertEq(v.usdcRotatedEvm(), 20_000e6);

        // Settle (wrong-sign gate skipped for a perp-less vault).
        p2.advance();
        p2.lockPrices(0);
        v.settle(0);
        assertEq(v.entryLedgerWad(), 20_000e18);

        // Partial exit inside the free transition zone.
        vm.prank(user);
        v.initiateExit(5e17);
        crankUntilIdle(v, 10);
        assertEq(v.exitShareWad(), 0);
        assertGt(usdc.balanceOf(user), 0);

        // Recovery guards work without a perp market.
        vm.prank(user);
        vm.expectRevert(B4VaultStorage.NothingToRecover.selector);
        v.recoverPerpSurplus();
    }

    /// A perp-bearing policy (Pro) on a spot-only vault degrades to its spot component:
    /// the fall regime rotates to USDC (no short), owner USDC margin sits inert but is
    /// paid at exit, and an external perp top-up is still recoverable — all without
    /// touching a perp market. (Documented degradation, ARCHITECTURE.md.)
    function test_D_spot_only_perp_policy_degrades_and_recovers() public {
        soltoken = new MockERC20("SOL", 18);
        CoreTypes.AssetDescriptor[] memory dirs = new CoreTypes.AssetDescriptor[](1);
        dirs[0] = spotOnlyDescriptor();
        B4Pool p2 = B4Pool(factory.createPool(dirs));

        vm.prank(user);
        B4Vault v = B4Vault(
            factory.createVault(
                address(p2),
                CoreTypes.descriptorHash(dirs[0]),
                address(pro),
                1e18,
                100,
                defaultRoute()
            )
        );
        soltoken.mint(user, 100e18);
        usdc.mint(user, 5_000e6);
        vm.startPrank(user);
        soltoken.approve(address(v), 100e18);
        usdc.approve(address(v), 5_000e6);
        v.deposit(100e18, 5_000e6); // $20,000 dir + $5,000 owner margin
        vm.stopPrank();

        // Fall regime: spot component is 0 ⇒ rotate the directional to USDC; the perp
        // short (−1) is inexpressible and simply skipped — no perp market ever touched.
        warpTo(Calendar.P);
        crankUntilIdle(v, 30);
        assertEq(v.dirEvm(), 0);
        assertEq(v.usdcRotatedEvm(), 20_000e6);
        assertEq(v.perpMargin6(), 0); // never allocated
        assertEq(v.usdcMarginEvm(), 5_000e6); // owner margin inert, still accounted

        // An external Core perp top-up is recoverable via the two-phase path (uses the
        // user-level usd-class-transfer, no perp market id).
        hub.addWithdrawable(address(v), 250e6);
        vm.prank(user);
        v.recoverPerpSurplus();
        crankUntilIdle(v, 5);
        assertEq(usdc.balanceOf(user), 250e6);

        // Full exit at the fall plateau (non-free) pays out the inert margin too, less
        // the single penalty on the whole 25k NAV. Owner ≈ 25k·(1−q) + 250 recovery ≈
        // 22,300 — decisively above the 17,890 it would be if margin were NOT included.
        vm.prank(user);
        v.initiateExit(1e18);
        crankUntilIdle(v, 10);
        assertEq(v.exitShareWad(), 0);
        assertGt(usdc.balanceOf(user), 22_000e6); // margin was in the payout basket
        assertLt(usdc.balanceOf(user), 22_500e6);
    }

    // =====================================================================
    // RAW-D HIP-3 width: an extended perp id (> uint16) must be rejected at binding —
    // the legacy position read would silently alias an unrelated market.
    // =====================================================================

    function test_D_hip3_wide_perp_id_rejected() public {
        CoreTypes.AssetDescriptor memory d = ubtcDescriptor();
        d.perpMarket = 70_000; // beyond uint16
        CoreTypes.AssetDescriptor[] memory dirs = new CoreTypes.AssetDescriptor[](1);
        dirs[0] = d;
        vm.expectRevert(DescriptorLib.PerpIdUnsupported.selector);
        factory.createPool(dirs);
    }
}
