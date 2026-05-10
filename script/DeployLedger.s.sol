// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {AgentPayLedger} from "../src/AgentPayLedger.sol";

/**
 * @title DeployLedger
 * @notice Deploys a `AgentPayLedger` instance wired against the existing core
 *  contracts and the chain's canonical wrapped-native (wrapped-native)
 *  contract. Run once per ledger version — peers cooperatively migrate
 *  channels between versions; the wallet / registry / nativeWrap stay shared.
 *
 * @dev Usage:
 *   forge script script/DeployLedger.s.sol --rpc-url $RPC_URL --broadcast --verify -vv
 *
 *  Reads the core addresses (including `nativeWrap`) from `config.json` (or
 *  the path in `DEPLOY_CONFIG`). See [`example_config.json`](example_config.json)
 *  for the schema.
 *
 * Environment variables:
 *   PRIVATE_KEY   — Deployer private key (required). Deployer becomes the
 *                    `AgentPayLedger` Ownable owner (`setBalanceLimits`,
 *                    `enableBalanceLimits`, `disableBalanceLimits`).
 *   DEPLOY_CONFIG — Path to JSON config file (default: `config.json`).
 */
contract DeployLedger is Script {
    function run() external returns (AgentPayLedger ledger) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        string memory configPath = vm.envOr("DEPLOY_CONFIG", string("config.json"));
        string memory config = vm.readFile(configPath);

        address nativeWrap = abi.decode(vm.parseJson(config, ".core.nativeWrap"), (address));
        address payRegistry = abi.decode(vm.parseJson(config, ".core.payRegistry"), (address));
        address wallet = abi.decode(vm.parseJson(config, ".core.wallet"), (address));

        require(nativeWrap != address(0), "nativeWrap address required");
        require(payRegistry != address(0), "payRegistry address required");
        require(wallet != address(0), "wallet address required");

        vm.startBroadcast(deployerKey);
        ledger = new AgentPayLedger(nativeWrap, payRegistry, wallet);
        vm.stopBroadcast();

        console.log("AgentPayLedger:       ", address(ledger));
        console.log("AgentPayLedger owner: ", ledger.owner());
        console.log("Balance limits enabled by default. Configure or disable via the post-deploy checklist.");
    }
}
