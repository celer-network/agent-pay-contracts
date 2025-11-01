// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../lib/interface/IBooleanCond.sol";

contract BooleanCondMock is IBooleanCond {
    function isFinalized(bytes calldata /* _query */) external pure returns (bool) {
        return true;
    }

    function getOutcome(bytes calldata _query) external pure returns (bool) {
        return _bytesToBool(_query);
    }

    function _bytesToBool(bytes memory _b) internal pure returns (bool) {
        if (_b.length == 0) {
            return false;
        }

        uint256 v;
        assembly { v := mload(add(_b, 32)) }  // load all 32bytes to v
        v = v >> (8 * (32 - _b.length));  // only first _b.length is valid
        return v != 0;
    }
}