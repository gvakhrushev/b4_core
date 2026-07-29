// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {EngineHarness} from "../utils/EngineHarness.sol";
import {MockERC20} from "../mocks/MockCore.sol";
import {B4Factory} from "src/core/B4Factory.sol";
import {B4ProductFactory} from "src/core/B4ProductFactory.sol";
import {B4VaultStorage} from "src/core/B4VaultStorage.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";
import {DescriptorLib} from "src/venue/DescriptorLib.sol";

/// @notice AUDIT-2026-07-25 observation #2 (unfiled in the report, closed in code, previously
///         SHIPPED WITH NO TEST — REVIEW-2026-07-25 §7 and action 13): `verifySettlement`
///         must assert the settlement descriptor IS the venue's quote asset (core token
///         index 0), not merely that the deployer flagged it `fixedUsd`.
///         `usdClassTransfer` moves the venue's USDC unconditionally, so a factory bound to
///         any OTHER linked token leaves `_startToPerp` watching a balance the transfer
///         never touches. The completion predicate can then never fire, and an
///         asset-transfer intent may never be discarded (HAZARDS A6) — the vault resends
///         forever and is unhealable. That is a FREEZE, not the mispricing that
///         SECURITY_MODEL §3 "market association" accepts as descriptor trust, which is why
///         the settlement side is checked rather than trusted (SPECIFICATION §2).
///         The guard is a BINDING-time check: it fails closed in the factory constructor,
///         so the bad configuration can never be deployed and no runtime path can meet it.
contract AuditObs2SettlementIdentityTest is VaultTestBase {
    /// A second linked, venue-consistent stablecoin that is NOT the quote token. Everything
    /// about it matches the real settlement token except its core index.
    uint64 constant FUSD_CORE = 7;
    uint32 constant FUSD_SPOT = 8;

    MockERC20 fusd;

    function setUp() public {
        setUpProtocol();
        fusd = new MockERC20("FUSD", 6);
        // Registered exactly like USDC (wei 8 / sz 0 / evm 6) so `_verifyToken` passes on it
        // and the ONLY thing wrong with it as settlement is the index.
        hub.registerToken(FUSD_CORE, address(fusd), 8, 0, 6, "FUSD");
        hub.registerSpotMarket(FUSD_SPOT, FUSD_CORE, USDC_CORE);
        hub.setSpotPx(FUSD_SPOT, 1e8); // $1 in (8 − 0) px decimals
    }

    function _fusdSettlement() internal view returns (CoreTypes.AssetDescriptor memory) {
        CoreTypes.AssetDescriptor memory s = usdcDescriptor();
        s.evmToken = address(fusd);
        s.coreToken = FUSD_CORE;
        return s;
    }

    // ------------------------------------------------- the guard, on both binding paths

    /// PASS-AFTER: `B4Factory` cannot be constructed on a non-quote settlement token. The
    /// revert is at DEPLOYMENT, before any pool, vault or user funds exist.
    function test_OBS2_non_quote_settlement_rejected_by_B4Factory() public {
        vm.expectRevert(DescriptorLib.BadSettlement.selector);
        new B4Factory(address(oracle), _fusdSettlement(), address(1), address(poolDeployer));
    }

    /// PASS-AFTER: the strict four-product path is bound by the same check — a residual is
    /// only closed if BOTH factories carry it.
    function test_OBS2_non_quote_settlement_rejected_by_B4ProductFactory() public {
        vm.expectRevert(DescriptorLib.BadSettlement.selector);
        new B4ProductFactory(address(oracle), _fusdSettlement(), address(1), address(poolDeployer));
    }

    /// The guard is precise, not a blanket rejection of unfamiliar tokens: the SAME token,
    /// same decimals, same registration binds fine as a DIRECTIONAL asset. So `_verifyToken`
    /// and every decimal branch of `verifySettlement` accept this descriptor — the index is
    /// the sole reason it is refused as settlement, and the check costs no legitimate
    /// configuration.
    function test_OBS2_same_token_still_binds_as_a_directional_asset() public {
        CoreTypes.AssetDescriptor memory d = CoreTypes.AssetDescriptor({
            evmToken: address(fusd),
            evmDecimals: 6,
            coreToken: FUSD_CORE,
            spotMarket: FUSD_SPOT,
            perpMarket: CoreTypes.NO_MARKET,
            coreWeiDecimals: 8,
            spotSzDecimals: 0,
            perpSzDecimals: 0,
            perpMaxLeverage: 0,
            fixedUsd: false
        });
        CoreTypes.AssetDescriptor[] memory dirs = new CoreTypes.AssetDescriptor[](1);
        dirs[0] = d;
        assertTrue(factory.createPool(dirs) != address(0), "venue-consistent token binds");
    }

    /// The fixture's own settlement — the quote token — is unaffected: `setUpProtocol`
    /// already deployed a factory on it, and it is index 0 by construction. Pins the
    /// assumption itself so a future fixture change cannot silently move the quote token.
    function test_OBS2_quote_token_is_index_zero() public view {
        assertEq(factory.settlementDescriptor().coreToken, 0, "settlement is the quote token");
        assertEq(hub.usdcToken(), 0, "venue quote token is spot index 0");
    }

    // ------------------------------------------------- the hazard the guard prevents

    /// FAIL-BEFORE evidence, kept as documentation of WHY index 0 is the invariant: drive the
    /// engine with the configuration binding now refuses. `_startToPerp` snapshots the
    /// SETTLEMENT token's spot balance (token 7) and emits `usdClassTransfer`, which moves
    /// the venue's USDC (token 0) — a balance this vault does not hold. No net decrease is
    /// ever observed on token 7, so the completion predicate can never fire; its exact
    /// complement resends on every timeout, forever (HAZARDS A3/A6). Delayed liveness would
    /// be acceptable; this is unbounded, with no admin and no discard path — a freeze.
    function test_OBS2_non_quote_settlement_would_freeze_the_toPerp_leg() public {
        EngineHarness h = new EngineHarness();
        h.setup(ubtcDescriptor(), _fusdSettlement(), address(oracle));
        hub.setUserExists(address(h), true);

        hub.coreTopUp(address(h), FUSD_CORE, 1_000e8); // $1,000 of "settlement" on Core spot
        h.setBuckets(0, 0, 0, 0, 0, 1_000e8, 0); // recorded as Core margin
        h.startToPerp(100e6); // $100 spot → perp

        assertEq(uint8(h.intentKind()), uint8(B4VaultStorage.IntentKind.ToPerp), "leg in flight");
        assertEq(
            hub.spotBal(address(h), FUSD_CORE),
            1_000e8,
            "the class transfer never touches the bound settlement token"
        );

        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + 1 hours + 1);
            assertTrue(h.verify(), "resend is the only outcome available");
            assertEq(
                uint8(h.intentKind()),
                uint8(B4VaultStorage.IntentKind.ToPerp),
                "completion can never fire: the watched balance cannot decrease"
            );
        }
        assertEq(h.perpMargin6(), 0, "no margin ever reaches the perp side");
        assertEq(h.coreUsdcMarginWei(), 1_000e8, "and the capital is stuck mid-leg");
    }
}
