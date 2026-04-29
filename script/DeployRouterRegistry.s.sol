// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {RouterRegistry} from "../src/RouterRegistry.sol";

/**
 * @title DeployRouterRegistry
 * @notice Deploys the optional `RouterRegistry` — a global registry where
 *  relay-router operators advertise themselves. Independent of the ledger / wallet
 *  graph; deploy only if the network needs it.
 *
 * @dev Usage:
 *   forge script script/DeployRouterRegistry.s.sol --rpc-url $RPC_URL --broadcast --verify -vv
 *
 * Environment variables:
 *   PRIVATE_KEY — Deployer private key (required).
 */
contract DeployRouterRegistry is Script {
    function run() external returns (RouterRegistry registry) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerKey);
        registry = new RouterRegistry();
        vm.stopBroadcast();

        console.log("RouterRegistry:", address(registry));
    }
}
