// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title BooleanCond interface
 */
interface IBooleanCond {
    function isFinalized(bytes calldata _query) external view returns (bool);

    function getOutcome(bytes calldata _query) external view returns (bool);
}
