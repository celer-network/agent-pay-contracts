// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title CelerWallet interface
 * @notice Multi-owner, multi-token wallet that holds funds for every channel in the
 *  AgentPay network. A CelerWallet has two distinct roles: a set of *owners* (the
 *  channel peers, recipients of withdrawals) and a single *operator* (typically a
 *  CelerLedger contract version) authorized to move funds. Operatorship is the pivot
 *  point for cooperative migration to a new ledger version — see
 *  {transferOperatorship} and {voteForOperator}.
 */
interface ICelerWallet {
    /**
     * @notice Create a new wallet.
     * @dev `walletId = keccak256(chainid, walletContract, msg.sender, _nonce)`.
     *  Reverts if the derived id is already in use, if `_operator == address(0)`,
     *  or if `_owners.length` exceeds the contract's `MAX_OWNERS` cap.
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
    function transferBetweenWallets(
        bytes32 _fromWalletId,
        bytes32 _toWalletId,
        address _tokenAddress,
        address _receiver,
        uint256 _amount
    ) external;

    /**
     * @notice Operator transfers operatorship of a wallet to a new operator.
     * @dev Migration pivot point: the new operator is typically a newer CelerLedger
     *  version cooperatively chosen by the peers. Also clears any in-flight
     *  {voteForOperator} candidate + tally — the direct transfer supersedes any
     *  pending vote.
     * @param _walletId Wallet whose operatorship moves.
     * @param _newOperator New operator address.
     */
    function transferOperatorship(bytes32 _walletId, address _newOperator) external;

    /**
     * @notice Cast (or re-cast) `msg.sender`'s vote for `_candidate` to become the
     *  next operator of `_walletId`. Operatorship changes only when *every* owner
     *  has voted for the same candidate.
     * @dev `msg.sender`'s vote is recorded in the same call — the proposer does
     *  not need to call again. Voting for a candidate different from the in-flight
     *  one resets every owner's tally (consensus is per-candidate). This path
     *  bypasses the current operator and is intended for use only when the
     *  operator contract is broken or compromised.
     * @param _walletId Wallet whose operatorship is being voted on.
     * @param _candidate Candidate operator the voter is endorsing.
     */
    function voteForOperator(bytes32 _walletId, address _candidate) external;

    /**
     * @notice Emergency token recovery (callable only when the contract is paused).
     * @param _tokenAddress Token to drain (`address(0)` for native).
     * @param _receiver Recipient of drained funds.
     * @param _amount Amount to drain.
     */
    function drainToken(address _tokenAddress, address _receiver, uint256 _amount) external;

    /// @notice Owners of `_walletId`.
    function walletOwners(bytes32 _walletId) external view returns (address[] memory);

    /// @notice Current operator of `_walletId`. Distinct from this contract's
    ///  Ownable owner — the wallet operator is per-wallet (typically a CelerLedger).
    function walletOperator(bytes32 _walletId) external view returns (address);

    /// @notice Token balance of `_walletId` for `_tokenAddress` (`address(0)` for native).
    function balanceOf(bytes32 _walletId, address _tokenAddress) external view returns (uint256);

    /// @notice Operator candidate currently being voted on for `_walletId`,
    ///  or `address(0)` if no vote is in flight.
    function pendingOperator(bytes32 _walletId) external view returns (address);

    /// @notice True iff `_owner` has voted for the current `pendingOperator(_walletId)`.
    function hasVoted(bytes32 _walletId, address _owner) external view returns (bool);

    /// @notice Emitted on wallet creation.
    event WalletCreated(bytes32 indexed walletId, address[] owners, address indexed operator);

    /// @notice Emitted on every successful deposit.
    event Deposited(bytes32 indexed walletId, address indexed tokenAddress, uint256 amount);

    /// @notice Emitted on every successful withdrawal.
    event Withdrawn(bytes32 indexed walletId, address indexed tokenAddress, address indexed receiver, uint256 amount);

    /// @notice Emitted on inter-wallet transfers via {transferBetweenWallets}.
    event TransferredBetweenWallets(
        bytes32 indexed fromWalletId,
        bytes32 indexed toWalletId,
        address indexed tokenAddress,
        address receiver,
        uint256 amount
    );

    /// @notice Emitted whenever a wallet's operator changes (either path).
    event OperatorChanged(bytes32 indexed walletId, address indexed oldOperator, address indexed newOperator);

    /// @notice Emitted when an owner casts a vote via {voteForOperator}.
    event OperatorVoted(bytes32 indexed walletId, address indexed candidate, address indexed voter);

    /// @notice Emitted on emergency drains via {drainToken}.
    event TokenDrained(address indexed tokenAddress, address indexed receiver, uint256 amount);
}
