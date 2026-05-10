// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./interfaces/IRouterRegistry.sol";
import "./lib/AgentPayErrors.sol";

/**
 * @title RouterRegistry
 * @notice Optional global registry where relay-router operators advertise themselves
 *  to the AgentPay network. Each registered router stores the unix timestamp
 *  (seconds) of its most recent registration or refresh; off-chain consumers may
 *  use this for liveness signaling and router discovery.
 * @dev See {IRouterRegistry} for canonical NatSpec on each function.
 */
contract RouterRegistry is IRouterRegistry {
    /// @notice Registered router addresses → unix timestamp (seconds) of most recent register/refresh.
    mapping(address => uint256) public routerInfo;

    /**
     * @notice An external router could register to join the AgentPay Network
     */
    function registerRouter() external {
        require(routerInfo[msg.sender] == 0, AgentPayErrors.RouterAlreadyRegistered());

        routerInfo[msg.sender] = block.timestamp;

        emit RouterUpdated(RouterOperation.Add, msg.sender);
    }

    /**
     * @notice An in-network router could deregister to leave the network
     */
    function deregisterRouter() external {
        require(routerInfo[msg.sender] != 0, AgentPayErrors.RouterNotRegistered());

        delete routerInfo[msg.sender];

        emit RouterUpdated(RouterOperation.Remove, msg.sender);
    }

    /**
     * @notice Refresh the existed router's stored timestamp
     */
    function refreshRouter() external {
        require(routerInfo[msg.sender] != 0, AgentPayErrors.RouterNotRegistered());

        routerInfo[msg.sender] = block.timestamp;

        emit RouterUpdated(RouterOperation.Refresh, msg.sender);
    }
}
