// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../interfaces/IAgentPayWallet.sol";

/**
 * @title WalletTestHelper
 * @notice **Test-only.** Thin wrapper used to create AgentPayWallet wallets from a
 *  contract (rather than an EOA) so tests can exercise non-EOA owner / operator
 *  paths and verify event emission. **Do not deploy to a production network.**
 */
contract WalletTestHelper {
    event NewWallet(bytes32 walletId);

    IAgentPayWallet wallet;

    constructor(address _wallet) {
        wallet = IAgentPayWallet(_wallet);
    }

    function create(address[] memory _owners, address _operator, uint256 _nonce) public {
        bytes32 n = keccak256(abi.encodePacked(_nonce));
        bytes32 walletId = wallet.create(_owners, _operator, n);
        emit NewWallet(walletId);
    }
}
