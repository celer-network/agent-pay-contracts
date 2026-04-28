// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title EthPool interface
 * @notice ERC20-shaped wrapper for native ETH. Lets the rest of the AgentPay system —
 *  in particular {ICelerLedger.openChannel} and {ICelerLedger.deposit} — pull ETH via a
 *  uniform `transferFrom` flow regardless of the underlying token type. The pool
 *  exposes ERC20-style allowance semantics so a depositor can pre-approve the ledger
 *  to draw funds.
 */
interface IEthPool {
    /**
     * @notice Deposit `msg.value` ETH for `_receiver`.
     * @param _receiver Account credited with the deposited ETH.
     */
    function deposit(address _receiver) external payable;

    /**
     * @notice Withdraw `_value` ETH from `msg.sender`'s pool balance back to its address.
     * @param _value Amount of ETH to withdraw.
     */
    function withdraw(uint256 _value) external;

    /**
     * @notice Approve `_spender` to draw up to `_value` of `msg.sender`'s ETH balance.
     * @param _spender Address authorized to spend.
     * @param _value Maximum spendable amount.
     * @return Always true (ERC20-style); reverts on invalid input.
     */
    function approve(address _spender, uint256 _value) external returns (bool);

    /**
     * @notice Transfer `_value` ETH from `_from`'s pool balance to `_to` (off the pool).
     * @dev Decrements `allowance(_from, msg.sender)`; emits both `Approval` and
     *  `Transfer`.
     * @param _from Source account inside the pool.
     * @param _to Destination address (receives raw ETH).
     * @param _value Amount of ETH to transfer.
     * @return Always true on success.
     */
    function transferFrom(address _from, address payable _to, uint256 _value) external returns (bool);

    /**
     * @notice Transfer ETH from a pool account directly into a CelerWallet, in one call.
     * @dev Decrements `allowance(_from, msg.sender)`. Used by {ICelerLedger.openChannel}
     *  and friends to fund a channel without the user having to first withdraw from
     *  the pool.
     * @param _from Source account inside the pool.
     * @param _walletAddr Target {ICelerWallet} address (must accept `depositETH`).
     * @param _walletId Target wallet id within `_walletAddr`.
     * @param _value Amount of ETH to forward.
     * @return Always true on success.
     */
    function transferToCelerWallet(address _from, address _walletAddr, bytes32 _walletId, uint256 _value)
        external
        returns (bool);

    /**
     * @notice Increase `_spender`'s allowance from `msg.sender` by `_addedValue`.
     * @param _spender Authorized spender.
     * @param _addedValue Increment.
     * @return Always true on success.
     */
    function increaseAllowance(address _spender, uint256 _addedValue) external returns (bool);

    /**
     * @notice Decrease `_spender`'s allowance from `msg.sender` by `_subtractedValue`.
     * @param _spender Authorized spender.
     * @param _subtractedValue Decrement.
     * @return Always true on success.
     */
    function decreaseAllowance(address _spender, uint256 _subtractedValue) external returns (bool);

    /// @notice Pool balance of `_owner`.
    function balanceOf(address _owner) external view returns (uint256);

    /// @notice Remaining allowance `_owner` has granted `_spender`.
    function allowance(address _owner, address _spender) external view returns (uint256);

    /// @notice Emitted when ETH is deposited into the pool.
    event Deposit(address indexed receiver, uint256 value);

    /// @notice Emitted when ETH leaves the pool (`from` is the pool balance debited; `to` receives raw ETH).
    event Transfer(address indexed from, address indexed to, uint256 value);

    /// @notice Emitted on allowance changes (matches ERC20 semantics).
    event Approval(address indexed owner, address indexed spender, uint256 value);
}
