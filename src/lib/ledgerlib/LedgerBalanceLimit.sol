// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./LedgerStruct.sol";

/**
 * @title Ledger Balance Limit Library
 * @notice CelerLedger library about balance limits
 */
library LedgerBalanceLimit {
    /**
     * @notice Set the per-channel balance limits of given tokens
     * @param _self storage data of CelerLedger contract
     * @param _tokenAddrs addresses of the tokens (address(0) is for ETH)
     * @param _limits balance limits of the tokens
     */
    function setBalanceLimits(
        LedgerStruct.Ledger storage _self,
        address[] calldata _tokenAddrs,
        uint256[] calldata _limits
    ) external {
        require(_tokenAddrs.length == _limits.length, "Lengths do not match");
        for (uint256 i = 0; i < _tokenAddrs.length; i++) {
            _self.balanceLimits[_tokenAddrs[i]] = _limits[i];
        }
    }

    /**
     * @notice Disable balance limits of all tokens
     * @param _self storage data of CelerLedger contract
     */
    function disableBalanceLimits(LedgerStruct.Ledger storage _self) external {
        _self.balanceLimitsEnabled = false;
    }

    /**
     * @notice Enable balance limits of all tokens
     * @param _self storage data of CelerLedger contract
     */
    function enableBalanceLimits(LedgerStruct.Ledger storage _self) external {
        _self.balanceLimitsEnabled = true;
    }

    /**
     * @notice Return balance limit of given token
     * @param _self storage data of CelerLedger contract
     * @param _tokenAddr query token address
     * @return token balance limit
     */
    function getBalanceLimit(LedgerStruct.Ledger storage _self, address _tokenAddr) external view returns (uint256) {
        return _self.balanceLimits[_tokenAddr];
    }

    /**
     * @notice Return balanceLimitsEnabled
     * @param _self storage data of CelerLedger contract
     * @return balanceLimitsEnabled
     */
    function getBalanceLimitsEnabled(LedgerStruct.Ledger storage _self) external view returns (bool) {
        return _self.balanceLimitsEnabled;
    }
}
