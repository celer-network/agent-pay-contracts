// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../interfaces/INumericCond.sol";

/**
 * @title NumericCondMock
 * @notice **Test-only.** Minimal {INumericCond} that decodes both `isFinalized`
 *  and `getOutcome` directly from their respective query bytes.
 *
 *  - `isFinalized(_query)`: a single byte where `0x00 → false` and any other
 *    value → `true`. Empty query defaults to `true`.
 *  - `getOutcome(_query)`: big-endian unsigned integer parsed from the query
 *    bytes. Empty query → `0`.
 *
 *  This shape lets a single deployed instance simulate every combination of
 *  (finalized, outcome) — useful for both Solidity tests and off-chain
 *  integration tests. **Do not deploy to a production network.**
 */
contract NumericCondMock is INumericCond {
    function isFinalized(bytes calldata _query) external pure returns (bool) {
        if (_query.length == 0) {
            return true;
        }
        return _bytesToUint(_query) != 0;
    }

    function getOutcome(bytes calldata _query) external pure returns (uint256) {
        return _bytesToUint(_query);
    }

    function _bytesToUint(bytes memory _b) internal pure returns (uint256) {
        if (_b.length == 0) {
            return 0;
        }

        uint256 v;
        assembly {
            v := mload(add(_b, 32))
        } // load all 32bytes to v
        v = v >> (8 * (32 - _b.length)); // only first _b.length is valid

        return v;
    }
}
