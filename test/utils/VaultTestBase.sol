// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VenueTestBase} from "./VenueTestBase.sol";
import {MockLzEndpoint} from "../mocks/MockLzEndpoint.sol";
import {HalvingOracle} from "src/core/HalvingOracle.sol";
import {B4Factory} from "src/core/B4Factory.sol";
import {B4Pool} from "src/core/B4Pool.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {B4VaultOps} from "src/core/B4VaultOps.sol";
import {B4VaultStorage} from "src/core/B4VaultStorage.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";
import {Origin} from "src/interfaces/ILayerZero.sol";
import {
    StrategyMini,
    StrategyB4,
    StrategyPro,
    StrategyProMax
} from "src/periphery/ReferenceStrategies.sol";

/// @notice Full-protocol fixture: venue + oracle + factory + pool + reference strategies.
abstract contract VaultTestBase is VenueTestBase {
    uint32 constant SRC_EID = 30_101;
    bytes32 constant SRC_SENDER = bytes32(uint256(1));
    uint256 constant GENESIS_HEIGHT = 840_000;
    uint256 constant GENESIS_TS = 1_713_571_767;

    MockLzEndpoint endpoint;
    HalvingOracle public oracle;
    B4Factory public factory;
    B4Pool public pool;
    StrategyMini mini;
    StrategyB4 b4;
    StrategyPro pro;
    StrategyProMax proMax;

    address user = address(0xA11CE);
    address operator = address(0x0FE0);
    address referrer = address(0x0EF0);

    function setUpProtocol() internal {
        vm.warp(GENESIS_TS);
        setUpVenue();
        endpoint = new MockLzEndpoint();
        oracle = new HalvingOracle(
            address(endpoint), SRC_EID, SRC_SENDER, GENESIS_HEIGHT, GENESIS_TS, address(this)
        );
        address impl = address(new B4Vault(address(new B4VaultOps())));
        factory = new B4Factory(address(oracle), usdcDescriptor(), impl);

        CoreTypes.AssetDescriptor[] memory dirs = new CoreTypes.AssetDescriptor[](1);
        dirs[0] = ubtcDescriptor();
        pool = B4Pool(factory.createPool(dirs));

        mini = new StrategyMini();
        b4 = new StrategyB4();
        pro = new StrategyPro();
        proMax = new StrategyProMax();
    }

    function defaultRoute() internal view returns (B4VaultStorage.FeeRoute memory) {
        return B4VaultStorage.FeeRoute({
            operator: operator, operatorBps: 3000, referrer: referrer, referrerBps: 4000
        });
    }

    function createVault(address strategy) internal returns (B4Vault v) {
        vm.prank(user);
        v = B4Vault(
            factory.createVault(
                address(pool),
                CoreTypes.descriptorHash(ubtcDescriptor()),
                strategy,
                1e18,
                100, // 1% spot slippage envelope
                defaultRoute()
            )
        );
    }

    /// Fund the user and deposit into the vault (growth window at t = 0).
    function fundAndDeposit(B4Vault v, uint256 dirAmount, uint256 usdcAmount) internal {
        if (dirAmount > 0) ubtc.mint(user, dirAmount);
        if (usdcAmount > 0) usdc.mint(user, usdcAmount);
        vm.startPrank(user);
        if (dirAmount > 0) ubtc.approve(address(v), dirAmount);
        if (usdcAmount > 0) usdc.approve(address(v), usdcAmount);
        v.deposit(dirAmount, usdcAmount);
        vm.stopPrank();
    }

    /// Crank the vault until it reports no more progress (bounded).
    function crankUntilIdle(B4Vault v, uint256 maxSteps) internal returns (uint256 steps) {
        for (steps = 0; steps < maxSteps; steps++) {
            if (!v.crank()) break;
        }
    }

    function warpTo(uint256 t) internal {
        vm.warp(GENESIS_TS + t);
    }

    function acceptHalving(uint256 height, uint32 ts) internal {
        bytes memory h = new bytes(80);
        h[68] = bytes1(uint8(ts));
        h[69] = bytes1(uint8(ts >> 8));
        h[70] = bytes1(uint8(ts >> 16));
        h[71] = bytes1(uint8(ts >> 24));
        vm.prank(address(endpoint));
        oracle.lzReceive(
            Origin(SRC_EID, SRC_SENDER, 1), bytes32(0), abi.encode(height, h), address(0), ""
        );
    }

    function intentKindOf(B4Vault v) internal view returns (B4VaultStorage.IntentKind kind) {
        (kind,,,,,,,,,,,) = v.intent();
    }
}
