// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {B4ProductFactory} from "src/core/B4ProductFactory.sol";
import {B4Pool} from "src/core/B4Pool.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {B4VaultStorage} from "src/core/B4VaultStorage.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {Phi} from "src/libraries/Phi.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";

/// @notice Regression for AUDIT-2026-07-25 H-1 — `capturePenalty` escrowed the pool's ENTIRE
///         unattributed balance of the settlement token and of the caller's directional
///         token into the CALLER's product sleeve, rather than the receipt the calling exit
///         actually produced. Any dust vault finalizing an exit therefore swept whatever
///         else happened to be sitting unattributed — donations, returned sleeve capital,
///         another vault's uncaptured penalty — into a sleeve of its own choosing. The value
///         never left the pool, but it left ordinary claim inventory, and claimants could
///         never reach it again.
///
/// The fix measures the receipt: `beginPenalty()` snapshots balances in transient storage
/// immediately before the exit pushes its penalty in, and `capturePenalty()` escrows only
/// `min(unaccounted, measured increase)`. Anything above that stays claim inventory.
contract AuditH1_PenaltyReceiptTest is VaultTestBase {
    B4ProductFactory productFactory;
    address[4] strategies;
    uint256 constant DIR = 1;

    function setUp() public {
        setUpProtocol();
        productFactory = new B4ProductFactory(
            address(oracle), usdcDescriptor(), factory.vaultImplementation(), address(poolDeployer)
        );
        strategies = [address(mini), address(b4), address(pro), address(proMax)];
    }

    function _proPool() internal returns (B4Pool p) {
        CoreTypes.AssetDescriptor[] memory dirs = new CoreTypes.AssetDescriptor[](1);
        dirs[0] = ubtcDescriptor();
        p = B4Pool(productFactory.createProductPool(dirs, strategies, 1)); // isolated Mini
    }

    function test_H1_capture_takes_only_this_exits_receipt_not_the_whole_balance() public {
        B4Pool p = _proPool();

        vm.prank(user);
        B4Vault v = B4Vault(
            productFactory.createVault(
                address(p),
                CoreTypes.descriptorHash(ubtcDescriptor()),
                address(mini),
                Phi.WAD,
                100,
                B4VaultStorage.FeeRoute(address(0), 0, address(0), 0)
            )
        );

        ubtc.mint(user, 1e8);
        vm.startPrank(user);
        ubtc.approve(address(v), 1e8);
        v.deposit(1e8, 0);
        vm.stopPrank();
        crankUntilIdle(v, 20);

        // A stranger's donation is sitting at the pool, unattributed, in the SAME two tokens
        // the exit's penalty will arrive in.
        uint256 donationBtc = 5e7;
        uint256 donationUsdc = 250_000e6;
        ubtc.mint(address(p), donationBtc);
        usdc.mint(address(p), donationUsdc);

        // Exit OUTSIDE every free window (plain Growth zone) so a penalty is actually taken.
        vm.warp(GENESIS_TS + 100 days);
        assertFalse(Calendar.freeExit(100 days), "must be a penalised exit");

        uint256 escrowBtcBefore = p.escrowHeld(address(ubtc));
        vm.prank(user);
        v.initiateExit(Phi.WAD);
        crankUntilIdle(v, 40);
        assertEq(v.exitShareWad(), 0, "exit completed");

        uint256 escrowedBtc = p.escrowHeld(address(ubtc)) - escrowBtcBefore;

        // The penalty is EXIT_Q of the exiting gross, which is far below the donation.
        assertGt(escrowedBtc, 0, "the exit's own penalty was escrowed");
        assertLt(escrowedBtc, donationBtc, "the donation was NOT swept into the sleeve");

        // The donation stayed reachable as ordinary claim inventory instead.
        p.capture();
        assertGe(
            p.liability(address(usdc)), donationUsdc, "donated USDC is claimable, not escrowed"
        );
        assertEq(p.escrowHeld(address(usdc)), 0, "no settlement token was mis-escrowed");

        // D2 holds on both tokens throughout.
        assertGe(
            ubtc.balanceOf(address(p)), p.liability(address(ubtc)) + p.escrowHeld(address(ubtc))
        );
        assertGe(
            usdc.balanceOf(address(p)), p.liability(address(usdc)) + p.escrowHeld(address(usdc))
        );
    }
}
