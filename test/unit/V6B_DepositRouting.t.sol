// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";

/// @notice V6 scope B, item 2(a): adjudicate the recorded C7 remnant against current
///         code — deposit() routes 100% of USDC into the owner-margin reserve that
///         _strategyValueWad excludes, with no conversion path and no exposure event.
contract V6B_DepositRoutingTest is VaultTestBase {
    function setUp() public {
        setUpProtocol();
    }

    function readSzi(address who) internal view returns (int64) {
        (bool ok, bytes memory ret) =
            CoreTypes.PRECOMPILE_POSITION.staticcall(abi.encode(who, uint16(PERP_MKT)));
        require(ok, "read");
        CoreTypes.Position memory p = abi.decode(ret, (CoreTypes.Position));
        return p.szi;
    }

    /// FIXED (SPEC §5 pure-perp + USDC-as-strategy): a USDC-only Pro Max deposit now OPENS its
    /// leveraged perp long — USDC is strategy capital (not a segregated margin reserve), so the
    /// φ perp long sizes on it and margins from it. Previously this deposit was inert.
    function test_V6B_2a_usdc_only_deposit_opens_leveraged_long() public {
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 0, 20_000e6); // $20k USDC only
        crankUntilIdle(v, 40);

        assertEq(v.navWad(), 20_000e18, "NAV is the deposit, conserved");
        // Structural §7b deploys the WHOLE deposit as margin (margin = notional/L), so the
        // strategy USDC drains out of strategyValue into perpMargin6 — that it funded the perp
        // (not the excluded owner reserve) is the "USDC = strategy capital" proof, no idle reserve.
        assertApproxEqAbs(
            uint256(v.perpMargin6()),
            20_000e6,
            200e6,
            "whole USDC deposit deployed as perp margin (C7)"
        );
        assertGt(readSzi(address(v)), 0, "phi perp long opens from USDC-only funding");
        assertGt(v.perpMargin6(), 0, "margin deployed from the strategy USDC");
        assertEq(v.dirEvm(), 0, "no directional spot for a pure-perp product");
    }

    /// FIXED (SPEC §5 pure-perp + V6-M-2): a dir-only Pro Max deposit now OPENS its leveraged
    /// perp long. Growth φ decomposes to spot 0 / perp φ, so the vault sells the deposited BTC
    /// into strategy USDC and stands the φ perp long up on it — no separate margin deposit, and
    /// the leg is no longer silently absent.
    function test_V6B_2a_dir_only_promax_opens_leveraged_long() public {
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 1e8, 0); // 1 BTC only, no margin
        crankUntilIdle(v, 40);

        assertGt(readSzi(address(v)), 0, "phi perp long opens from BTC-only funding");
        assertGt(v.perpMargin6(), 0, "margin funded by selling the deposited BTC");
        assertEq(v.dirEvm(), 0, "BTC fully sold into the pure-perp position");
        // Leverage engaged: perp notional exceeds the deposit value (phi net of carved margin).
        uint256 notional6 = uint256(uint64(readSzi(address(v)))) * MARK_PX;
        assertGt(notional6, 100_000e6, "levered above 1x, not 1x spot");
    }
}
