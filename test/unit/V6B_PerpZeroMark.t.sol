// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";

/// @notice V6 scope B, item 1 (FIXED by V8-L-1): F4 added the pxWad == 0 hold-guard to
///         _startSpotOrder but NOT to _startPerpOrder, so the exit flatten in
///         _planExitStep (which calls _startPerpOrder directly) emitted a ZERO-PRICE IOC
///         during a mark-feed outage — rejected by the venue, cleared after timeout and
///         re-issued forever (H3). The guard is now mirrored into _startPerpOrder: the
///         flatten HOLDS while the feed is down and resumes when it returns.
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

    /// Exit flatten at markWad == 0 now HOLDS (no intent, no px-0 order queued), then
    /// resumes the flatten as soon as the mark feed returns.
    function test_V6B_1_exit_flatten_held_at_dead_mark_feed_resumes_on_return() public {
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 1e8, 20_000e6);
        crankUntilIdle(v, 40);

        hub.setAuto(false, true, true); // hold venue execution so orders stay queued
        hub.setMarkPx(PERP_MKT, 0); // mark feed outage

        vm.prank(user);
        v.initiateExit(1e18);

        v.crank(); // exit machine tries to flatten — HELD by the zero-mark guard
        assertEq(hub.pendingActions(), 0, "no zero-price order emitted at dead mark feed");
        assertEq(uint8(intentKindOf(v)), 0, "no intent snapshot while the mark is zero");

        // Feed returns: the flatten proceeds normally with a real limit price.
        hub.setMarkPx(PERP_MKT, MARK_PX);
        v.crank();
        (uint32 asset, uint64 limitPx, bool reduceOnly) = _queuedLimitPx(hub.queueHead());
        assertEq(asset, PERP_MKT);
        assertTrue(reduceOnly, "the exit flatten is reduce-only");
        assertGt(limitPx, 0, "live-mark limit price once the feed returns");
    }
}
