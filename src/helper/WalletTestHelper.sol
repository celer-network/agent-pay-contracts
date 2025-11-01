// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../lib/interface/ICelerWallet.sol";

contract WalletTestHelper {
    event NewWallet(bytes32 walletId);

    ICelerWallet wallet;

    constructor(address _celerWallet) {
        wallet = ICelerWallet(_celerWallet);
    }

    function create(
        address[] memory _owners,
    address _operator,
    uint256 _nonce
    )
        public
    {
        bytes32 n = keccak256(abi.encodePacked(_nonce));
        bytes32 walletId = wallet.create(_owners, _operator, n);
        emit NewWallet(walletId);
    }
}