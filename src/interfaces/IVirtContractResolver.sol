// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title VirtContractResolver interface
 * @notice Materializes off-chain ("virtual") contracts on-chain when a dispute requires
 *  them. Maps a deterministic virtual address — `keccak256(code, nonce)` — to the real
 *  on-chain address produced by deploying that bytecode via `CREATE`. Once deployed,
 *  PayResolver can query the contract through {IBooleanCond} or {INumericCond}.
 */
interface IVirtContractResolver {
    /**
     * @notice Deploy a virtual contract on-chain under its deterministic virtual address.
     * @dev Reverts if a contract has already been deployed under (`_code`, `_nonce`)
     *  or if the underlying `CREATE` fails.
     * @param _code Bytecode of the virtual contract.
     * @param _nonce Nonce that, together with `_code`, derives the virtual address.
     * @return True on successful deployment (reverts otherwise).
     */
    function deploy(bytes calldata _code, uint256 _nonce) external returns (bool);

    /**
     * @notice Resolve a virtual address to its deployed on-chain address.
     * @param _virtAddr `keccak256(code, nonce)` virtual address.
     * @return The deployed contract address, or `address(0)` if not yet deployed.
     */
    function resolve(bytes32 _virtAddr) external view returns (address);

    /// @notice Emitted when a virtual contract is materialized on-chain.
    event Deploy(bytes32 indexed virtAddr);
}
