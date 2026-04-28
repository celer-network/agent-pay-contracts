// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./lib/interface/IRouterRegistry.sol";

/**
 * @title RouterRegistry
 * @notice Optional global registry where relay-router operators advertise themselves
 *  to the AgentPay network. Each registered router stores the latest registration
 *  or refresh `block.number`; off-chain consumers may use this for liveness signaling
 *  and router discovery.
 * @dev See {IRouterRegistry} for canonical NatSpec on each function.
 */
contract RouterRegistry is IRouterRegistry {
    /// @notice Registered router addresses → most recent register/refresh block number.
    mapping(address => uint256) public routerInfo;

    /**
     * @notice An external router could register to join the Celer Network
     */
    function registerRouter() external {
        require(routerInfo[msg.sender] == 0, "Router address already exists");

        routerInfo[msg.sender] = block.number;

        emit RouterUpdated(RouterOperation.Add, msg.sender);
    }

    /**
     * @notice An in-network router could deregister to leave the network
     */
    function deregisterRouter() external {
        require(routerInfo[msg.sender] != 0, "Router address does not exist");

        delete routerInfo[msg.sender];

        emit RouterUpdated(RouterOperation.Remove, msg.sender);
    }

    /**
     * @notice Refresh the existed router's block number
     */
    function refreshRouter() external {
        require(routerInfo[msg.sender] != 0, "Router address does not exist");

        routerInfo[msg.sender] = block.number;

        emit RouterUpdated(RouterOperation.Refresh, msg.sender);
    }
}
