// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title NumericCond interface
 */
interface INumericCond {
    function isFinalized(bytes calldata _query) external view returns (bool);

    function getOutcome(bytes calldata _query) external view returns (uint256);
}
