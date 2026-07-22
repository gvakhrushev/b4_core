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

    /// A USDC-only Pro Max deposit gets ZERO strategy exposure under the flat-phi
    /// engine: strategy value is 0, no perp target is ever derivable, the margin
    /// reserve is never touched, and the crank converges with nothing to do.
    function test_V6B_2a_usdc_only_deposit_zero_exposure() public {
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 0, 20_000e6); // $20k USDC only
        uint256 steps = crankUntilIdle(v, 40);

        assertEq(v.usdcMarginEvm(), 20_000e6, "100% parked in owner margin reserve");
        assertEq(v.strategyValueWad(), 0, "strategy value excludes the reserve");
        assertEq(v.navWad(), 20_000e18, "NAV is the parked reserve only");
        assertEq(readSzi(address(v)), 0, "no perp ever opened");
        assertEq(v.perpMargin6(), 0, "margin never deployed");
        assertEq(v.dirEvm(), 0);
        assertEq(v.usdcRotatedEvm(), 0, "no rotation to strategy capital exists");
        // The machine converged (returned false), not spun — the deposit is simply inert.
        assertLt(steps, 40);
    }

    /// A dir-only Pro Max deposit runs UNLEVERED: the spot leg is held but the
    /// leveraged perp leg is silently absent (notionalCap = margin * maxLev / phi = 0).
    function test_V6B_2a_dir_only_deposit_levered_leg_silently_absent() public {
        B4Vault v = createVault(address(proMax));
        fundAndDeposit(v, 1e8, 0); // 1 BTC only, no margin
        uint256 steps = crankUntilIdle(v, 40);

        assertEq(v.dirEvm(), 1e8, "spot leg held");
        assertEq(readSzi(address(v)), 0, "phi-1 perp leg absent: notionalCap == 0");
        assertEq(v.perpMargin6(), 0);
        assertEq(v.navWad(), 100_000e18, "1x spot exposure only, not phi");
        assertLt(steps, 40);
    }
}
