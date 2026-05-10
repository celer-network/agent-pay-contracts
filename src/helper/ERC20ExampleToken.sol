// SPDX-License-Identifier: MIT
// Based on https://github.com/OpenZeppelin/openzeppelin-solidity/blob/master/contracts/examples/SimpleToken.sol
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title ERC20ExampleToken
 * @notice **Test-only.** Simple ERC-20 token whose entire supply is minted to the
 *  deployer. Used to fund ERC-20 channels in AgentPayLedger tests. **Do not deploy to a
 *  production network.**
 */
contract ERC20ExampleToken is ERC20 {
    uint8 public constant DECIMALS = 18;
    uint256 public constant INITIAL_SUPPLY = 1e28;

    /**
     * @notice Constructor that gives msg.sender all of existing tokens.
     */
    constructor() ERC20("ERC20ExampleToken", "EET20") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
