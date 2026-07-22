// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";

/// @notice V6 scope B, item 1: F4 added the pxWad == 0 hold-guard to _startSpotOrder
///         but NOT to _startPerpOrder. The two paths that call _startPerpOrder without
///         a mark check — the wrong-sign reduce in _planSyncStep and the exit flatten
///         in _planExitStep — emit a ZERO-PRICE IOC during a mark-feed outage. The
///         venue rejects it, the intent clears after RESEND_TIMEOUT, and the planner
///         re-issues it forever: an exit freeze for the duration of the outage (H3).
contract V6B_PerpZeroMarkTest is VaultTestBase {
    function setUp() public {
        setUpProtocol();
    }

    function _queuedLimitPx(uint256 idx)
        internal
        view
        returns (uint32 asset, uint64 limitPx, bool reduceOnly)
    {
        (, bytes memory raw,) = hub.queue(idx);
        bytes memory args = new bytes(raw.length - 4);
        for (uint256 i; i < args.length; i++) {
            args[i] = raw[i + 4];
        }
        bool isBuy;
        uint64 sz;
        (asset, isBuy, limitPx, sz, reduceOnly,,) =
            abi.decode(args, (uint32, bool, uint64, uint64, bool, uint8, uint128));
    }

    /// Exit flatten at markWad == 0 emits limitPx == 0 orders, then loops: clear after
    /// timeout → re-issue zero again. The exit cannot progress while the feed is down.
    function test_V6B_1_exit_flatten_emits_zero_price_order_at_dead_mark_feed() public {
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 1e8, 20_000e6);
        crankUntilIdle(v, 40);

        hub.setAuto(false, true, true); // hold venue execution so orders stay queued
        hub.setMarkPx(PERP_MKT, 0); // mark feed outage

        vm.prank(user);
        v.initiateExit(1e18);

        v.crank(); // exit machine flattens: order queued WITHOUT a mark==0 guard
        (uint32 asset, uint64 limitPx, bool reduceOnly) = _queuedLimitPx(hub.queueHead());
        assertEq(asset, PERP_MKT);
        assertTrue(reduceOnly, "the exit flatten is reduce-only");
        assertEq(limitPx, 0, "zero-price order emitted at dead mark feed (venue rejects)");

        // After the resend timeout the no-fill intent clears and the planner re-issues
        // the same zero-price order: the exit spins instead of holding (contrast with
        // the F4 spot guard, which returns false and holds).
        vm.warp(block.timestamp + 1 hours + 1);
        v.crank(); // verify: no fill -> cleared
        v.crank(); // planner re-issues
        (, uint64 limitPx2,) = _queuedLimitPx(hub.queueHead());
        assertEq(limitPx2, 0, "re-issued zero-price order: spin, not hold");
        assertEq(v.exitShareWad(), 1e18, "exit stuck while the feed is down");
    }
}
