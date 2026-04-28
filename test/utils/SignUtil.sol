// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";

/**
 * @title SignUtil
 * @notice Co-sign helpers for AgentPay tests. Takes the keccak256 of the
 *  serialized message, applies the EIP-191 prefix
 *  (`MessageHashUtils.toEthSignedMessageHash`) the contracts use to verify,
 *  and returns a 65-byte (r,s,v) signature with `v ∈ {27, 28}`.
 */
library SignUtil {
    Vm internal constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev EIP-191 prefix the contracts apply via `toEthSignedMessageHash`.
    function ethSignedHash(bytes memory _msg) internal pure returns (bytes32) {
        bytes32 messageHash = keccak256(_msg);
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
    }

    /// @dev Sign a serialized protobuf message with `_pk`. Returns 65-byte (r,s,v).
    function sign(uint256 _pk, bytes memory _msg) internal pure returns (bytes memory sig) {
        bytes32 ethHash = ethSignedHash(_msg);
        (uint8 v, bytes32 r, bytes32 s) = VM.sign(_pk, ethHash);
        sig = abi.encodePacked(r, s, v);
    }

    /// @dev Co-sign with two keys, in the same order as their addresses sort ascending.
    ///  Caller is responsible for ensuring (`_pk0`'s addr < `_pk1`'s addr) — pass keys
    ///  for already-sorted peer pair (see `BaseTest._makeSortedPeerPair`).
    function coSign(uint256 _pk0, uint256 _pk1, bytes memory _msg) internal pure returns (bytes[] memory sigs) {
        sigs = new bytes[](2);
        sigs[0] = sign(_pk0, _msg);
        sigs[1] = sign(_pk1, _msg);
    }
}
