// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {CelerLedger} from "../src/CelerLedger.sol";

/**
 * @title DeployLedger
 * @notice Deploys a `CelerLedger` instance wired against the existing core
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
 *                    `CelerLedger` Ownable owner (`setBalanceLimits`,
 *                    `enableBalanceLimits`, `disableBalanceLimits`).
 *   DEPLOY_CONFIG — Path to JSON config file (default: `config.json`).
 */
contract DeployLedger is Script {
    function run() external returns (CelerLedger ledger) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        string memory configPath = vm.envOr("DEPLOY_CONFIG", string("config.json"));
        string memory config = vm.readFile(configPath);

        address nativeWrap = abi.decode(vm.parseJson(config, ".core.nativeWrap"), (address));
        address payRegistry = abi.decode(vm.parseJson(config, ".core.payRegistry"), (address));
        address celerWallet = abi.decode(vm.parseJson(config, ".core.celerWallet"), (address));

        require(nativeWrap != address(0), "nativeWrap address required");
        require(payRegistry != address(0), "payRegistry address required");
        require(celerWallet != address(0), "celerWallet address required");

        vm.startBroadcast(deployerKey);
        ledger = new CelerLedger(nativeWrap, payRegistry, celerWallet);
        vm.stopBroadcast();

        console.log("CelerLedger:       ", address(ledger));
        console.log("CelerLedger owner: ", ledger.owner());
        console.log("Balance limits enabled by default. Configure or disable via the post-deploy checklist.");
    }
}
