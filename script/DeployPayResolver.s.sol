// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {PayResolver} from "../src/PayResolver.sol";

/**
 * @title DeployPayResolver
 * @notice Deploys a `PayResolver` instance wired against the existing
 *  `PayRegistry` and `VirtContractResolver`. Each `PayResolver` version is chosen
 *  per-payment by the source (field 8 of `ConditionalPay`), so this script can run
 *  any number of times to add a new resolver to the network.
 *
 * @dev Usage:
 *   forge script script/DeployPayResolver.s.sol --rpc-url $RPC_URL --broadcast --verify -vv
 *
 *  Reads the core addresses from `config.json` (or the path in `DEPLOY_CONFIG`).
 *  See [`example_config.json`](example_config.json) for the schema.
 *
 * Environment variables:
 *   PRIVATE_KEY   — Deployer private key (required).
 *   DEPLOY_CONFIG — Path to JSON config file (default: `config.json`).
 */
contract DeployPayResolver is Script {
    function run() external returns (PayResolver resolver) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        string memory configPath = vm.envOr("DEPLOY_CONFIG", string("config.json"));
        string memory config = vm.readFile(configPath);

        address payRegistry = abi.decode(vm.parseJson(config, ".core.payRegistry"), (address));
        address virtResolver = abi.decode(vm.parseJson(config, ".core.virtResolver"), (address));

        require(payRegistry != address(0), "payRegistry address required");
        require(virtResolver != address(0), "virtResolver address required");

        vm.startBroadcast(deployerKey);
        resolver = new PayResolver(payRegistry, virtResolver);
        vm.stopBroadcast();

        console.log("PayResolver:", address(resolver));
    }
}
