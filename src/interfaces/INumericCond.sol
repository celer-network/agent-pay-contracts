// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title NumericCond interface
 * @notice Standard interface for app contracts whose outcome resolves to a uint256.
 * @dev Numeric counterpart to {IBooleanCond}. Used with the NUMERIC_ADD / NUMERIC_MAX
 *  / NUMERIC_MIN transfer functions, where the per-condition `getOutcome` values are
 *  combined to compute the final payment amount.
 */
interface INumericCond {
    /**
     * @notice Check whether the condition's outcome is finalized and may be queried.
     * @param _query Condition-specific query payload.
     * @return True if the outcome is finalized.
     */
    function isFinalized(bytes calldata _query) external view returns (bool);

    /**
     * @notice Return the numeric outcome of the finalized condition.
     * @param _query Condition-specific query payload.
     * @return The condition's numeric outcome.
     */
    function getOutcome(bytes calldata _query) external view returns (uint256);
}
