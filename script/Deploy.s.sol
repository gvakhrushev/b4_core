// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {HalvingOracle} from "../src/core/HalvingOracle.sol";
import {B4Factory} from "../src/core/B4Factory.sol";
import {B4ProductFactory} from "../src/core/B4ProductFactory.sol";
import {B4PoolDeployer} from "../src/core/B4PoolDeployer.sol";
import {B4Vault} from "../src/core/B4Vault.sol";
import {B4VaultOps} from "../src/core/B4VaultOps.sol";
import {B4VaultRecovery} from "../src/core/B4VaultRecovery.sol";
import {CoreTypes} from "../src/venue/CoreTypes.sol";

/// @notice Deployment wiring for the target network. Every address/decimal below MUST be
///         confirmed by the funded release gates (SECURITY_MODEL §5) before mainnet:
///         canonical USDC identity/decimals, LayerZero endpoint + EIDs + DVN config,
///         Citrea light client, and the whole venue-semantics gate list in docs/audits/REPORT.md.
///         After configuration, `renounceDelegate()` MUST be executed one-shot on both
///         LayerZero sides and verified on-chain (E3).
contract Deploy is Script {
    function run() external {
        // ---- environment (placeholders: funded-gate values) ----
        address lzEndpoint = vm.envAddress("LZ_ENDPOINT");
        uint32 srcEid = uint32(vm.envUint("CITREA_EID"));
        bytes32 srcSender = vm.envBytes32("PROVER_ADDRESS_B32");
        uint256 bootstrapHeight = vm.envUint("BOOTSTRAP_HALVING_HEIGHT");
        address configurator = vm.envAddress("LZ_CONFIGURATOR"); // removed one-shot later

        CoreTypes.AssetDescriptor memory usdc = CoreTypes.AssetDescriptor({
            evmToken: vm.envAddress("USDC_EVM"),
            evmDecimals: 6,
            // MUST be 0. Binding asserts the settlement descriptor IS the venue's quote token
            // (`DescriptorLib.verifySettlement`), because `usdClassTransfer` moves that token
            // unconditionally; any other index reverts `BadSettlement` here, at deployment.
            coreToken: uint64(vm.envUint("USDC_CORE_INDEX")),
            spotMarket: CoreTypes.NO_MARKET,
            perpMarket: CoreTypes.NO_MARKET,
            coreWeiDecimals: 8,
            spotSzDecimals: 0,
            perpSzDecimals: 0,
            perpMaxLeverage: 0,
            fixedUsd: true
        });

        vm.startBroadcast();
        HalvingOracle oracle =
            new HalvingOracle(lzEndpoint, srcEid, srcSender, bootstrapHeight, configurator);
        // Separate deployments (EIP-3860); both belong in the reproducible-build
        // manifest together with constructor args (gate §5.14).
        B4VaultOps ops = new B4VaultOps();
        B4VaultRecovery recoveryModule = new B4VaultRecovery();
        B4Vault implementation = new B4Vault(address(ops), address(recoveryModule));
        // Holds B4Pool's creation code once, so the factories do not each embed it and
        // blow EIP-170 (see B4PoolDeployer). Deploy it separately and pass it by address —
        // a factory that constructed its own would re-embed the code.
        B4PoolDeployer poolDeployer = new B4PoolDeployer();
        new B4Factory(address(oracle), usdc, address(implementation), address(poolDeployer));
        vm.stopBroadcast();
    }
}
