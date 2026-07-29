// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {B4Pool} from "src/core/B4Pool.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";

/// @notice A directional pool token whose `balanceOf` can be flipped to revert — the same
///         hostile-basket-asset vector `AuditRegression.t.sol` uses, re-declared here to keep
///         this file self-contained.
contract SnapshotMalignToken {
    bool public reverting;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balances;

    function setReverting(bool v) external {
        reverting = v;
    }

    function mint(address to, uint256 a) external {
        balances[to] += a;
    }

    function balanceOf(address a) external view returns (uint256) {
        require(!reverting, "balanceOf blocked");
        return balances[a];
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balances[msg.sender] -= a;
        balances[to] += a;
        return true;
    }
}

/// @notice `B4Pool` plus two read-only windows into its own transient space. The harness
///         inherits the pool, so `tload` here reads the SAME address's transient slots the
///         pool writes — which is exactly the collision domain under test.
contract PoolTransientHarness is B4Pool {
    constructor(address oracle_, CoreTypes.AssetDescriptor[] memory ds, address factory_)
        B4Pool(oracle_, ds, factory_)
    {}

    function tslotBase() external pure returns (uint256) {
        return PENALTY_SNAPSHOT_TSLOT;
    }

    function rawTload(uint256 slot) external view returns (uint256 v) {
        assembly ("memory-safe") {
            v := tload(slot)
        }
    }
}

/// @notice Regressions for REVIEW-2026-07-25 item 17 — the raw transient slots used by
///         `beginPenalty`/`capturePenalty`.
///
///  (a) The snapshot lived at raw slots `1..assetCount`, un-namespaced. Any future transient
///      user of this contract (a transient reentrancy guard replacing `_entered`, an inlined
///      library) that picked a low slot would silently corrupt the H-1 measured receipt.
///
///  (b) `capturePenalty` cleared the slot only AFTER `if (!ok) continue;`, so a hostile
///      basket asset could leave a stale pre-transfer snapshot alive for the rest of the
///      transaction. A later capture that did not re-snapshot then measured `received`
///      against that stale balance and escrowed the pool's whole unattributed inventory into
///      its own sleeve — H-1 itself, re-opened.
contract Review17_TransientSnapshotTest is VaultTestBase {
    address constant VAULT = address(0xB4B4);
    uint256 constant DIR = 2; // the hostile token's index in the basket

    function setUp() public {
        setUpProtocol();
    }

    function _harness() internal returns (PoolTransientHarness h, SnapshotMalignToken bad) {
        bad = new SnapshotMalignToken();
        hub.registerToken(9, address(bad), 8, 2, 18, "BAD");
        hub.registerSpotMarket(9, 9, USDC_CORE);
        hub.setSpotPx(9, 4000e6);

        CoreTypes.AssetDescriptor[] memory ds = new CoreTypes.AssetDescriptor[](3);
        ds[0] = usdcDescriptor();
        ds[1] = ubtcDescriptor();
        ds[2] = CoreTypes.AssetDescriptor({
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
        // This test contract acts as the factory, exactly as `AuditRegression.t.sol` does.
        h = new PoolTransientHarness(address(oracle), ds, address(this));
        address[4] memory strategies = [address(mini), address(b4), address(pro), address(proMax)];
        h.configurePolicies(strategies, 1); // isolated Mini → a strict configured pool
        h.registerVault(VAULT, 1, DIR);
    }

    /// (a) The snapshot must live in a namespaced region, not at raw `1..9`.
    function test_review17_transient_slots_are_namespaced() public {
        (PoolTransientHarness h, SnapshotMalignToken bad) = _harness();
        usdc.mint(address(h), 7e6);
        bad.mint(address(h), 3e18);

        vm.prank(VAULT);
        h.beginPenalty();

        uint256 base = h.tslotBase();
        assertEq(base & 0xff, 0, "low byte cleared: [BASE, BASE+255] is reserved");
        assertGt(base, type(uint128).max, "not a low, guessable slot");

        // The legacy raw layout must now carry nothing: a future transient user of this
        // contract that picks a small slot cannot collide with the penalty snapshot.
        for (uint256 s = 0; s <= 16; s++) {
            assertEq(h.rawTload(s), 0, "raw low slot must hold no snapshot");
        }

        // ...and the snapshot really is at BASE + i, holding `balance + 1`.
        assertEq(h.rawTload(base + 0), 7e6 + 1, "settlement snapshot");
        assertEq(h.rawTload(base + 1), 0 + 1, "ubtc snapshot (zero balance still snapshots)");
        assertEq(h.rawTload(base + DIR), 3e18 + 1, "directional snapshot");
    }

    /// (b) A failing `balanceOf` must still consume the snapshot.
    function test_review17_stale_snapshot_is_cleared_when_balanceOf_fails() public {
        (PoolTransientHarness h, SnapshotMalignToken bad) = _harness();

        // Exit A snapshots while the pool holds none of the directional token.
        vm.prank(VAULT);
        h.beginPenalty();

        // Value that is NOT this exit's receipt arrives: a stranger's donation.
        uint256 donation = 100e18;
        bad.mint(address(h), donation);

        // The token turns hostile, so exit A's capture skips index DIR entirely.
        bad.setReverting(true);
        vm.prank(VAULT);
        h.capturePenalty();
        assertEq(h.escrowHeld(address(bad)), 0, "nothing escrowed while balanceOf fails");

        // A SECOND capture runs later in the SAME transaction with no intervening
        // `beginPenalty` — exactly what `_finalizeExit` produces when the try/catch around
        // `beginPenalty` swallows a failure.
        bad.setReverting(false);
        vm.prank(VAULT);
        h.capturePenalty();

        // FAIL-BEFORE: the stale "balance 0" snapshot survived the `continue`, so `received`
        // measured the entire donation and all of it was escrowed into this vault's sleeve.
        // PASS-AFTER: the snapshot is consumed unconditionally, `received == 0`, and the
        // donation falls through to ordinary claim inventory — the documented safe direction.
        assertEq(h.escrowHeld(address(bad)), 0, "stale snapshot must not mint sleeve escrow");
        assertEq(h.penaltyEscrow(1, DIR, DIR), 0, "no sleeve escrow booked");
        assertEq(h.liability(address(bad)), donation, "donation stays claimable");
        assertEq(h.accruing(DIR), donation, "donation joined the accruing basket");

        // Pool solvency (invariant: balance >= liability + escrowHeld) holds throughout.
        assertGe(bad.balanceOf(address(h)), h.liability(address(bad)) + h.escrowHeld(address(bad)));
    }
}
