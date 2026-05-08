// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../interfaces/ICelerWallet.sol";

/**
 * @title WalletTestHelper
 * @notice **Test-only.** Thin wrapper used to create CelerWallet wallets from a
 *  contract (rather than an EOA) so tests can exercise non-EOA owner / operator
 *  paths and verify event emission. **Do not deploy to a production network.**
 */
contract WalletTestHelper {
    event NewWallet(bytes32 walletId);

    ICelerWallet wallet;

    constructor(address _celerWallet) {
        wallet = ICelerWallet(_celerWallet);
    }

    function create(address[] memory _owners, address _operator, uint256 _nonce) public {
        bytes32 n = keccak256(abi.encodePacked(_nonce));
        bytes32 walletId = wallet.create(_owners, _operator, n);
        emit NewWallet(walletId);
    }
}
