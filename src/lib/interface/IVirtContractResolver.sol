// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title VirtContractResolver interface
 */
interface IVirtContractResolver {
    function deploy(bytes calldata _code, uint256 _nonce) external returns (bool);

    function resolve(bytes32 _virtAddr) external view returns (address);

    event Deploy(bytes32 indexed virtAddr);
}
