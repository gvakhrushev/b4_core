// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VenueTestBase} from "../utils/VenueTestBase.sol";
import {MockERC20} from "../mocks/MockCore.sol";
import {MockLzEndpoint} from "../mocks/MockLzEndpoint.sol";
import {B4Pool} from "src/core/B4Pool.sol";
import {HalvingOracle} from "src/core/HalvingOracle.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";
import {Origin} from "src/interfaces/ILayerZero.sol";

contract MockVault {
    address public owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function report(B4Pool pool, uint256 id, uint256 weight) external {
        pool.reportWeight(id, weight);
    }
}

contract B4PoolTest is VenueTestBase {
    uint32 constant SRC_EID = 30_101;
    bytes32 constant SRC_SENDER = bytes32(uint256(1));
    uint256 constant GENESIS_HEIGHT = 840_000;
    uint256 constant GENESIS_TS = 1_713_571_767;

    MockLzEndpoint endpoint;
    HalvingOracle oracle;
    B4Pool pool;
    MockERC20 ueth;
    MockVault vaultA;
    MockVault vaultB;
    address ownerA = address(0xA11CE);
    address ownerB = address(0xB0B);

    uint64 constant UETH_CORE = 2;
    uint32 constant UETH_SPOT = 6;

    function setUp() public {
        vm.warp(GENESIS_TS);
        setUpVenue();
        endpoint = new MockLzEndpoint();
        oracle = new HalvingOracle(
            address(endpoint), SRC_EID, SRC_SENDER, GENESIS_HEIGHT, GENESIS_TS, address(this)
        );

        // Second directional asset for multi-asset basket behavior.
        ueth = new MockERC20("UETH", 18);
        hub.registerToken(UETH_CORE, address(ueth), 8, 2, 18, "UETH");
        hub.registerSpotMarket(UETH_SPOT, UETH_CORE, USDC_CORE);
        hub.setSpotPx(UETH_SPOT, 4000e6); // $4000, 8−2 = 6 px decimals

        CoreTypes.AssetDescriptor[] memory descriptors = new CoreTypes.AssetDescriptor[](3);
        descriptors[0] = usdcDescriptor();
        descriptors[1] = ubtcDescriptor();
        descriptors[2] = uethDescriptor();
        pool = new B4Pool(address(oracle), descriptors); // test acts as factory

        vaultA = new MockVault(ownerA);
        vaultB = new MockVault(ownerB);
        pool.registerVault(address(vaultA));
        pool.registerVault(address(vaultB));
    }

    function uethDescriptor() internal view returns (CoreTypes.AssetDescriptor memory) {
        return CoreTypes.AssetDescriptor({
            evmToken: address(ueth),
            evmDecimals: 18,
            coreToken: UETH_CORE,
            spotMarket: UETH_SPOT,
            perpMarket: CoreTypes.NO_MARKET,
            coreWeiDecimals: 8,
            spotSzDecimals: 2,
            perpSzDecimals: 0,
            perpMaxLeverage: 0,
            fixedUsd: false
        });
    }

    function p1() internal pure returns (uint256) {
        return GENESIS_TS + Calendar.P - Calendar.H;
    }

    function p2() internal pure returns (uint256) {
        return GENESIS_TS + Calendar.T + Calendar.H;
    }

    function _fund(MockERC20 token, uint256 amount) internal {
        token.mint(address(pool), amount);
        pool.capture();
    }

    function _materializeAndLock() internal returns (uint256 id) {
        pool.advance();
        id = pool.intervalCount() - 1;
        pool.lockPrices(id);
    }

    // ------------------------------------------------------------- intervals & calendar

    function test_advance_materializes_points_in_order() public {
        assertFalse(pool.advance()); // nothing passed yet
        vm.warp(p1());
        assertTrue(pool.advance());
        (uint64 pt,,,) = pool.intervalInfo(0);
        assertEq(pt, p1());
        assertFalse(pool.advance()); // p2 not passed

        vm.warp(p2() + 5);
        assertTrue(pool.advance());
        (pt,,,) = pool.intervalInfo(1);
        assertEq(pt, p2());
        assertFalse(pool.advance());
        assertEq(pool.intervalCount(), 2);
    }

    /// E4 / TEST_PLAN §3.11: interval keys stay continuous across the epoch boundary —
    /// the interval beginning at T+H settles at the NEXT epoch's P−H.
    function test_intervalKey_continuity_across_epoch_boundary() public {
        vm.warp(p1());
        pool.advance();
        vm.warp(p2());
        pool.advance();
        assertEq(pool.intervalCount(), 2);

        // Fast-ish next halving accepted (no wall-clock window).
        uint256 newTs = GENESIS_TS + 1319 days;
        vm.warp(newTs + 1);
        _acceptHalving(GENESIS_HEIGHT + 210_000, uint32(newTs));

        // Next point = new epoch's P−H; id continues at 2.
        uint256 nextPoint = newTs + Calendar.P - Calendar.H;
        vm.warp(nextPoint);
        assertTrue(pool.advance());
        assertEq(pool.intervalCount(), 3);
        (uint64 pt,,,) = pool.intervalInfo(2);
        assertEq(pt, nextPoint);
    }

    /// An ultra-fast fact supersedes the old epoch's unreached point — skipped, ids
    /// monotonic, nothing strands (delayed liveness only).
    function test_superseded_point_skipped() public {
        vm.warp(p1());
        pool.advance(); // id 0 at old p1
        // Halving arrives before old p2 is reached (barely-monotonic timestamp).
        uint256 newTs = GENESIS_TS + 900 days;
        vm.warp(newTs + 1);
        _acceptHalving(GENESIS_HEIGHT + 210_000, uint32(newTs));

        uint256 newP1 = newTs + Calendar.P - Calendar.H;
        vm.warp(newP1);
        assertTrue(pool.advance());
        (uint64 pt,,,) = pool.intervalInfo(1);
        assertEq(pt, newP1); // old p2 never materializes
    }

    // ------------------------------------------------------------- price lock (D1)

    function test_lockPrices_window() public {
        vm.warp(p1());
        pool.advance();
        vm.warp(p1() - 1); // cannot happen in practice; guard anyway
        vm.expectRevert(B4Pool.OutsideSnapshotWindow.selector);
        pool.lockPrices(0);

        vm.warp(p1() + Calendar.SNAPSHOT_WINDOW + 1);
        vm.expectRevert(B4Pool.OutsideSnapshotWindow.selector);
        pool.lockPrices(0);

        vm.warp(p1() + Calendar.SNAPSHOT_WINDOW);
        pool.lockPrices(0);
        (, uint64 lockedAt,,) = pool.intervalInfo(0);
        assertEq(lockedAt, block.timestamp);
        assertEq(pool.lockedPxWad(0, 0), 1e18); // USDC fixed
        assertEq(pool.lockedPxWad(0, 1), 100_000e18); // UBTC
        assertEq(pool.lockedPxWad(0, 2), 4_000e18); // UETH

        vm.expectRevert(B4Pool.AlreadyLocked.selector);
        pool.lockPrices(0);
    }

    /// D1 regression (TEST_PLAN §3.9): a transient zero on ONE asset must not poison the
    /// interval — nothing commits, and a retry within the window succeeds.
    function test_checkpointPrice_poisoning_transientZero_retries() public {
        vm.warp(p1());
        pool.advance();
        hub.setSpotPx(UETH_SPOT, 0); // transient oracle failure on one asset

        vm.expectRevert(B4Pool.ZeroPrice.selector);
        pool.lockPrices(0);
        // NOTHING was committed — not even the assets that priced fine.
        assertEq(pool.lockedPxWad(0, 1), 0);
        (, uint64 lockedAt,,) = pool.intervalInfo(0);
        assertEq(lockedAt, 0);

        // Oracle recovers inside the window: retry succeeds, interval fully usable.
        vm.warp(p1() + 30 minutes);
        hub.setSpotPx(UETH_SPOT, 4000e6);
        pool.lockPrices(0);
        assertEq(pool.lockedPxWad(0, 2), 4_000e18);
    }

    function test_missed_snapshot_makes_interval_unreportable_not_stuck() public {
        vm.warp(p1());
        pool.advance();
        _fund(usdc, 1_000e6);
        vm.warp(p1() + Calendar.SNAPSHOT_WINDOW + 1);
        vm.expectRevert(B4Pool.OutsideSnapshotWindow.selector);
        pool.lockPrices(0);
        // Reports and claims impossible…
        vm.expectRevert(B4Pool.NotLocked.selector);
        vaultA.report(pool, 0, 1e18);
        vm.expectRevert(B4Pool.NotLocked.selector);
        pool.claimFor(0, address(vaultA));
        // …but inventory self-heals: sweeps into the next interval once it exists.
        vm.warp(p2());
        pool.advance();
        pool.sweep(0);
        assertEq(pool.accruing(0), 0); // moved into interval 1's bucket at advance? No:
        // sweep happens after advance, so it lands in accruing for interval 2.
        assertEq(pool.remainingOf(0, 0), 0);
    }

    // ------------------------------------------------------------- weights

    function test_reportWeight_rules() public {
        vm.warp(p1());
        pool.advance();
        vm.expectRevert(B4Pool.NotLocked.selector);
        vaultA.report(pool, 0, 5e18);
        pool.lockPrices(0);

        vm.expectRevert(B4Pool.NotAVault.selector);
        pool.reportWeight(0, 5e18);
        vm.expectRevert(B4Pool.ZeroWeight.selector);
        vaultA.report(pool, 0, 0);

        vaultA.report(pool, 0, 5e18);
        assertEq(pool.weightOf(0, address(vaultA)), 5e18);
        vm.expectRevert(B4Pool.AlreadyReported.selector);
        vaultA.report(pool, 0, 5e18);

        vaultB.report(pool, 0, 15e18);
        (,,, uint256 total) = pool.intervalInfo(0);
        assertEq(total, 20e18);

        vm.warp(pool.reportDeadline(0) + 1);
        vm.expectRevert(B4Pool.ReportWindowClosed.selector);
        vaultB.report(pool, 0, 1e18);
    }

    // ------------------------------------------------------------- claims & liability

    function _setupDistribution() internal returns (uint256 id) {
        _fund(usdc, 1_000e6);
        _fund(ubtc, 2e8);
        vm.warp(p1());
        id = _materializeAndLock();
        vaultA.report(pool, id, 3e18);
        vaultB.report(pool, id, 1e18);
        vm.warp(pool.reportDeadline(id) + 1);
    }

    function test_claim_proRata_paysFixedOwner() public {
        uint256 id = _setupDistribution();
        uint256 deadline = pool.reportDeadline(id);
        // Claims are gated until the report window closes (weights final).
        vm.warp(deadline);
        vm.expectRevert(B4Pool.ReportWindowOpen.selector);
        pool.claimFor(id, address(vaultA));
        vm.warp(deadline + 1);

        pool.claimFor(id, address(vaultA)); // permissionless, pays ownerA
        assertEq(usdc.balanceOf(ownerA), 750e6); // 3/4 of 1000
        assertEq(ubtc.balanceOf(ownerA), 15e7); // 3/4 of 2
        pool.claimFor(id, address(vaultB));
        assertEq(usdc.balanceOf(ownerB), 250e6);
        assertEq(ubtc.balanceOf(ownerB), 5e7);

        // Repeat claim is a no-op (all assets claimed).
        pool.claimFor(id, address(vaultA));
        assertEq(usdc.balanceOf(ownerA), 750e6);

        // balance ≥ liability throughout (D2).
        assertGe(usdc.balanceOf(address(pool)), pool.liability(address(usdc)));
    }

    function test_claim_requiresWeight() public {
        uint256 id = _setupDistribution();
        MockVault stranger = new MockVault(address(0xDEAD));
        pool.registerVault(address(stranger));
        vm.expectRevert(B4Pool.NothingToClaim.selector);
        pool.claimFor(id, address(stranger));
    }

    /// D3 regression (TEST_PLAN §3.10): shortfall socialization is order-independent —
    /// both claim orders pay everyone the same haircut.
    function test_shortfall_socialization_orderIndependent() public {
        uint256 id = _setupDistribution();
        // External deficit: 40% of the USDC vanishes (balance 600 < liability 1000).
        usdc.burn(address(pool), 400e6);

        uint256 snap = vm.snapshotState();
        pool.claimFor(id, address(vaultA));
        pool.claimFor(id, address(vaultB));
        uint256 a1 = usdc.balanceOf(ownerA);
        uint256 b1 = usdc.balanceOf(ownerB);
        vm.revertToState(snap);

        pool.claimFor(id, address(vaultB));
        pool.claimFor(id, address(vaultA));
        uint256 a2 = usdc.balanceOf(ownerA);
        uint256 b2 = usdc.balanceOf(ownerB);

        assertApproxEqAbs(a1, a2, 1); // flooring dust only
        assertApproxEqAbs(b1, b2, 1);
        assertApproxEqAbs(a1, 450e6, 1); // 750 × 0.6
        assertApproxEqAbs(b1, 150e6, 1); // 250 × 0.6
        // Haircut applies to USDC only; whole tokens unaffected.
        assertEq(ubtc.balanceOf(ownerA) + ubtc.balanceOf(ownerB), 2e8);
    }

    /// D5 regression: a failed token transfer defers only that token's claim.
    function test_failed_transfer_leaves_token_retryable() public {
        uint256 id = _setupDistribution();
        usdc.setBlocked(true);
        pool.claimFor(id, address(vaultA));
        assertEq(usdc.balanceOf(ownerA), 0); // deferred
        assertEq(ubtc.balanceOf(ownerA), 15e7); // succeeded
        assertFalse(pool.claimedOf(id, address(vaultA), 0));
        assertTrue(pool.claimedOf(id, address(vaultA), 1));

        usdc.setBlocked(false);
        pool.claimFor(id, address(vaultA)); // retry pays the deferred token only
        assertEq(usdc.balanceOf(ownerA), 750e6);
        assertEq(ubtc.balanceOf(ownerA), 15e7);
    }

    // ------------------------------------------------------------- sweep (D4) & capture

    function test_sweep_once_after_expiry_liabilityUnchanged() public {
        uint256 id = _setupDistribution();
        pool.claimFor(id, address(vaultA)); // B claims nothing; leftovers remain
        uint256 liabBefore = pool.liability(address(usdc));

        vm.expectRevert(B4Pool.NotExpired.selector);
        pool.sweep(id);

        vm.warp(p2());
        pool.advance(); // interval 1 exists ⇒ interval 0 expired
        pool.sweep(id);
        assertEq(pool.liability(address(usdc)), liabBefore); // D4
        assertEq(pool.remainingOf(id, 0), 0);
        assertEq(pool.accruing(0), 250e6); // B's unclaimed share accrues forward

        vm.expectRevert(B4Pool.AlreadySwept.selector);
        pool.sweep(id);
        vm.expectRevert(B4Pool.NothingToClaim.selector);
        pool.claimFor(id, address(vaultB)); // swept interval: nothing left to claim
    }

    function test_capture_measuredDelta_only() public {
        usdc.mint(address(pool), 500e6); // donation sits unaccounted…
        assertEq(pool.liability(address(usdc)), 0);
        pool.capture(); // …until captured as inventory (never vault profit)
        assertEq(pool.liability(address(usdc)), 500e6);
        assertEq(pool.accruing(0), 500e6);
        pool.capture(); // idempotent without new receipt
        assertEq(pool.liability(address(usdc)), 500e6);
        assertEq(pool.accruing(0), 500e6);
    }

    // ------------------------------------------------------------- constructor guards

    function test_constructor_rejects_duplicates() public {
        CoreTypes.AssetDescriptor[] memory d = new CoreTypes.AssetDescriptor[](3);
        d[0] = usdcDescriptor();
        d[1] = ubtcDescriptor();
        d[2] = ubtcDescriptor();
        vm.expectRevert(B4Pool.DuplicateAsset.selector);
        new B4Pool(address(oracle), d);
    }

    function _acceptHalving(uint256 height, uint32 ts) internal {
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
}
