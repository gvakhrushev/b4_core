// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VenueTestBase} from "../utils/VenueTestBase.sol";
import {MockLzEndpoint} from "../mocks/MockLzEndpoint.sol";
import {B4Pool} from "src/core/B4Pool.sol";
import {HalvingOracle} from "src/core/HalvingOracle.sol";
import {Calendar} from "src/libraries/Calendar.sol";
import {CoreTypes} from "src/venue/CoreTypes.sol";

/// @notice ERC20 whose balanceOf burns ~all forwarded gas. V2-1 contained REVERTING or
///         return-bombing balanceOf reads, but both _safeBalanceOf and SafeTransfer._call
///         forward `gas()` — i.e. ~63/64 of the caller's remaining gas — to the untrusted
///         token. A gas-griefing hook therefore destroys 63/64 of the transaction's gas
///         budget per read; with enough griefing tokens early in the basket, the loop in
///         claimFor/capture cannot finish inside ANY block gas limit (each read leaves
///         1/64 of the budget; the trailing per-asset work is fixed), so the whole
///         transaction OOG-reverts — including the settlement token's payment/capture.
contract GasGriefToken {
    mapping(address => uint256) public balances;
    uint8 public constant decimals = 18;
    bool public griefing = true;

    function setGriefing(bool v) external {
        griefing = v;
    }

    function mint(address to, uint256 a) external {
        balances[to] += a;
    }

    function _burn() internal view {
        while (gasleft() > 200) {}
    }

    function balanceOf(address a) external view returns (uint256) {
        if (griefing) _burn();
        return balances[a];
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balances[msg.sender] -= a;
        balances[to] += a;
        return true;
    }
}

contract MockVaultG {
    address public owner;

    constructor(address o) {
        owner = o;
    }

    function report(B4Pool pool, uint256 id, uint256 weight) external {
        pool.reportWeight(id, weight);
    }
}

/// @title V3 adversarial PoC — gas-griefing token hooks vs V2-1 containment.
contract V3PoolGasGriefTest is VenueTestBase {
    uint32 constant SRC_EID = 30_101;
    bytes32 constant SRC_SENDER = bytes32(uint256(1));
    uint256 constant GENESIS_HEIGHT = 840_000;
    uint256 constant GENESIS_TS = 1_713_571_767;

    MockLzEndpoint endpoint;
    HalvingOracle oracle;
    B4Pool pool;
    GasGriefToken[3] grief;
    MockVaultG vaultA;
    address ownerA = address(0xA11CE);

    function setUp() public {
        vm.warp(GENESIS_TS);
        setUpVenue();
        endpoint = new MockLzEndpoint();
        oracle = new HalvingOracle(
            address(endpoint), SRC_EID, SRC_SENDER, GENESIS_HEIGHT, GENESIS_TS, address(this)
        );

        CoreTypes.AssetDescriptor[] memory ds = new CoreTypes.AssetDescriptor[](5);
        ds[0] = usdcDescriptor();
        for (uint256 i = 0; i < 3; i++) {
            grief[i] = new GasGriefToken();
            uint64 core = uint64(20 + i);
            uint32 spot = uint32(20 + i);
            hub.registerToken(core, address(grief[i]), 8, 2, 18, "G");
            hub.registerSpotMarket(spot, core, USDC_CORE);
            hub.setSpotPx(spot, 100e6);
            ds[i + 1] = CoreTypes.AssetDescriptor({
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
        ds[4] = ubtcDescriptor(); // honest directional AFTER the griefers
        pool = new B4Pool(address(oracle), ds); // test acts as factory

        vaultA = new MockVaultG(ownerA);
        pool.registerVault(address(vaultA));
    }

    function _setGriefing(bool v) internal {
        for (uint256 i = 0; i < 3; i++) {
            grief[i].setGriefing(v);
        }
    }

    function _setupClaimable() internal returns (uint256 id) {
        _setGriefing(false);
        usdc.mint(address(pool), 1_000e6);
        ubtc.mint(address(pool), 2e8);
        for (uint256 i = 0; i < 3; i++) {
            grief[i].mint(address(pool), 50e18);
        }
        pool.capture(); // book all five while healthy
        _setGriefing(true);

        vm.warp(GENESIS_TS + Calendar.P - Calendar.H);
        pool.advance();
        id = pool.intervalCount() - 1;
        pool.lockPrices(id);
        vaultA.report(pool, id, 1e18);
        vm.warp(pool.reportDeadline(id) + 1);
    }

    /// Baseline shape: with no gas-griefing, everything pays (V2-1 harness sanity).
    function test_noGrief_everythingPays() public {
        uint256 id = _setupClaimable();
        _setGriefing(false);
        pool.claimFor(id, address(vaultA));
        assertEq(usdc.balanceOf(ownerA), 1_000e6);
        assertEq(ubtc.balanceOf(ownerA), 2e8);
    }

    /// PASS-AFTER (V3-POOL-1 fix): ONE gas-griefing token — its read is now gas-CAPPED, so
    /// the claim survives cheaply (no 63/64 blowup) and only its own claim defers.
    function test_oneGriever_claimSurvives_cheaply() public {
        uint256 id = _setupClaimable();
        grief[1].setGriefing(false);
        grief[2].setGriefing(false); // only grief[0] burns

        uint256 g0 = gasleft();
        pool.claimFor{gas: 25_000_000}(id, address(vaultA));
        uint256 used = g0 - gasleft();

        assertEq(usdc.balanceOf(ownerA), 1_000e6);
        assertEq(ubtc.balanceOf(ownerA), 2e8);
        assertFalse(pool.claimedOf(id, address(vaultA), 1)); // grief[0] deferred
        assertLt(used, 2_000_000); // the gas cap bounds the griefer's burn
    }

    /// PASS-AFTER: THREE griefing tokens no longer OOG the claim — each read is capped, so
    /// claimFor completes, the settlement USDC and honest UBTC pay, and only the grievers
    /// defer (D5 per-token isolation restored).
    function test_grievers_claimFor_survives() public {
        uint256 id = _setupClaimable();
        pool.claimFor{gas: 29_000_000}(id, address(vaultA));
        assertEq(usdc.balanceOf(ownerA), 1_000e6); // settlement paid
        assertEq(ubtc.balanceOf(ownerA), 2e8); // honest directional paid
        assertTrue(pool.claimedOf(id, address(vaultA), 0)); // USDC claimed
        assertTrue(pool.claimedOf(id, address(vaultA), 4)); // UBTC claimed
        for (uint256 i = 1; i <= 3; i++) {
            assertFalse(pool.claimedOf(id, address(vaultA), i)); // grievers deferred
        }
    }

    /// PASS-AFTER: capture() skips the gas-capped grievers and captures the healthy tokens.
    function test_grievers_capture_survives() public {
        _setupClaimable();
        uint256 liabBefore = pool.liability(address(usdc));
        usdc.mint(address(pool), 100e6);
        pool.capture{gas: 29_000_000}();
        assertEq(pool.liability(address(usdc)), liabBefore + 100e6); // healthy token captured
    }

    /// Control: grievers disabled again → capture and claims work (the freeze is the
    /// gas-grief, nothing else).
    function test_grieversDisabled_recovers() public {
        uint256 id = _setupClaimable();
        _setGriefing(false);
        usdc.mint(address(pool), 100e6);
        pool.capture();
        pool.claimFor(id, address(vaultA));
        assertEq(usdc.balanceOf(ownerA), 1_000e6 + 0); // bucket share paid
        assertGt(ubtc.balanceOf(ownerA), 0);
    }
}
