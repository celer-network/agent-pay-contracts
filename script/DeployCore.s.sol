// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {PayRegistry} from "../src/PayRegistry.sol";
import {VirtContractResolver} from "../src/VirtContractResolver.sol";
import {CelerWallet} from "../src/CelerWallet.sol";

/**
 * @title DeployCore
 * @notice Deploys the three permanent (non-versioned) AgentPay contracts on a
 *  fresh network: `PayRegistry`, `VirtContractResolver`, `CelerWallet`. These
 *  are deployed once per network and shared by every `CelerLedger` /
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
 *                 `CelerWallet` Ownable owner (pause / drain / unpause).
 */
contract DeployCore is Script {
    function run()
        external
        returns (PayRegistry payRegistry, VirtContractResolver virtResolver, CelerWallet celerWallet)
    {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerKey);
        payRegistry = new PayRegistry();
        virtResolver = new VirtContractResolver();
        celerWallet = new CelerWallet();
        vm.stopBroadcast();

        console.log("PayRegistry:         ", address(payRegistry));
        console.log("VirtContractResolver:", address(virtResolver));
        console.log("CelerWallet:         ", address(celerWallet));
        console.log("CelerWallet owner:   ", celerWallet.owner());
    }
}
