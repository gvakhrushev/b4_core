// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {HalvingOracle} from "../src/core/HalvingOracle.sol";
import {B4Factory} from "../src/core/B4Factory.sol";
import {B4Vault} from "../src/core/B4Vault.sol";
import {B4VaultOps} from "../src/core/B4VaultOps.sol";
import {CoreTypes} from "../src/venue/CoreTypes.sol";

/// @notice Deployment wiring for the target network. Every address/decimal below MUST be
///         confirmed by the funded release gates (SECURITY_MODEL §5) before mainnet:
///         canonical USDC identity/decimals, LayerZero endpoint + EIDs + DVN config,
///         Citrea light client, and the whole venue-semantics gate list in REPORT.md.
///         After configuration, `renounceDelegate()` MUST be executed one-shot on both
///         LayerZero sides and verified on-chain (E3).
contract Deploy is Script {
    function run() external {
        // ---- environment (placeholders: funded-gate values) ----
        address lzEndpoint = vm.envAddress("LZ_ENDPOINT");
        uint32 srcEid = uint32(vm.envUint("CITREA_EID"));
        bytes32 srcSender = vm.envBytes32("PROVER_ADDRESS_B32");
        uint256 genesisHeight = vm.envUint("GENESIS_HALVING_HEIGHT"); // multiple of 210000
        uint256 genesisTs = vm.envUint("GENESIS_HALVING_TS"); // from the halving header
        address configurator = vm.envAddress("LZ_CONFIGURATOR"); // removed one-shot later

        CoreTypes.AssetDescriptor memory usdc = CoreTypes.AssetDescriptor({
            evmToken: vm.envAddress("USDC_EVM"),
            evmDecimals: 6,
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
        HalvingOracle oracle = new HalvingOracle(
            lzEndpoint, srcEid, srcSender, genesisHeight, genesisTs, configurator
        );
        // Separate deployments (EIP-3860); both belong in the reproducible-build
        // manifest together with constructor args (gate §5.14).
        B4VaultOps ops = new B4VaultOps();
        B4Vault implementation = new B4Vault(address(ops));
        new B4Factory(address(oracle), usdc, address(implementation));
        vm.stopBroadcast();
    }
}
