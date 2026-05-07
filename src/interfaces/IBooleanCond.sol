// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title BooleanCond interface
 * @notice Standard interface for app contracts whose outcome resolves to a boolean.
 * @dev Implemented by deployed condition contracts and (when materialized on-chain) by
 *  virtual condition contracts. PayResolver invokes these methods during conditional
 *  payment resolution; the `_query` payload is supplied via `Condition.args_query_*`
 *  fields and is opaque to the AgentPay core. See the App Contracts and Protocols page
 *  in the architecture docs for the broader integration model.
 */
interface IBooleanCond {
    /**
     * @notice Check whether the condition's outcome is finalized and may be queried.
     * @dev `getOutcome` must be safe to call once this returns true; PayResolver
     *  reverts payment resolution if any condition is not yet finalized.
     * @param _query Condition-specific query payload.
     * @return True if the outcome is finalized.
     */
    function isFinalized(bytes calldata _query) external view returns (bool);

    /**
     * @notice Return the boolean outcome of the finalized condition.
     * @param _query Condition-specific query payload.
     * @return The condition's boolean outcome.
     */
    function getOutcome(bytes calldata _query) external view returns (bool);
}
