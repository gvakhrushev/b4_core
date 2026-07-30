// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {VenueTestBase} from "../utils/VenueTestBase.sol";
import {MockLzEndpoint} from "../mocks/MockLzEndpoint.sol";
import {HalvingOracle} from "src/core/HalvingOracle.sol";
import {B4ProductFactory} from "src/core/B4ProductFactory.sol";
import {B4Pool} from "src/core/B4Pool.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {B4VaultOps} from "src/core/B4VaultOps.sol";
import {B4VaultRecovery} from "src/core/B4VaultRecovery.sol";
import {B4VaultStorage} from "src/core/B4VaultStorage.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {Phi} from "src/libraries/Phi.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";
import {Origin} from "src/interfaces/ILayerZero.sol";
import {
    StrategyMini,
    StrategyB4,
    StrategyPro,
    StrategyProMax
} from "src/periphery/ReferenceStrategies.sol";

/// @notice Contract-level proof of the pool flow used by the population simulator.
/// The numbers intentionally mirror the worked Mini example: 10 equal $1k users,
/// two penalized exits, eight equal-weight stayers, then BTC $1k -> $4k -> $5k.
contract PoolClaimFlowTest is Test, VenueTestBase {
    uint32 internal constant SRC_EID = 30_101;
    bytes32 internal constant SRC_SENDER = bytes32(uint256(1));
    uint256 internal constant HALVING_HEIGHT = 210_000;
    uint256 internal constant HALVING_TS = 1_354_116_278;
    uint256 internal constant USER_DEPOSIT_WAD = 1_000e18;

    MockLzEndpoint internal endpoint;
    HalvingOracle internal oracle;
    B4ProductFactory internal factory;
    B4Pool internal pool;
    address[4] internal strategies;

    function setUp() public {
        vm.warp(HALVING_TS);
        setUpVenue();
        endpoint = new MockLzEndpoint();
        oracle = new HalvingOracle(
            address(endpoint), SRC_EID, SRC_SENDER, HALVING_HEIGHT, address(this)
        );
        bytes memory genesisHeader = new bytes(80);
        genesisHeader[68] = bytes1(uint8(HALVING_TS));
        genesisHeader[69] = bytes1(uint8(HALVING_TS >> 8));
        genesisHeader[70] = bytes1(uint8(HALVING_TS >> 16));
        genesisHeader[71] = bytes1(uint8(HALVING_TS >> 24));
        vm.prank(address(endpoint));
        oracle.lzReceive(
            Origin(SRC_EID, SRC_SENDER, 1),
            bytes32(0),
            abi.encode(HALVING_HEIGHT, genesisHeader),
            address(0),
            ""
        );
        address impl =
            address(new B4Vault(address(new B4VaultOps()), address(new B4VaultRecovery())));
        factory =
            new B4ProductFactory(address(oracle), usdcDescriptor(), impl, address(poolDeployer));
        CoreTypes.AssetDescriptor[] memory dirs = new CoreTypes.AssetDescriptor[](1);
        dirs[0] = ubtcDescriptor();
        strategies[0] = address(new StrategyMini());
        strategies[1] = address(new StrategyB4());
        strategies[2] = address(new StrategyPro());
        strategies[3] = address(new StrategyProMax());
        pool = B4Pool(factory.createProductPool(dirs, strategies, 1));
    }

    function test_mini_penalty_sleeve_grows_in_kind_then_claims_pro_rata() public {
        // The post-halving free window is deliberately passed: these are penalized exits.
        vm.warp(HALVING_TS + Calendar.W + 1);
        _setPx(1_000e18);

        B4Vault[8] memory stayers;
        for (uint256 i = 0; i < stayers.length; i++) {
            stayers[i] = _createVault(address(uint160(0xA100 + i)));
            _deposit(stayers[i], address(uint160(0xA100 + i)), USER_DEPOSIT_WAD, 1_000e18);
        }

        // 20% of the ten equal users exit. They have no profit, so all q belongs to the pool.
        for (uint256 i = 0; i < 2; i++) {
            address exiter = address(uint160(0xB100 + i));
            B4Vault v = _createVault(exiter);
            _deposit(v, exiter, USER_DEPOSIT_WAD, 1_000e18);
            vm.prank(exiter);
            v.initiateExit(Phi.WAD);
            _crankUntilIdle(v, 12);
            assertEq(v.exitShareWad(), 0, "fresh Mini exit finalizes");
        }

        // The strict pool first records the penalty in the Mini sleeve's escrow. It is
        // not claimable inventory yet: the same Mini position must hold it to a free
        // window, where the realised BTC returns to `accruing`.
        uint256 escrowBtc = pool.penaltyEscrow(1, 1, 1);
        uint256 perExitBtc = _btcForUsd(USER_DEPOSIT_WAD, 1_000e18) * Phi.EXIT_Q / Phi.WAD;
        assertEq(escrowBtc, 2 * perExitBtc, "each in-kind exit is floored independently");
        assertEq(pool.accruing(1), 0, "escrow is not an immediate claim basket");
        assertTrue(pool.foldPenalty(1, 1), "measured escrow enters Mini sleeve");

        // At P-H the whole accruing inventory becomes a fixed interval basket. Eight
        // identical Mini vaults settle at $4k, so their reward weights are exactly equal.
        vm.warp(HALVING_TS + Calendar.P - Calendar.H);
        _setPx(4_000e18);
        assertTrue(pool.initiateSleeveExit(1, 1), "free window starts sleeve realization");
        for (uint256 i = 0; i < 20; i++) {
            if (!pool.crankSleeve(1, 1)) break;
        }
        uint256 accruedBtc = pool.accruing(1);
        assertEq(accruedBtc, escrowBtc, "realised Mini sleeve returns in kind");
        assertTrue(pool.advance(), "P-H materializes the basket");
        pool.lockPrices(0);
        for (uint256 i = 0; i < stayers.length; i++) {
            stayers[i].settle(0);
            assertEq(
                pool.weightOf(0, address(stayers[i])),
                pool.weightOf(0, address(stayers[0])),
                "identical stayers have identical pool weights"
            );
        }

        uint256 bucketBtc = pool.bucketOf(0, 1);
        assertEq(bucketBtc, accruedBtc, "advance moves the complete accrued BTC basket");

        // Claims open three days after P-H. The same BTC is now worth $5k; no spreadsheet
        // return is assumed — the owner receives the token amount from B4Pool.claimFor.
        vm.warp(pool.reportDeadline(0) + 1);
        _setPx(5_000e18);
        address targetOwner = address(uint160(0xA100));
        uint256 beforeBtc = ubtc.balanceOf(targetOwner);
        pool.claimFor(0, address(stayers[0]));
        uint256 targetBtc = ubtc.balanceOf(targetOwner) - beforeBtc;

        assertEq(targetBtc, bucketBtc / 8, "target gets one eighth of the in-kind basket");
        uint256 targetClaimWad = targetBtc * 1e10 * 5_000e18 / 1e18;

        // q is 11.8034%, not the rounded 11% in the hand example. Therefore the exact
        // contract result is ~14.75% of the target's $1k, versus the example's 13.75%.
        assertEq(targetClaimWad, 147_542_450_000_000_000_000, "8-decimal in-kind result");
        assertGt(targetClaimWad * 10_000 / USER_DEPOSIT_WAD, 1_400, "pool adds >14% here");
    }

    function _createVault(address owner_) internal returns (B4Vault v) {
        vm.prank(owner_);
        v = B4Vault(
            factory.createVault(
                address(pool),
                CoreTypes.descriptorHash(ubtcDescriptor()),
                strategies[0],
                Phi.WAD,
                100,
                B4VaultStorage.FeeRoute({
                    operator: address(0x0FE0),
                    operatorBps: 3819,
                    referrer: address(0),
                    referrerBps: 0
                })
            )
        );
        vm.prank(owner_);
        ubtc.approve(address(v), type(uint256).max);
    }

    function _deposit(B4Vault v, address owner_, uint256 usdWad, uint256 pxWad) internal {
        uint256 amount = _btcForUsd(usdWad, pxWad);
        ubtc.mint(owner_, amount);
        vm.prank(owner_);
        v.deposit(amount, 0);
    }

    function _btcForUsd(uint256 usdWad, uint256 pxWad) internal pure returns (uint256) {
        return (usdWad * Phi.WAD / pxWad) / 1e10;
    }

    function _setPx(uint256 pxWad) internal {
        hub.setSpotPx(SPOT_MKT, uint64(pxWad / 1e14));
        hub.setMarkPx(PERP_MKT, uint64(pxWad / 1e16));
        hub.setOraclePx(PERP_MKT, uint64(pxWad / 1e16));
    }

    function _crankUntilIdle(B4Vault v, uint256 maxSteps) internal {
        for (uint256 i = 0; i < maxSteps; i++) {
            if (!v.crank()) return;
        }
    }
}
