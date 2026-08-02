// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VaultTestBase} from "../utils/VaultTestBase.sol";
import {B4Vault} from "src/core/B4Vault.sol";
import {B4ProductFactory} from "src/core/B4ProductFactory.sol";
import {B4VaultRecovery} from "src/core/B4VaultRecovery.sol";

/// @notice EIP-170 guard for every contract the protocol actually deploys.
///
/// AUDIT-2026-07-25 found the previous guard covered only `B4ProductPoolCreator`, while
/// `B4VaultOps` sat 115 bytes under the limit. `B4Vault` and `B4VaultOps` BOTH inherit
/// `B4VaultEngine`, so every byte added to the engine is paid twice — a remediation round
/// touching the engine can silently overflow. Because `VaultTestBase.setUpProtocol`
/// deploys `B4VaultOps`, that overflow kills the whole suite at setup with no legible
/// failure, which is why this test exists and why it prints every size.
///
/// Measured on deployed instances rather than `type(C).runtimeCode`: the latter is
/// unavailable for contracts holding immutables, which most of these do.
contract Eip170SizesTest is VaultTestBase {
    uint256 constant LIMIT = 24_576;

    function setUp() public {
        setUpProtocol();
    }

    function test_all_deployed_contracts_fit_eip170() public {
        address vaultImpl = factory.vaultImplementation();
        address ops = B4Vault(vaultImpl).ops();

        B4ProductFactory pf = new B4ProductFactory(
            address(oracle), usdcDescriptor(), vaultImpl, address(poolDeployer)
        );

        _check("B4Vault", vaultImpl);
        _check("B4VaultOps", ops);
        _check("B4VaultRecovery", B4Vault(vaultImpl).recovery());
        _check("B4PoolDeployer", address(poolDeployer));
        _check("B4Pool", address(pool));
        _check("B4Factory", address(factory));
        _check("B4FactoryVaultCreator", factory.vaultCreator());
        _check("B4ProductFactory", address(pf));
        _check("B4ProductPoolCreator", pf.poolCreator());
    }

    function _check(string memory name, address a) internal {
        uint256 n = a.code.length;
        // Report, never underflow: an overflowing contract must produce a legible size,
        // not a panic that hides which contract blew the limit.
        if (n < LIMIT) {
            emit log_named_uint(string.concat(name, " headroom"), LIMIT - n);
        } else {
            emit log_named_uint(string.concat(name, " OVER by"), n - LIMIT);
        }
        assertLt(n, LIMIT, name);
    }
}
