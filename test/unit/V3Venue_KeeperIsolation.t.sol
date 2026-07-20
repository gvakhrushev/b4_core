// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {Keeper} from "src/periphery/Keeper.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {B4Pool} from "src/core/B4Pool.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";

/// @notice V3-VENUE candidate: Keeper.crank lacks revert isolation for the vault-list VIEW
///         calls. `_retryDeferred` reads v.route()/v.owner()/v.pool()/v.dirDescriptor()/
///         v.usdcDescriptor() OUTSIDE any try/catch (Keeper.sol:82-95), and
///         pool.intervalCount()/pool.currentReportable() are unguarded too
///         (Keeper.sol:33,53). One malformed entry in `vaults` therefore reverts the WHOLE
///         crank transaction — rolling back pool.advance/lockPrices/sweep/capture AND every
///         earlier healthy vault's cranks/settles made in the same call — contradicting the
///         contract's own guarantee ("Steps are wrapped in try/catch so one unavailable
///         step never strands the rest", Keeper.sol:11-12) and the F2/G2 isolation design.
contract V3VenueKeeperIsolationTest is VaultTestBase {
    Keeper keeper;

    function setUp() public {
        setUpProtocol();
        keeper = new Keeper();
    }

    /// Pass-after (V4-VENUE-1): one malformed entry in `vaults` is isolated behind the
    /// self-call wrappers (crankVault/settleVault/retryDeferred); pool steps AND the
    /// healthy vault's progress in the same crank persist. Fail-before: on the unwrapped
    /// keeper this exact call reverted wholesale (0xD34D has no code — the high-level-call
    /// extcodesize pre-check reverts in the crank frame, outside any local try/catch).
    function test_one_bad_entry_isolated_pool_and_vaults_survive() public {
        B4Vault v = createVault(address(b4));
        fundAndDeposit(v, 1e8, 0); // 1 UBTC (~$100k) deposited in the growth zone

        // Make pool-level work available: warp exactly to the first settlement point so
        // pool.advance() materializes interval 0 and lockPrices(0) is inside its window.
        warpTo(Calendar.P - Calendar.H);

        address[] memory mixed = new address[](2);
        mixed[0] = address(v); // healthy vault, has real work to do (sell at target 0)
        mixed[1] = address(0xD34D); // no code at all: extcodesize pre-check reverts uncaught

        // The crank does NOT revert: the bad entry is skipped, everything else advances.
        keeper.crank(pool, mixed, 8);

        assertEq(pool.intervalCount(), 1, "pool.advance must survive the bad entry");
        (uint64 pointTime, uint64 lockedAt,,) = pool.intervalInfo(0);
        assertEq(pointTime, uint64(GENESIS_TS + Calendar.P - Calendar.H));
        assertTrue(lockedAt != 0, "prices locked despite the bad entry");

        // The healthy vault progressed too (was: 1e8 dir on EVM, nothing else anywhere).
        assertTrue(
            v.dirEvm() != 1e8 || v.coreDirWei() != 0 || v.coreUsdcRotatedWei() != 0
                || v.usdcRotatedEvm() != 0,
            "healthy vault progress must survive the bad entry"
        );
    }

    /// A legitimate vault of ANOTHER pool is fully isolated (control/refutation of a
    /// wider reading of the finding): every per-vault state-changing call is try/catch'd,
    /// and its view functions all exist, so it cannot break the batch.
    function test_legit_foreign_vault_does_not_break_batch() public {
        B4Vault v = createVault(address(b4));
        fundAndDeposit(v, 1e8, 0);

        // A second pool with the same descriptor set (its own B4Pool instance).
        CoreTypes.AssetDescriptor[] memory dirs = new CoreTypes.AssetDescriptor[](1);
        dirs[0] = ubtcDescriptor();
        B4Pool pool2 = B4Pool(factory.createPool(dirs));
        vm.prank(user);
        B4Vault foreign = B4Vault(
            factory.createVault(
                address(pool2),
                CoreTypes.descriptorHash(ubtcDescriptor()),
                address(b4),
                1e18,
                100,
                defaultRoute()
            )
        );

        warpTo(Calendar.P - Calendar.H);
        address[] memory list = new address[](2);
        list[0] = address(v);
        list[1] = address(foreign); // valid vault ABI, wrong pool for settle/claimFor
        keeper.crank(pool, list, 8); // must NOT revert
        assertEq(pool.intervalCount(), 1, "pool advanced despite foreign vault in list");
    }
}
