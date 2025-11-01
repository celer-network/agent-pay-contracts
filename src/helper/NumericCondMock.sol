// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../lib/interface/INumericCond.sol";

contract NumericCondMock is INumericCond {
    function isFinalized(bytes calldata /* _query */) external pure returns (bool) {
        return true;
    }

    function getOutcome(bytes calldata _query) external pure returns (uint256) {
        return _bytesToUint(_query);
    }

    function _bytesToUint(bytes memory _b) internal pure returns (uint256) {
        if (_b.length == 0) {
            return 0;
        }

        uint256 v;
        assembly { v := mload(add(_b, 32)) }  // load all 32bytes to v
        v = v >> (8 * (32 - _b.length));  // only first _b.length is valid
        
        return v;
    }
}