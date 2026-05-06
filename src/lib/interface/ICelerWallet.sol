// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title CelerWallet interface
 * @notice Multi-owner, multi-token wallet that holds funds for every channel in the
 *  AgentPay network. A CelerWallet has two distinct roles: a set of *owners* (the
 *  channel peers, recipients of withdrawals) and a single *operator* (typically a
 *  CelerLedger contract version) authorized to move funds. Operatorship is the pivot
 *  point for cooperative migration to a new ledger version — see
 *  {transferOperatorship} and {proposeNewOperator}.
 */
interface ICelerWallet {
    /**
     * @notice Create a new wallet.
     * @dev `walletId = keccak256(chainid, walletContract, msg.sender, _nonce)`.
     *  Reverts if the derived id is already in use or if `_operator == address(0)`.
     * @param _owners Owners of the wallet (typically the two channel peers).
     * @param _operator Initial operator authorized to move funds.
     * @param _nonce Caller-supplied nonce, used in the wallet-id derivation.
     * @return Id of the created wallet.
     */
    function create(address[] calldata _owners, address _operator, bytes32 _nonce) external returns (bytes32);

    /**
     * @notice Deposit `msg.value` native (e.g. ETH) into a wallet's native balance.
     * @dev Public payable; called directly by users or by `CelerLedger` after
     *  unwrapping wrapped-native internally for the multi-party-funding path.
     *  Credits `balances[walletId][address(0)]`.
     * @param _walletId Wallet to deposit into.
     */
    function depositNative(bytes32 _walletId) external payable;

    /**
     * @notice Deposit ERC-20 tokens into a wallet (caller must have approved this contract).
     * @param _walletId Wallet to deposit into.
     * @param _tokenAddress ERC-20 token address.
     * @param _amount Amount of tokens to pull from `msg.sender`.
     */
    function depositERC20(bytes32 _walletId, address _tokenAddress, uint256 _amount) external;

    /**
     * @notice Withdraw funds from a wallet to a receiver who is also an owner.
     * @dev Caller must be the wallet's operator. Native is sent via raw `call`; if the
     *  ledger ever permits non-EOA peers, the ledger should layer a withdraw-pattern
     *  on top to avoid griefing.
     * @param _walletId Wallet to debit.
     * @param _tokenAddress Token to withdraw (`address(0)` for native).
     * @param _receiver Beneficiary; must be an owner of the wallet.
     * @param _amount Amount to withdraw.
     */
    function withdraw(bytes32 _walletId, address _tokenAddress, address _receiver, uint256 _amount) external;

    /**
     * @notice Move funds between two wallets sharing the same operator and a common owner.
     * @dev Used for off-chain liquidity rebalancing across channels. Both wallets must
     *  list `_receiver` among their owners.
     * @param _fromWalletId Source wallet id.
     * @param _toWalletId Destination wallet id.
     * @param _tokenAddress Token to move (`address(0)` for native).
     * @param _receiver Beneficiary owner present in both wallets.
     * @param _amount Amount to transfer.
     */
    function transferToWallet(
        bytes32 _fromWalletId,
        bytes32 _toWalletId,
        address _tokenAddress,
        address _receiver,
        uint256 _amount
    ) external;

    /**
     * @notice Operator transfers operatorship of a wallet to a new operator.
     * @dev Migration pivot point: the new operator is typically a newer CelerLedger
     *  version cooperatively chosen by the peers.
     * @param _walletId Wallet whose operatorship moves.
     * @param _newOperator New operator address.
     */
    function transferOperatorship(bytes32 _walletId, address _newOperator) external;

    /**
     * @notice Manual fallback: wallet owners cooperatively assign a new operator.
     * @dev Operatorship changes only when *all* owners have proposed the same address.
     *  Proposing a different address resets the vote tally. This path bypasses the
     *  current operator and is intended for use only when the operator contract is
     *  broken or compromised.
     * @param _walletId Wallet whose operatorship is being proposed for change.
     * @param _newOperator Proposed new operator.
     */
    function proposeNewOperator(bytes32 _walletId, address _newOperator) external;

    /**
     * @notice Emergency token recovery (callable only when the contract is paused).
     * @param _tokenAddress Token to drain (`address(0)` for native).
     * @param _receiver Recipient of drained funds.
     * @param _amount Amount to drain.
     */
    function drainToken(address _tokenAddress, address _receiver, uint256 _amount) external;

    /// @notice Owners of `_walletId`.
    function getWalletOwners(bytes32 _walletId) external view returns (address[] memory);

    /// @notice Operator of `_walletId`.
    function getOperator(bytes32 _walletId) external view returns (address);

    /// @notice Token balance of `_walletId` for `_tokenAddress` (`address(0)` for native).
    function getBalance(bytes32 _walletId, address _tokenAddress) external view returns (uint256);

    /// @notice Currently proposed new operator for `_walletId`, if any.
    function getProposedNewOperator(bytes32 _walletId) external view returns (address);

    /// @notice Whether `_owner` has voted for the current proposed new operator.
    function getProposalVote(bytes32 _walletId, address _owner) external view returns (bool);

    /// @notice Emitted on wallet creation.
    event CreateWallet(bytes32 indexed walletId, address[] indexed owners, address indexed operator);

    /// @notice Emitted on every successful deposit.
    event DepositToWallet(bytes32 indexed walletId, address indexed tokenAddress, uint256 amount);

    /// @notice Emitted on every successful withdrawal.
    event WithdrawFromWallet(
        bytes32 indexed walletId, address indexed tokenAddress, address indexed receiver, uint256 amount
    );

    /// @notice Emitted on inter-wallet transfers via {transferToWallet}.
    event TransferToWallet(
        bytes32 indexed fromWalletId,
        bytes32 indexed toWalletId,
        address indexed tokenAddress,
        address receiver,
        uint256 amount
    );

    /// @notice Emitted whenever a wallet's operator changes (either path).
    event ChangeOperator(bytes32 indexed walletId, address indexed oldOperator, address indexed newOperator);

    /// @notice Emitted when an owner proposes / votes on a new operator.
    event ProposeNewOperator(bytes32 indexed walletId, address indexed newOperator, address indexed proposer);

    /// @notice Emitted on emergency drains via {drainToken}.
    event DrainToken(address indexed tokenAddress, address indexed receiver, uint256 amount);
}
