// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title EthPool interface
 */
interface IEthPool {
    function deposit(address _receiver) external payable;

    function withdraw(uint256 _value) external;

    function approve(address _spender, uint256 _value) external returns (bool);

    function transferFrom(address _from, address payable _to, uint256 _value) external returns (bool);

    function transferToCelerWallet(address _from, address _walletAddr, bytes32 _walletId, uint256 _value) external returns (bool);

    function increaseAllowance(address _spender, uint256 _addedValue) external returns (bool);

    function decreaseAllowance(address _spender, uint256 _subtractedValue) external returns (bool);

    function balanceOf(address _owner) external view returns (uint256);

    function allowance(address _owner, address _spender) external view returns (uint256);

    event Deposit(address indexed receiver, uint256 value);
    
    // transfer from "from" account inside EthPool to real "to" address outside EthPool
    event Transfer(address indexed from, address indexed to, uint256 value);
    
    event Approval(address indexed owner, address indexed spender, uint256 value);
}
