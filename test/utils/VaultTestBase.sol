// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VenueTestBase} from "./VenueTestBase.sol";
import {MockLzEndpoint} from "../mocks/MockLzEndpoint.sol";
import {HalvingOracle} from "src/core/HalvingOracle.sol";
import {B4Factory} from "src/core/B4Factory.sol";
import {B4ProductFactory} from "src/core/B4ProductFactory.sol";
import {B4Pool} from "src/core/B4Pool.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {B4VaultOps} from "src/core/B4VaultOps.sol";
import {B4VaultRecovery} from "src/core/B4VaultRecovery.sol";
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
            address(endpoint), SRC_EID, SRC_SENDER, GENESIS_HEIGHT, address(this)
        );
        acceptHalving(GENESIS_HEIGHT, uint32(GENESIS_TS));
        address impl =
            address(new B4Vault(address(new B4VaultOps()), address(new B4VaultRecovery())));
        factory = new B4Factory(address(oracle), usdcDescriptor(), impl, address(poolDeployer));

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

    // ------------------------------------------------------- strict product-pool fixture
    // `createPool` above is the LEGACY shared basket (policyMask == 0). Every campaign built
    // on it is structurally blind to the strict Product-Pool domain: sleeves, per-policy
    // `penaltyEscrow`, `escrowHeld` and the `capturePenalty` receipt split never execute.
    // These three helpers make the strict pool as cheap to stand up as the legacy one, so a
    // test (or an invariant campaign) chooses the domain instead of inheriting it. The
    // factory is LAZY on purpose: deploying it inside `setUpProtocol` would shift the CREATE
    // nonce of every contract the ~30 existing suites build afterwards.

    B4ProductFactory internal _strictFactory;

    function strictFactory() internal returns (B4ProductFactory) {
        if (address(_strictFactory) == address(0)) {
            _strictFactory = new B4ProductFactory(
                address(oracle),
                usdcDescriptor(),
                factory.vaultImplementation(),
                address(poolDeployer)
            );
        }
        return _strictFactory;
    }

    /// One-directional-asset strict pool. `mask` is one of the five product choices
    /// (1/2/4/8 isolated, 15 aggregate); every enabled policy gets its own sleeve.
    function createStrictPool(uint8 mask) internal returns (B4Pool p) {
        CoreTypes.AssetDescriptor[] memory dirs = new CoreTypes.AssetDescriptor[](1);
        dirs[0] = ubtcDescriptor();
        address[4] memory strategies = [address(mini), address(b4), address(pro), address(proMax)];
        p = B4Pool(strictFactory().createProductPool(dirs, strategies, mask));
    }

    function createStrictVault(
        B4Pool p,
        address strategy,
        address owner_,
        B4VaultStorage.FeeRoute memory route_
    ) internal returns (B4Vault v) {
        vm.prank(owner_);
        v = B4Vault(
            strictFactory()
                .createVault(
                    address(p),
                    CoreTypes.descriptorHash(ubtcDescriptor()),
                    strategy,
                    1e18,
                    100,
                    route_
                )
        );
    }

    /// `fundAndDeposit` for a vault whose owner is not the shared `user`.
    function fundAndDepositFor(B4Vault v, address owner_, uint256 dirAmount, uint256 usdcAmount)
        internal
    {
        if (dirAmount > 0) ubtc.mint(owner_, dirAmount);
        if (usdcAmount > 0) usdc.mint(owner_, usdcAmount);
        vm.startPrank(owner_);
        if (dirAmount > 0) ubtc.approve(address(v), dirAmount);
        if (usdcAmount > 0) usdc.approve(address(v), usdcAmount);
        v.deposit(dirAmount, usdcAmount);
        vm.stopPrank();
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

    /// @dev Mark-to-market equity: `navWad()` plus the perp's unrealized PnL.
    ///
    ///      USE THIS, not `navWad()`, whenever a figure is meant to be what the vault is WORTH.
    ///      NAV is recorded value only — it excludes unrealized perp PnL by invariant B3, which is
    ///      correct for settlement and blind for a pure-perp product, whose entire position is the
    ///      leg NAV cannot see. That blindness has produced three separate wrong published
    ///      results in this repository (a 0.00 % Pro Max drawdown, a "leveraged sleeve loses
    ///      value" claim, and a Pro Max ranked below Pro on a worked cycle where it ends at 2.4x
    ///      Pro). It lives here so it stops being re-derived, one caller at a time, by whoever
    ///      forgets next.
    function equityWad(B4Vault v) internal view returns (uint256) {
        (int64 szi, uint64 entryNtl,) = hub.positions(address(v), PERP_MKT);
        int256 eq = int256(v.navWad());
        if (szi != 0) {
            uint64 az = uint64(szi > 0 ? szi : -szi);
            int256 mk = int256(uint256(az) * uint256(hub.markPxOf(PERP_MKT)));
            int256 up = szi > 0 ? mk - int256(uint256(entryNtl)) : int256(uint256(entryNtl)) - mk;
            eq += up * int256(10 ** 12);
        }
        return eq > 0 ? uint256(eq) : 0;
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
