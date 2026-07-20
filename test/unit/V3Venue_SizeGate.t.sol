// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {B4VaultOps} from "src/core/B4VaultOps.sol";
import {Keeper} from "src/periphery/Keeper.sol";

/// @notice V3-VENUE-3 fix: an ENFORCED EIP-170 gate. `forge build --sizes` is informational
///         and CI stayed green as B4Vault crept to 24,022/24,576 B (554 B margin); a later
///         addition would silently push a real deployment over the 24,576 B contract-code
///         limit with the suite still passing. This test deploys every protocol contract and
///         asserts its runtime code fits, so any size regression fails a test rather than a
///         mainnet deploy. B4Vault is the binding one (delegatecalls B4VaultOps precisely to
///         stay under the limit), so it also carries an explicit min-margin floor: if that
///         floor trips, move more logic into the ops module before shipping.
contract V3VenueSizeGateTest is VaultTestBase {
    /// EIP-170 deployed-contract code size limit.
    uint256 constant EIP170_LIMIT = 24_576;
    /// Minimum headroom we require for the binding contract (B4Vault). A drop below this is
    /// a signal to shift logic into B4VaultOps, not to weaken the check.
    uint256 constant MIN_VAULT_MARGIN = 128;

    function setUp() public {
        setUpProtocol();
    }

    function _assertFits(string memory name, address a) internal {
        uint256 sz = a.code.length;
        assertGt(sz, 0, string.concat(name, ": not deployed"));
        assertLe(sz, EIP170_LIMIT, string.concat(name, ": over EIP-170 limit"));
        emit log_named_uint(string.concat(name, " runtime bytes"), sz);
    }

    /// Every deployed protocol contract fits under EIP-170.
    function test_V3VENUE3_all_contracts_under_eip170() public {
        // Fresh B4Vault implementation (the factory's impl is created the same way).
        B4Vault vaultImpl = new B4Vault(address(new B4VaultOps()));
        Keeper keeper = new Keeper();

        _assertFits("B4Vault", address(vaultImpl));
        _assertFits("B4VaultOps", address(new B4VaultOps()));
        _assertFits("B4Factory", address(factory));
        _assertFits("B4Pool", address(pool));
        _assertFits("HalvingOracle", address(oracle));
        _assertFits("Keeper", address(keeper));
    }

    /// B4Vault is the tight one: enforce a minimum EIP-170 margin so a creeping addition
    /// trips a test (with a clear remedy) well before it bricks a real deployment.
    function test_V3VENUE3_vault_keeps_min_margin() public {
        B4Vault vaultImpl = new B4Vault(address(new B4VaultOps()));
        uint256 sz = address(vaultImpl).code.length;
        assertLe(
            sz,
            EIP170_LIMIT - MIN_VAULT_MARGIN,
            "B4Vault margin below floor: move logic into B4VaultOps"
        );
        emit log_named_uint("B4Vault margin (B)", EIP170_LIMIT - sz);
    }
}
