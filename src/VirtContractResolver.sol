// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./interfaces/IVirtContractResolver.sol";
import "./lib/AgentPayErrors.sol";

/**
 * @title VirtContractResolver
 * @notice Materializes off-chain ("virtual") contracts on-chain when a dispute requires
 *  them. Maps a deterministic virtual address — `keccak256(code, nonce)` — to the real
 *  on-chain address produced by deploying the bytecode via the `CREATE` opcode.
 * @dev See {IVirtContractResolver} for canonical NatSpec on the external API.
 */
contract VirtContractResolver is IVirtContractResolver {
    /// @dev `keccak256(code, nonce) → deployed address`.
    mapping(bytes32 => address) virtToRealMap;

    /// @inheritdoc IVirtContractResolver
    function deploy(bytes calldata _code, uint256 _nonce) external returns (bool) {
        bytes32 virtAddr = keccak256(abi.encodePacked(_code, _nonce));
        bytes memory c = _code;
        require(virtToRealMap[virtAddr] == address(0), AgentPayErrors.VirtAddressOccupied());
        address deployedAddress;
        assembly {
            deployedAddress := create(0, add(c, 32), mload(c))
        }
        require(deployedAddress != address(0), AgentPayErrors.CreateContractFailed());

        virtToRealMap[virtAddr] = deployedAddress;
        emit Deploy(virtAddr);
        return true;
    }

    /// @inheritdoc IVirtContractResolver
    function resolve(bytes32 _virtAddr) external view returns (address) {
        require(virtToRealMap[_virtAddr] != address(0), AgentPayErrors.VirtAddressUnresolved());
        return virtToRealMap[_virtAddr];
    }
}
