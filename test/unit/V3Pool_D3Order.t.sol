// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VenueTestBase} from "../utils/VenueTestBase.sol";
import {MockLzEndpoint} from "../mocks/MockLzEndpoint.sol";
import {B4Pool} from "src/core/B4Pool.sol";
import {HalvingOracle} from "src/core/HalvingOracle.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";

contract MockVaultD {
    address public owner;

    constructor(address o) {
        owner = o;
    }

    function report(B4Pool pool, uint256 id, uint256 weight) external {
        pool.reportWeight(id, weight);
    }
}

/// @title V3 adversarial PoC — D3 order-independence of shortfall socialization,
///        stressed with many claimants and fuzzed shortfall ratios.
contract V3PoolD3OrderTest is VenueTestBase {
    uint32 constant SRC_EID = 30_101;
    bytes32 constant SRC_SENDER = bytes32(uint256(1));
    uint256 constant GENESIS_HEIGHT = 840_000;
    uint256 constant GENESIS_TS = 1_713_571_767;
    uint256 constant NV = 6;

    MockLzEndpoint endpoint;
    HalvingOracle oracle;
    B4Pool pool;
    MockVaultD[NV] vaults;
    address[NV] owners;

    function setUp() public {
        vm.warp(GENESIS_TS);
        setUpVenue();
        endpoint = new MockLzEndpoint();
        oracle = new HalvingOracle(
            address(endpoint), SRC_EID, SRC_SENDER, GENESIS_HEIGHT, GENESIS_TS, address(this)
        );
        CoreTypes.AssetDescriptor[] memory ds = new CoreTypes.AssetDescriptor[](2);
        ds[0] = usdcDescriptor();
        ds[1] = ubtcDescriptor();
        pool = new B4Pool(address(oracle), ds);
        for (uint256 i = 0; i < NV; i++) {
            owners[i] = address(uint160(0x1000 + i));
            vaults[i] = new MockVaultD(owners[i]);
            pool.registerVault(address(vaults[i]));
        }
    }

    function _w(uint256 raw) internal pure returns (uint256) {
        return bound(raw, 1, 1e18);
    }

    function _interval(uint256 bucket, uint256[NV] memory rawW, uint256 bal0)
        internal
        returns (uint256 id, uint256 wTotal)
    {
        usdc.mint(address(pool), bucket);
        pool.capture();
        vm.warp(GENESIS_TS + Calendar.P - Calendar.H);
        pool.advance();
        id = pool.intervalCount() - 1;
        pool.lockPrices(id);
        for (uint256 i = 0; i < NV; i++) {
            uint256 w = _w(rawW[i]);
            wTotal += w;
            vaults[i].report(pool, id, w);
        }
        vm.warp(pool.reportDeadline(id) + 1);
        if (bal0 > bucket) usdc.mint(address(pool), bal0 - bucket);
        if (bal0 < bucket) usdc.burn(address(pool), bucket - bal0);
        assertEq(pool.liability(address(usdc)), bucket);
    }

    /// Claims in the given order; payouts written to `out` (MEMORY: survives a later
    /// revertToState of the pool, unlike this contract's storage).
    function _runOrder(uint256 id, bool forward, uint256 maxPaid, uint256[NV] memory out)
        internal
        returns (uint256 endLiab)
    {
        uint256 total;
        for (uint256 k = 0; k < NV; k++) {
            uint256 i = forward ? k : NV - 1 - k;
            pool.claimFor(id, address(vaults[i]));
        }
        for (uint256 i = 0; i < NV; i++) {
            out[i] = usdc.balanceOf(owners[i]);
            total += out[i];
        }
        assertLe(total, maxPaid, "paid more than balance");
        endLiab = pool.liability(address(usdc));
    }

    /// Per-claimant fairness across the two orders: nobody below the initial-ratio
    /// floor share; order drift within the documented per-claim dust bound.
    function _verifyFairness(
        uint256 bucket,
        uint256 wTotal,
        uint256 bal0,
        uint256[NV] memory rawW,
        uint256[NV] memory pay1,
        uint256[NV] memory pay2
    ) internal {
        for (uint256 i = 0; i < NV; i++) {
            uint256 nominal = (bucket * _w(rawW[i])) / wTotal;
            if (bal0 < bucket) {
                uint256 floorShare = (nominal * bal0) / bucket;
                assertGe(pay1[i], floorShare, "fwd: below initial-ratio share");
                assertGe(pay2[i], floorShare, "rev: below initial-ratio share");
            } else {
                assertEq(pay1[i], nominal, "no shortfall must pay nominal");
                assertEq(pay2[i], nominal, "no shortfall must pay nominal");
            }
            uint256 d = pay1[i] > pay2[i] ? pay1[i] - pay2[i] : pay2[i] - pay1[i];
            assertLe(d, NV, "order drift beyond per-claim dust bound");
        }
    }

    /// D3: no claimant may receive less than the initial-ratio floor share; totals
    /// conserve; end state is order-independent.
    function testFuzz_shortfall_orderIndependent_bounded(
        uint256 bucket,
        uint256 balRatioBps,
        uint256[NV] memory rawW
    ) public {
        bucket = bound(bucket, NV, 1e15);
        balRatioBps = bound(balRatioBps, 1, 20_000); // 0.01%..200% of liability
        uint256 bal0 = (bucket * balRatioBps) / 10_000;
        (uint256 id, uint256 wTotal) = _interval(bucket, rawW, bal0);

        uint256[NV] memory pay1;
        uint256[NV] memory pay2;
        uint256 snap = vm.snapshotState();
        uint256 endA = _runOrder(id, true, bal0, pay1);
        vm.revertToState(snap);
        uint256 endB = _runOrder(id, false, bal0, pay2);

        _verifyFairness(bucket, wTotal, bal0, rawW, pay1, pay2);
        assertEq(endA, endB, "end liability order-dependent");
        // Remaining after all claims = bucket − Σ⌊nominal⌋: per-claim mulDiv flooring
        // dust, bounded by < 1 wei per claim (documented B5 / RAW-B-002 residual).
        assertLe(pool.remainingOf(id, 0), NV - 1, "remaining dust beyond per-claim floor bound");
        for (uint256 i = 0; i < NV; i++) {
            assertTrue(pool.claimedOf(id, address(vaults[i]), 0));
        }
    }

    /// First/last claimant edges: a single claimant owed the whole bucket under an
    /// extreme shortfall, then a late donation must NOT revive the consumed claim
    /// (documented shortfall semantics) but lands in a later interval via capture.
    function test_firstLast_claimant_edges() public {
        usdc.mint(address(pool), 1_000e6);
        pool.capture();
        vm.warp(GENESIS_TS + Calendar.P - Calendar.H);
        pool.advance();
        uint256 id = pool.intervalCount() - 1;
        pool.lockPrices(id);
        vaults[0].report(pool, id, 1e18); // only vault 0 reports
        vm.warp(pool.reportDeadline(id) + 1);
        usdc.burn(address(pool), 999_999_900); // balance 100 < liability 1e9

        pool.claimFor(id, address(vaults[0]));
        uint256 got = usdc.balanceOf(owners[0]);
        assertEq(got, 100); // entire remaining balance, haircut applied
        assertEq(pool.liability(address(usdc)), 0);
        assertEq(pool.remainingOf(id, 0), 0);

        // A later donation is captured for a FUTURE interval, not the consumed claim.
        usdc.mint(address(pool), 500e6);
        pool.capture();
        assertEq(pool.accruing(0), 500e6);
        pool.claimFor(id, address(vaults[0])); // no-op: already claimed
        assertEq(usdc.balanceOf(owners[0]), 100);
    }
}
