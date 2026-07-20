// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {B4Pool} from "src/core/B4Pool.sol";
import {B4VaultStorage} from "src/core/B4VaultStorage.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";

/// Same gas-griefing token shape as V3Pool_GasGrief.t.sol.
contract GasGriefTokenX {
    mapping(address => uint256) public balances;
    uint8 public constant decimals = 18;
    bool public griefing = true;

    function setGriefing(bool v) external {
        griefing = v;
    }

    function mint(address to, uint256 a) external {
        balances[to] += a;
    }

    function balanceOf(address a) external view returns (uint256) {
        if (griefing) {
            while (gasleft() > 200) {}
        }
        return balances[a];
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balances[msg.sender] -= a;
        balances[to] += a;
        return true;
    }
}

/// @title V3 adversarial PoC — a gas-griefing co-asset freezes a co-resident vault's
///        non-free exit: _finalizeExit calls pool.capture() un-guarded (V2-1 contained
///        reverts, not gas exhaustion), so the exit can never finalize and the vault's
///        accounted funds are locked while the griefers misbehave.
contract V3PoolExitFreezeTest is VaultTestBase {
    GasGriefTokenX[3] grief;
    B4Pool griefPool;

    function setUp() public {
        setUpProtocol();
        // A factory-created pool: USDC + UBTC + three gas-griefing directionals.
        CoreTypes.AssetDescriptor[] memory dirs = new CoreTypes.AssetDescriptor[](4);
        dirs[0] = ubtcDescriptor();
        for (uint256 i = 0; i < 3; i++) {
            grief[i] = new GasGriefTokenX();
            uint64 core = uint64(30 + i);
            uint32 spot = uint32(30 + i);
            hub.registerToken(core, address(grief[i]), 8, 2, 18, "G");
            hub.registerSpotMarket(spot, core, USDC_CORE);
            hub.setSpotPx(spot, 100e6);
            dirs[i + 1] = CoreTypes.AssetDescriptor({
                evmToken: address(grief[i]),
                evmDecimals: 18,
                coreToken: core,
                spotMarket: spot,
                perpMarket: CoreTypes.NO_MARKET,
                coreWeiDecimals: 8,
                spotSzDecimals: 2,
                perpSzDecimals: 0,
                perpMaxLeverage: 0,
                fixedUsd: false
            });
        }
        griefPool = B4Pool(factory.createPool(dirs)); // factory validates every descriptor
    }

    function _createVault() internal returns (B4Vault v) {
        vm.prank(user);
        v = B4Vault(
            factory.createVault(
                address(griefPool),
                CoreTypes.descriptorHash(ubtcDescriptor()),
                address(mini),
                1e18,
                100,
                defaultRoute()
            )
        );
    }

    function _depositAndInitiateExit(B4Vault v) internal {
        fundAndDeposit(v, 1e8, 0); // 1 BTC = $100k, growth window
        warpTo(100 days); // deep growth: NOT a free-exit window (POST_FACT_FREE_EXIT = 20d)
        hub.setSpotPx(SPOT_MKT, 110_000e4); // +10%: profit, penalty > operator cut
        vm.prank(user);
        v.initiateExit(1e18); // full exit; pool share of the penalty > 0
    }

    /// Control: griefers OFF → the non-free exit finalizes; capture runs; owner paid.
    function test_control_exit_finalizes_when_tokens_behave() public {
        for (uint256 i = 0; i < 3; i++) {
            grief[i].setGriefing(false);
        }
        B4Vault v = _createVault();
        _depositAndInitiateExit(v);
        crankUntilIdle(v, 10);
        assertEq(v.exitShareWad(), 0); // finalized
        assertGt(ubtc.balanceOf(user), 0); // owner paid in kind
        assertGt(griefPool.liability(address(ubtc)), 0); // penalty captured by the pool
    }

    /// PASS-AFTER (V3-POOL-1 fix): griefers ON → the gas-capped capture() (and the
    /// try/catch around it in _finalizeExit) means the exit finalizes and the owner is
    /// paid despite the malicious co-assets. No freeze.
    function test_exit_finalizes_despite_grief_coassets() public {
        B4Vault v = _createVault();
        _depositAndInitiateExit(v);

        crankUntilIdle(v, 10);
        assertEq(v.exitShareWad(), 0); // finalized despite the grievers
        assertGt(ubtc.balanceOf(user), 0); // owner paid in kind (gross − penalty)
        assertLt(v.dirEvm(), 1e4); // accounted funds left the vault (only flooring dust)
        assertGt(griefPool.liability(address(ubtc)), 0); // penalty captured too
    }
}
