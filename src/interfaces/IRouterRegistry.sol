// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title RouterRegistry interface
 * @notice Optional global registry where relay-router operators advertise themselves
 *  to the AgentPay network. The registry stores the unix timestamp (seconds) of
 *  the latest registration / refresh per router address; consumers may use it to
 *  discover live routers off-chain.
 */
interface IRouterRegistry {
    /// @notice Type of a {RouterUpdated} event.
    enum RouterOperation {
        Add,
        Remove,
        Refresh
    }

    /**
     * @notice Register `msg.sender` as a router; reverts if already registered.
     * @dev Stores the current `block.timestamp` against the caller's address.
     */
    function registerRouter() external;

    /**
     * @notice Deregister `msg.sender`; reverts if not currently registered.
     */
    function deregisterRouter() external;

    /**
     * @notice Refresh `msg.sender`'s stored timestamp; reverts if not registered.
     * @dev Used by routers to signal liveness without removing/re-adding.
     */
    function refreshRouter() external;

    /// @notice Emitted on every register / deregister / refresh.
    event RouterUpdated(RouterOperation indexed op, address indexed routerAddress);
}
