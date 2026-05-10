// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {PayRegistry} from "../src/PayRegistry.sol";
import {VirtContractResolver} from "../src/VirtContractResolver.sol";
import {AgentPayWallet} from "../src/AgentPayWallet.sol";

/**
 * @title DeployCore
 * @notice Deploys the three permanent (non-versioned) AgentPay contracts on a
 *  fresh network: `PayRegistry`, `VirtContractResolver`, `AgentPayWallet`. These
 *  are deployed once per network and shared by every `AgentPayLedger` /
 *  `PayResolver` version that follows.
 *
 * @dev Usage:
 *   forge script script/DeployCore.s.sol --rpc-url $RPC_URL --broadcast --verify -vv
 *
 *  After deploy, paste the three addresses into `config.json`'s `core` block
 *  (see [`example_config.json`](example_config.json)) along with the chain's
 *  canonical `nativeWrap` (wrapped-native) address, before running
 *  `DeployLedger` or `DeployPayResolver`.
 *
 * Environment variables:
 *   PRIVATE_KEY — Deployer private key (required). Deployer becomes the
 *                 `AgentPayWallet` Ownable owner (pause / drain / unpause).
 */
contract DeployCore is Script {
    function run()
        external
        returns (PayRegistry payRegistry, VirtContractResolver virtResolver, AgentPayWallet wallet)
    {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerKey);
        payRegistry = new PayRegistry();
        virtResolver = new VirtContractResolver();
        wallet = new AgentPayWallet();
        vm.stopBroadcast();

        console.log("PayRegistry:         ", address(payRegistry));
        console.log("VirtContractResolver:", address(virtResolver));
        console.log("AgentPayWallet:         ", address(wallet));
        console.log("AgentPayWallet owner:   ", wallet.owner());
    }
}
