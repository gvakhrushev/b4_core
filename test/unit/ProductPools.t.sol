// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {B4Factory} from "src/core/B4Factory.sol";
import {B4ProductFactory} from "src/core/B4ProductFactory.sol";
import {B4ProductPoolCreator} from "src/core/B4ProductPoolCreator.sol";
import {B4Pool} from "src/core/B4Pool.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {B4VaultStorage} from "src/core/B4VaultStorage.sol";
import {HalvingOracle} from "src/core/HalvingOracle.sol";
import {Keeper} from "src/periphery/Keeper.sol";
import {Phi} from "src/libraries/Phi.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {StructuralLeverage} from "src/libraries/StructuralLeverage.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";
import {Origin} from "src/interfaces/ILayerZero.sol";
import {MockERC20} from "../mocks/MockCore.sol";

/// @notice Product-domain regression suite. It covers all five user-facing pool
///         choices: four isolated masks and the explicit aggregate mask 15.
contract ProductPoolsTest is VaultTestBase {
    B4ProductFactory productFactory;
    address[4] strategies;

    uint256 constant DIR = 1;

    function setUp() public {
        setUpProtocol();
        productFactory = new B4ProductFactory(
            address(oracle), usdcDescriptor(), factory.vaultImplementation(), address(poolDeployer)
        );
        strategies = [address(mini), address(b4), address(pro), address(proMax)];
    }

    function _productPool(uint8 mask) internal returns (B4Pool p) {
        CoreTypes.AssetDescriptor[] memory dirs = new CoreTypes.AssetDescriptor[](1);
        dirs[0] = ubtcDescriptor();
        p = B4Pool(productFactory.createProductPool(dirs, strategies, mask));
    }

    function _twoAssetProductPool(uint8 mask) internal returns (B4Pool p, MockERC20 ueth) {
        ueth = new MockERC20("UETH", 18);
        uint64 uethCore = 2;
        uint32 uethSpot = 6;
        hub.registerToken(uethCore, address(ueth), 8, 2, 18, "UETH");
        hub.registerSpotMarket(uethSpot, uethCore, USDC_CORE);
        hub.setSpotPx(uethSpot, 4_000e6);

        CoreTypes.AssetDescriptor[] memory dirs = new CoreTypes.AssetDescriptor[](2);
        dirs[0] = ubtcDescriptor();
        dirs[1] = CoreTypes.AssetDescriptor({
            evmToken: address(ueth),
            evmDecimals: 18,
            coreToken: uethCore,
            spotMarket: uethSpot,
            perpMarket: CoreTypes.NO_MARKET,
            coreWeiDecimals: 8,
            spotSzDecimals: 2,
            perpSzDecimals: 0,
            perpMaxLeverage: 0,
            fixedUsd: false
        });
        p = B4Pool(productFactory.createProductPool(dirs, strategies, mask));
    }

    function _createProductVault(B4Pool p, address strategy, address owner_)
        internal
        returns (B4Vault v)
    {
        vm.prank(owner_);
        v = B4Vault(
            productFactory.createVault(
                address(p),
                CoreTypes.descriptorHash(ubtcDescriptor()),
                strategy,
                Phi.WAD,
                100,
                B4VaultStorage.FeeRoute(address(0), 0, address(0), 0)
            )
        );
    }

    function _fundAndDeposit(B4Vault v, address owner_, uint256 dirAmount, uint256 usdcAmount)
        internal
    {
        if (dirAmount != 0) ubtc.mint(owner_, dirAmount);
        if (usdcAmount != 0) usdc.mint(owner_, usdcAmount);
        vm.startPrank(owner_);
        if (dirAmount != 0) ubtc.approve(address(v), dirAmount);
        if (usdcAmount != 0) usdc.approve(address(v), usdcAmount);
        v.deposit(dirAmount, usdcAmount);
        vm.stopPrank();
    }

    function _crankSleeve(B4Pool p, uint8 policy) internal {
        for (uint256 i = 0; i < 120; i++) {
            if (!p.crankSleeve(policy, DIR)) break;
        }
    }

    function _setPx(uint256 usd) internal {
        hub.setSpotPx(SPOT_MKT, uint64(usd * 1e4));
        hub.setMarkPx(PERP_MKT, uint64(usd * 1e2));
        hub.setOraclePx(PERP_MKT, uint64(usd * 1e2));
    }

    function _samplePeak(B4Pool p, uint256 start, uint256 px) internal {
        for (uint256 i = 0; i < 11; i++) {
            vm.warp(start + i * 1 days);
            _setPx(px);
            p.sampleAnchor(DIR);
        }
    }

    function _sampleLow(B4Pool p, uint256 start, uint256 px) internal {
        for (uint256 i = 0; i < 11; i++) {
            vm.warp(start + i * 1 days);
            _setPx(px);
            p.sampleAnchor(DIR);
        }
    }

    /// @dev Establish `prevPeak = 1k`, then the new cycle's confirmed `C = 5k`.
    function _prepareConfirmedPeaks(B4Pool p) internal returns (uint256 hts) {
        _samplePeak(p, GENESIS_TS + Calendar.P - Calendar.W + 1 days, 1_000);
        hts = GENESIS_TS + Calendar.T + Calendar.W + 30 days;
        vm.warp(hts);
        acceptHalving(GENESIS_HEIGHT + 210_000, uint32(hts));
        vm.warp(hts + 1 days);
        _setPx(1_000);
        p.sampleAnchor(DIR); // halving flip promotes the confirmed previous peak
        _samplePeak(p, hts + Calendar.P - Calendar.W + 1 days, 5_000);
        (uint256 prevPeak, uint256 peakC,) = p.peaks(DIR);
        assertEq(prevPeak, 1_000e18, "previous peak promoted");
        assertEq(peakC, 5_000e18, "current peak confirmed");
    }

    /// @dev Establish `floor = 500`, then the next cycle's confirmed 62-low `B = 2k`.
    function _prepareConfirmedLows(B4Pool p) internal returns (uint256 hts) {
        _sampleLow(p, GENESIS_TS + Calendar.T + 1 days, 500);
        hts = GENESIS_TS + Calendar.T + Calendar.W + 30 days;
        vm.warp(hts);
        acceptHalving(GENESIS_HEIGHT + 210_000, uint32(hts));
        vm.warp(hts + 1 days);
        _setPx(500);
        p.sampleAnchor(DIR); // halving flip promotes the confirmed previous low
        _sampleLow(p, hts + Calendar.T + 1 days, 2_000);
        (uint256 floor_, uint256 cap_) = p.anchors(DIR);
        assertEq(floor_, 500e18, "previous 62-low promoted");
        assertEq(cap_, 2_000e18, "current 62-low confirmed");
    }

    function test_five_pool_choices_and_upgrade_rule() public {
        B4Pool miniPool = _productPool(1);
        B4Pool b4Pool = _productPool(2);
        B4Pool proPool = _productPool(4);
        B4Pool maxPool = _productPool(8);
        B4Pool aggregate = _productPool(15);

        assertEq(miniPool.policyMask(), 1);
        assertEq(b4Pool.policyMask(), 2);
        assertEq(proPool.policyMask(), 4);
        assertEq(maxPool.policyMask(), 8);
        assertEq(aggregate.policyMask(), 15);
        for (uint8 policy = 1; policy <= 4; policy++) {
            assertTrue(aggregate.sleeveOf(policy, DIR) != address(0), "aggregate sleeve missing");
        }

        // An isolated Mini pool cannot silently become Pro.
        vm.prank(user);
        vm.expectRevert();
        productFactory.createVault(
            address(miniPool),
            CoreTypes.descriptorHash(ubtcDescriptor()),
            address(pro),
            Phi.WAD,
            100,
            B4VaultStorage.FeeRoute(address(0), 0, address(0), 0)
        );

        // Aggregate capital may upgrade in place; reverse movement must exit/re-enter.
        B4Vault v = _createProductVault(aggregate, address(mini), user);
        assertEq(aggregate.policyOfVault(address(v)), 1);
        vm.prank(user);
        v.selectPolicy(address(proMax), Phi.WAD);
        assertEq(aggregate.policyOfVault(address(v)), 4);
        vm.prank(user);
        vm.expectRevert(B4VaultStorage.BadPolicy.selector);
        v.selectPolicy(address(pro), Phi.WAD);
    }

    function test_partial_mixed_masks_are_not_an_undocumented_sixth_product() public {
        CoreTypes.AssetDescriptor[] memory dirs = new CoreTypes.AssetDescriptor[](1);
        dirs[0] = ubtcDescriptor();
        vm.expectRevert();
        productFactory.createProductPool(dirs, strategies, 3); // Mini + B4 is not one of the five choices
    }

    function test_pool_creation_requires_proven_oracle_bootstrap() public {
        HalvingOracle fresh = new HalvingOracle(
            address(endpoint), SRC_EID, SRC_SENDER, GENESIS_HEIGHT, address(this)
        );
        address impl = factory.vaultImplementation();
        B4Factory legacy =
            new B4Factory(address(fresh), usdcDescriptor(), impl, address(poolDeployer));
        B4ProductFactory strict =
            new B4ProductFactory(address(fresh), usdcDescriptor(), impl, address(poolDeployer));

        CoreTypes.AssetDescriptor[] memory dirs = new CoreTypes.AssetDescriptor[](1);
        dirs[0] = ubtcDescriptor();

        vm.expectRevert(B4Factory.OracleNotBootstrapped.selector);
        legacy.createPool(dirs);
        vm.expectRevert(B4ProductFactory.OracleNotBootstrapped.selector);
        strict.createProductPool(dirs, strategies, 1);

        bytes memory h = new bytes(80);
        h[68] = bytes1(uint8(GENESIS_TS));
        h[69] = bytes1(uint8(GENESIS_TS >> 8));
        h[70] = bytes1(uint8(GENESIS_TS >> 16));
        h[71] = bytes1(uint8(GENESIS_TS >> 24));
        vm.prank(address(endpoint));
        fresh.lzReceive(
            Origin(SRC_EID, SRC_SENDER, 1),
            bytes32(0),
            abi.encode(GENESIS_HEIGHT, h),
            address(0),
            ""
        );

        address legacyPool = legacy.createPool(dirs);
        address strictPool = strict.createProductPool(dirs, strategies, 1);
        assertTrue(legacy.isPool(legacyPool), "legacy pool registered after bootstrap");
        assertTrue(strict.isPool(strictPool), "product pool registered after bootstrap");
    }

    function test_pro_penalty_uses_its_own_sleeve_and_current_stop() public {
        B4Pool p = _productPool(4); // isolated Pro
        B4Vault v = _createProductVault(p, address(pro), user);

        // Deposit before the pivot, build a density-confirmed 5k peak, then open
        // at 6k in Fall. Pro's current stop is max(2p, C) = 12k.
        warpTo(Calendar.P - Calendar.W + 1 days);
        _setPx(5_000);
        _fundAndDeposit(v, user, 0, 100_000e6);
        _samplePeak(p, GENESIS_TS + Calendar.P - Calendar.W + 1 days, 5_000);
        warpTo(Calendar.P + 30 days);
        _setPx(6_000);
        crankUntilIdle(v, 120);
        uint256 expected = 12_000e18;
        assertEq(v.perpStopWad(), expected, "user Pro stop");

        vm.prank(user);
        v.initiateExit(Phi.WAD);
        crankUntilIdle(v, 160);
        uint256 penalty = p.penaltyEscrow(3, DIR, 0);
        assertGt(penalty, 0, "USDC penalty held for Pro");
        assertEq(p.accruing(0), 0, "penalty is not prematurely distributable");
        assertEq(p.escrowHeld(address(usdc)), penalty, "escrow excluded from liabilities");

        assertTrue(p.foldPenalty(3, DIR), "folded into Pro sleeve");
        _crankSleeve(p, 3);
        B4Vault sleeve = B4Vault(p.sleeveOf(3, DIR));
        assertEq(sleeve.perpStopWad(), expected, "sleeve uses exact current Pro stop");
        assertLt(readPos(address(sleeve)).szi, 0, "sleeve is a short, not passive inventory");
        assertEq(p.escrowHeld(address(usdc)), 0, "physical escrow transferred once");
    }

    function test_pro_deep_short_penalty_is_pinned_to_the_confirmed_5k_peak() public {
        B4Pool p = _productPool(4);
        _samplePeak(p, GENESIS_TS + Calendar.P - Calendar.W + 1 days, 5_000);
        B4Vault v = _createProductVault(p, address(pro), user);
        warpTo(Calendar.P + 30 days);
        _setPx(2_000);
        _fundAndDeposit(v, user, 0, 100_000e6);
        crankUntilIdle(v, 120);
        assertEq(v.perpStopWad(), 5_000e18, "Pro stop cannot fall below confirmed peak");

        vm.prank(user);
        v.initiateExit(Phi.WAD);
        crankUntilIdle(v, 160);
        p.foldPenalty(3, DIR);
        _crankSleeve(p, 3);
        assertEq(B4Vault(p.sleeveOf(3, DIR)).perpStopWad(), 5_000e18, "same deep Pro stop");
    }

    function test_aggregate_keeps_pro_penalty_in_pro_sleeve_until_free_window_exit() public {
        B4Pool p = _productPool(15);
        B4Vault v = _createProductVault(p, address(pro), user);

        warpTo(Calendar.P - Calendar.W + 1 days);
        _setPx(5_000);
        _fundAndDeposit(v, user, 0, 100_000e6);
        _samplePeak(p, GENESIS_TS + Calendar.P - Calendar.W + 1 days, 5_000);
        warpTo(Calendar.P + 30 days);
        _setPx(6_000);
        crankUntilIdle(v, 120);

        vm.prank(user);
        v.initiateExit(Phi.WAD);
        crankUntilIdle(v, 160);
        uint256 penalty = p.penaltyEscrow(3, DIR, 0);
        assertGt(penalty, 0, "Pro penalty captured");
        assertEq(p.penaltyEscrow(4, DIR, 0), 0, "Pro Max receives no Pro capital");

        p.foldPenalty(3, DIR);
        _crankSleeve(p, 3);
        B4Vault proSleeve = B4Vault(p.sleeveOf(3, DIR));
        B4Vault maxSleeve = B4Vault(p.sleeveOf(4, DIR));
        assertEq(proSleeve.perpStopWad(), 12_000e18, "Pro sleeve has the Pro stop");
        assertEq(maxSleeve.perpStopWad(), 0, "unfunded Pro Max sleeve never trades Pro capital");
        assertEq(p.accruing(0), 0, "live sleeve capital is not yet a common claim");

        // `T` starts the closing-fall free-exit zone. Only here can this sleeve
        // realise into the aggregate claim basket.
        warpTo(Calendar.T);
        _setPx(2_000);
        assertTrue(p.initiateSleeveExit(3, DIR), "free-window sleeve exit begins");
        for (uint256 i = 0; i < 220; i++) {
            if (!p.crankSleeve(3, DIR)) break;
        }
        assertEq(proSleeve.exitShareWad(), 0, "sleeve fully exits");
        assertGt(p.accruing(0), 0, "realised sleeve proceeds join common claims");
    }

    function test_keeper_folds_and_cranks_the_strict_product_sleeve() public {
        B4Pool p = _productPool(4);
        B4Vault v = _createProductVault(p, address(pro), user);
        warpTo(Calendar.P - Calendar.W + 1 days);
        _setPx(5_000);
        _fundAndDeposit(v, user, 0, 100_000e6);
        _samplePeak(p, GENESIS_TS + Calendar.P - Calendar.W + 1 days, 5_000);
        warpTo(Calendar.P + 30 days);
        _setPx(6_000);
        crankUntilIdle(v, 120);

        vm.prank(user);
        v.initiateExit(Phi.WAD);
        crankUntilIdle(v, 160);
        assertGt(p.penaltyEscrow(3, DIR, 0), 0, "penalty awaits a permissionless fold");

        Keeper keeper = new Keeper();
        address[] memory none = new address[](0);
        keeper.crank(p, none, 120);
        B4Vault sleeve = B4Vault(p.sleeveOf(3, DIR));
        assertEq(p.penaltyEscrow(3, DIR, 0), 0, "keeper folded exact escrow once");
        assertEq(sleeve.perpStopWad(), 12_000e18, "keeper preserves the Pro structural stop");
    }

    /// Only the exiting vault's whitelisted pair (settlement + its directional asset) is a
    /// penalty. A co-listed whitelisted token donated to the pool remains a generic donation,
    /// never an unreachable `(policy, direction, other-token)` escrow slot.
    function test_non_matching_whitelisted_token_stays_generic_inventory() public {
        (B4Pool p, MockERC20 ueth) = _twoAssetProductPool(15);
        B4Vault v = _createProductVault(p, address(mini), user);

        warpTo(100 days); // deposits open; exit is non-free
        _setPx(110_000);
        _fundAndDeposit(v, user, 1e8, 0);
        uint256 donation = 5e18;
        ueth.mint(address(p), donation);

        vm.prank(user);
        v.initiateExit(Phi.WAD);
        crankUntilIdle(v, 20);

        assertEq(p.penaltyEscrow(1, DIR, 2), 0, "other whitelisted asset is never penalty escrow");
        assertEq(p.escrowHeld(address(ueth)), 0, "generic donation is not sleeve-held");
        assertEq(p.accruing(2), donation, "other whitelisted asset becomes ordinary inventory");
        assertEq(p.liability(address(ueth)), donation, "ordinary donation liability recorded once");
    }

    function test_pro_max_shallow_short_penalty_keeps_the_confirmed_7472_stop() public {
        B4Pool p = _productPool(8);
        uint256 hts = _prepareConfirmedPeaks(p);
        B4Vault v = _createProductVault(p, address(proMax), user);
        vm.warp(hts + Calendar.P + 30 days);
        _setPx(6_000);
        _fundAndDeposit(v, user, 0, 100_000e6);
        crankUntilIdle(v, 160);
        uint256 expected = StructuralLeverage.shortStructStop(6_000e18, 1_000e18, 5_000e18);
        assertEq(expected, 7_472_135_954_999_579_392_000, "exact phi stop");
        assertEq(v.perpStopWad(), expected, "user short stop");

        vm.prank(user);
        v.initiateExit(Phi.WAD);
        crankUntilIdle(v, 180);
        p.foldPenalty(4, DIR);
        _crankSleeve(p, 4);
        assertEq(B4Vault(p.sleeveOf(4, DIR)).perpStopWad(), expected, "same Pro Max stop");
    }

    function test_pro_max_deep_short_penalty_never_moves_inside_the_5k_peak() public {
        B4Pool p = _productPool(8);
        uint256 hts = _prepareConfirmedPeaks(p);
        B4Vault v = _createProductVault(p, address(proMax), user);
        vm.warp(hts + Calendar.P + 30 days);
        _setPx(2_000);
        _fundAndDeposit(v, user, 0, 100_000e6);
        crankUntilIdle(v, 160);
        uint256 expected = StructuralLeverage.shortStructStop(2_000e18, 1_000e18, 5_000e18);
        assertGe(expected, 5_000e18, "structural stop remains outside confirmed peak");
        assertEq(v.perpStopWad(), expected, "deep user stop");

        vm.prank(user);
        v.initiateExit(Phi.WAD);
        crankUntilIdle(v, 180);
        p.foldPenalty(4, DIR);
        _crankSleeve(p, 4);
        assertEq(B4Vault(p.sleeveOf(4, DIR)).perpStopWad(), expected, "same deep Pro Max stop");
    }

    function test_pro_max_long_penalty_uses_the_confirmed_62_minimum_stop() public {
        B4Pool p = _productPool(8);
        uint256 hts = _prepareConfirmedLows(p);
        B4Vault v = _createProductVault(p, address(proMax), user);
        vm.warp(hts + Calendar.T + Calendar.W + 5 days);
        _setPx(5_000);
        _fundAndDeposit(v, user, 0, 100_000e6);
        crankUntilIdle(v, 160);
        uint256 expected = StructuralLeverage.longStop(5_000e18, 500e18, 2_000e18);
        assertGt(expected, 0, "long stop present");
        assertLe(expected, 2_000e18, "never above confirmed 62 low");
        assertEq(v.perpStopWad(), expected, "user long stop");

        vm.prank(user);
        v.initiateExit(Phi.WAD);
        crankUntilIdle(v, 180);
        p.foldPenalty(4, DIR);
        _crankSleeve(p, 4);
        B4Vault sleeve = B4Vault(p.sleeveOf(4, DIR));
        assertTrue(sleeve.perpStopLong(), "sleeve remains a long");
        assertEq(sleeve.perpStopWad(), expected, "same confirmed-minimum stop");
    }

    function test_post_halving_twenty_day_window_has_no_penalty_to_transfer() public {
        B4Pool p = _productPool(8);
        B4Vault v = _createProductVault(p, address(proMax), user);
        warpTo(10 days); // Calendar.POST_FACT_FREE_EXIT = 20 days
        _setPx(10_000);
        _fundAndDeposit(v, user, 0, 100_000e6);
        crankUntilIdle(v, 120);
        vm.prank(user);
        v.initiateExit(Phi.WAD);
        crankUntilIdle(v, 180);
        assertEq(p.penaltyEscrow(4, DIR, 0), 0, "post-halving exits are free by protocol rule");
        assertEq(p.penaltyEscrow(4, DIR, DIR), 0, "no directional penalty either");
    }

    function test_pro_max_penalty_reopens_the_same_structural_long() public {
        B4Pool p = _productPool(8); // isolated Pro Max
        B4Vault v = _createProductVault(p, address(proMax), user);

        // Terminal growth is outside every free-exit window. With no confirmed low
        // anchor the exact engine fallback is the φ structural long at p/φ²; the
        // equality below is deliberately between the user and the sleeve, not a
        // duplicated formula in the test.
        warpTo(Calendar.T + Calendar.W + 5 days);
        _setPx(10_000);
        _fundAndDeposit(v, user, 0, 100_000e6);
        crankUntilIdle(v, 120);
        uint256 userStop = v.perpStopWad();
        assertTrue(v.perpStopLong(), "user Pro Max long");
        assertGt(userStop, 0, "structural stop armed");

        vm.prank(user);
        v.initiateExit(Phi.WAD);
        crankUntilIdle(v, 180);
        assertGt(p.penaltyEscrow(4, DIR, 0), 0, "penalty assigned to Pro Max only");

        p.foldPenalty(4, DIR);
        _crankSleeve(p, 4);
        B4Vault sleeve = B4Vault(p.sleeveOf(4, DIR));
        assertTrue(sleeve.perpStopLong(), "sleeve retains long side");
        assertEq(sleeve.perpStopWad(), userStop, "same live StructuralLeverage stop");
        assertGt(readPos(address(sleeve)).szi, 0, "sleeve opened the Pro Max long");
    }

    function test_product_modules_fit_eip170() public pure {
        assertLt(type(B4ProductPoolCreator).runtimeCode.length, 24_576, "product pool creator size");
    }

    function readPos(address who) internal view returns (CoreTypes.Position memory) {
        (bool ok, bytes memory ret) =
            CoreTypes.PRECOMPILE_POSITION.staticcall(abi.encode(who, uint16(PERP_MKT)));
        require(ok, "read pos");
        return abi.decode(ret, (CoreTypes.Position));
    }
}
