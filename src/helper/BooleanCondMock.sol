// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../interfaces/IBooleanCond.sol";

/**
 * @title BooleanCondMock
 * @notice **Test-only.** Minimal {IBooleanCond} that decodes both `isFinalized`
 *  and `getOutcome` directly from their respective query bytes.
 *
 *  Encoding for both queries: a single byte where `0x00 → false` and any other
 *  value → `true`. Empty query bytes default to `true` so callers that don't
 *  care about a particular flag can leave the corresponding `argsQuery*` field
 *  empty and get the "happy path" behavior.
 *
 *  This shape lets a single deployed instance simulate every combination of
 *  (finalized, outcome) — useful for both Solidity tests and off-chain
 *  integration tests. **Do not deploy to a production network.**
 */
contract BooleanCondMock is IBooleanCond {
    function isFinalized(bytes calldata _query) external pure returns (bool) {
        if (_query.length == 0) {
            return true;
        }
        return _bytesToBool(_query);
    }

    function getOutcome(bytes calldata _query) external pure returns (bool) {
        return _bytesToBool(_query);
    }

    /// @dev Empty input → false (matches the "no outcome" notion for `getOutcome`).
    function _bytesToBool(bytes memory _b) internal pure returns (bool) {
        if (_b.length == 0) {
            return false;
        }

        uint256 v;
        assembly {
            v := mload(add(_b, 32))
        } // load all 32bytes to v
        v = v >> (8 * (32 - _b.length)); // only first _b.length is valid
        return v != 0;
    }
}
