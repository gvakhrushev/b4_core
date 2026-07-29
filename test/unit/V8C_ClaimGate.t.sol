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

contract V8CMockVault {
    address public owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function report(B4Pool pool, uint256 id, uint256 weight) external {
        pool.reportWeight(id, weight);
    }
}

/// @notice V8 Scope C — attack 4: the new claimFor latest-only gate
///         (`if (id + 1 < intervalCount) revert NothingToClaim();`, B4Pool.sol:329).
///         Previously a claim stayed open on ANY unswept locked interval; now successor
///         MATERIALIZATION itself closes it (sweep only carries the remainder forward).
///         I) a D5-deferred claim (malicious/broken basket token) becomes unretryable at
///            the next settlement point even while unswept and fully collateralized;
///         J) a vault that never claims in time forfeits its share to the reporters of a
///            LATER interval (redistribution via sweep → accruing → interval N+2 bucket).
contract V8C_ClaimGateTest is VenueTestBase {
    uint32 constant SRC_EID = 30_101;
    bytes32 constant SRC_SENDER = bytes32(uint256(1));
    uint256 constant GEN_HEIGHT = 840_000;
    uint256 constant GEN_TS = 1_713_571_767;

    MockLzEndpoint endpoint;
    HalvingOracle oracle;
    B4Pool pool;
    V8CMockVault vaultA;
    V8CMockVault vaultB;
    address ownerA = address(0xA11CE);
    address ownerB = address(0xB0B);

    function setUp() public {
        vm.warp(GEN_TS);
        setUpVenue();
        endpoint = new MockLzEndpoint();
        oracle =
            new HalvingOracle(address(endpoint), SRC_EID, SRC_SENDER, GEN_HEIGHT, address(this));
        _acceptHalving(GEN_HEIGHT, uint32(GEN_TS));
        CoreTypes.AssetDescriptor[] memory ds = new CoreTypes.AssetDescriptor[](2);
        ds[0] = usdcDescriptor();
        ds[1] = ubtcDescriptor();
        pool = new B4Pool(address(oracle), ds, address(this)); // test acts as factory
        vaultA = new V8CMockVault(ownerA);
        vaultB = new V8CMockVault(ownerB);
        pool.registerVault(address(vaultA));
        pool.registerVault(address(vaultB));
    }

    function p1() internal pure returns (uint256) {
        return GEN_TS + Calendar.P - Calendar.H;
    }

    function p2() internal pure returns (uint256) {
        return GEN_TS + Calendar.T + Calendar.H;
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

    /// Interval 0: 1000 USDC in the basket, A weight 3, B weight 1, report window closed.
    function _intervalZero() internal returns (uint256 id) {
        usdc.mint(address(pool), 1_000e6);
        pool.capture();
        vm.warp(p1());
        pool.advance();
        id = pool.intervalCount() - 1;
        pool.lockPrices(id);
        vaultA.report(pool, id, 3e18);
        vaultB.report(pool, id, 1e18);
        vm.warp(pool.reportDeadline(id) + 1);
    }

    /// I) D5 retry dies at successor materialization. A's USDC claim defers (transfer
    ///    blocked). Pre-successor the retry still works (old semantics preserved up to
    ///    the gate — pinned via snapshot). After `advance()` materializes interval 1 —
    ///    with interval 0 UNSWEPT, the USDC healthy again and A's 750e6 still sitting in
    ///    `remaining` — the retry reverts NothingToClaim. The deferred share then sweeps
    ///    forward: deferred-then-late == forfeited.
    function test_D5_deferred_claim_dies_at_successor_materialization() public {
        uint256 id = _intervalZero();

        usdc.setBlocked(true);
        pool.claimFor(id, address(vaultA)); // USDC defers; UBTC pays
        assertEq(usdc.balanceOf(ownerA), 0, "USDC deferred");
        assertFalse(pool.claimedOf(id, address(vaultA), 0), "USDC claim open");

        // Pre-successor: the D5 retry still works (gate not yet engaged).
        uint256 snap = vm.snapshotState();
        usdc.setBlocked(false);
        pool.claimFor(id, address(vaultA));
        assertEq(usdc.balanceOf(ownerA), 750e6, "retry works while latest (old semantics)");
        vm.revertToState(snap);

        // Successor materializes — interval 0 NOT swept, USDC healthy, tokens present.
        vm.warp(p2());
        pool.advance();
        usdc.setBlocked(false);
        (,, bool swept,) = pool.intervalInfo(id);
        assertFalse(swept, "interval 0 unswept");
        assertEq(pool.remainingOf(id, 0), 1_000e6, "A's deferred 750 + B's 250 still in the pool");

        vm.expectRevert(B4Pool.NothingToClaim.selector);
        pool.claimFor(id, address(vaultA)); // the retry DIES here

        pool.sweep(id);
        assertEq(pool.accruing(0), 1_000e6, "deferred 750 + B's unclaimed 250 roll forward");
    }

    /// J) Late-keeper forfeiture redistributes to a LATER interval's reporters. B never
    ///    claims interval 0; its 250e6 sweeps into accruing and lands in interval 2's
    ///    bucket (interval 1's bucket was already fixed at its own materialization).
    ///    Interval 2 has only A reporting ⇒ A collects B's forfeited share on top.
    function test_late_claim_forfeits_to_later_interval_reporters() public {
        uint256 id = _intervalZero();
        pool.claimFor(id, address(vaultA)); // A takes 750; B's 250 remains
        assertEq(usdc.balanceOf(ownerA), 750e6);

        // Successor materializes + sweeps: B's share rolls into the accruing basket.
        vm.warp(p2());
        pool.advance(); // interval 1 (empty basket: nothing accrued since p1)
        pool.sweep(id);
        assertEq(pool.accruing(0), 250e6, "B's forfeited share accrues forward");

        // Interval 2 (next epoch): 750 fresh USDC + B's 250 forfeited = 1000 bucket.
        uint256 hts2 = GEN_TS + Calendar.T + 30 days;
        vm.warp(hts2);
        _acceptHalving(GEN_HEIGHT + 210_000, uint32(hts2));
        usdc.mint(address(pool), 750e6);
        pool.capture();
        vm.warp(hts2 + Calendar.P - Calendar.H);
        pool.advance();
        uint256 id2 = pool.intervalCount() - 1;
        assertEq(id2, 2);
        assertEq(pool.bucketOf(id2, 0), 1_000e6, "interval 2 carries B's forfeiture");
        pool.lockPrices(id2);
        vaultA.report(pool, id2, 1e18); // only A reports this interval
        vm.warp(pool.reportDeadline(id2) + 1);

        pool.claimFor(id2, address(vaultA));
        assertEq(usdc.balanceOf(ownerA), 1_750e6, "A collects its 750 + B's forfeited 250 + 750");
        assertEq(usdc.balanceOf(ownerB), 0, "B forfeited everything");

        vm.expectRevert(B4Pool.NothingToClaim.selector);
        pool.claimFor(id, address(vaultB)); // interval 0 long dead
    }
}
