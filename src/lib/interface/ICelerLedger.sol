// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../data/PbEntity.sol";
import "../ledgerlib/LedgerStruct.sol";

/**
 * @title CelerLedger interface
 * @notice Channel state machine and primary user entry point for AgentPay. CelerLedger
 *  acts as the operator of a {ICelerWallet} and exposes the on-chain APIs for opening,
 *  funding, withdrawing from, settling, and migrating payment channels.
 * @dev The interface is grouped by the library that implements each section in
 *  `src/lib/ledgerlib/` (LedgerOperation, LedgerChannel, LedgerBalanceLimit,
 *  LedgerMigrate). Any change here must be mirrored in the corresponding library, and
 *  events declared here must match the library declarations bit-for-bit.
 */
interface ICelerLedger {
    // =========================================================================
    // LedgerOperation — channel lifecycle, deposit, withdraw, settle
    // =========================================================================

    /**
     * @notice Open a fully-funded channel from a co-signed initializer in one tx.
     * @dev Atomically creates a wallet in the underlying CelerWallet, derives
     *  `channelId = keccak256(chainid, walletAddr, ledgerAddr, keccak256(initializer))`,
     *  and pulls the initial deposits. Native value is allowed via `msg.value`.
     *  The initializer's `chain_id` and `ledger_address` must match this
     *  contract's execution domain. ERC-20 path assumes plain ERC-20 semantics
     *  (`balanceDelta == requested`); fee-on-transfer / rebasing / ERC-777
     *  tokens are unsupported.
     * @param _openChannelRequest ABI-encoded `PbChain.OpenChannelRequest` message.
     */
    function openChannel(bytes calldata _openChannelRequest) external payable;

    /**
     * @notice Deposit native or ERC-20 tokens into an existing channel.
     * @dev Anyone can deposit; total credited is `msg.value + _transferFromAmount`.
     *  For ERC-20 channels, `msg.value` must be 0 and the depositor must have approved
     *  this contract for `_transferFromAmount`. For native channels, `_transferFromAmount`
     *  is pulled from {INativeWrap} and unwrapped before crediting the wallet.
     *  ERC-20 path assumes plain ERC-20 semantics — fee-on-transfer / rebasing /
     *  ERC-777 tokens are unsupported.
     * @param _channelId Channel to credit.
     * @param _receiver Peer credited with the deposit.
     * @param _transferFromAmount Amount to pull via `transferFrom` (in addition to `msg.value`).
     */
    function deposit(bytes32 _channelId, address _receiver, uint256 _transferFromAmount) external payable;

    /**
     * @notice Batched variant of {deposit} across multiple channels in one tx.
     * @param _channelIds Channels to credit.
     * @param _receivers Peer per channel credited with the deposit.
     * @param _transferFromAmounts Amount per channel pulled via `transferFrom`.
     */
    function depositInBatch(
        bytes32[] calldata _channelIds,
        address[] calldata _receivers,
        uint256[] calldata _transferFromAmounts
    ) external;

    /**
     * @notice Persist co-signed simplex states on-chain as a lightweight checkpoint.
     * @dev Useful for snapshotting transferred amounts without closing the channel —
     *  e.g. before a long offline period. Updates per-peer `seqNum`/`transferOut`.
     * @param _signedSimplexStateArray ABI-encoded `PbChain.SignedSimplexStateArray`.
     */
    function snapshotStates(bytes calldata _signedSimplexStateArray) external;

    /**
     * @notice Begin a unilateral withdrawal; opens a challenge window.
     * @param _channelId Channel to withdraw from.
     * @param _amount Amount to withdraw.
     * @param _recipientChannelId Optional channel to redirect the funds into; pass
     *  `bytes32(0)` to withdraw to the caller's address instead.
     */
    function intendWithdraw(bytes32 _channelId, uint256 _amount, bytes32 _recipientChannelId) external;

    /**
     * @notice Finalize a unilateral withdrawal after its challenge window has closed.
     * @param _channelId Channel whose pending withdraw is being finalized.
     */
    function confirmWithdraw(bytes32 _channelId) external;

    /**
     * @notice Counterparty veto of an in-flight unilateral withdrawal.
     * @param _channelId Channel whose pending withdraw is being cancelled.
     */
    function vetoWithdraw(bytes32 _channelId) external;

    /**
     * @notice Co-signed single-tx withdrawal.
     * @dev Skips the challenge window. Supports both withdraw-to-account and
     *  withdraw-into-another-channel paths via the request's `recipient_channel_id`.
     * @param _cooperativeWithdrawRequest ABI-encoded `PbChain.CooperativeWithdrawRequest`.
     */
    function cooperativeWithdraw(bytes calldata _cooperativeWithdrawRequest) external;

    /**
     * @notice Begin unilateral settlement using the latest co-signed simplex states.
     * @dev Opens a challenge window during which the counterparty may submit newer
     *  states with higher `seqNum`. Pending pay outcomes are read from
     *  {IPayRegistry} when `confirmSettle` finalizes.
     * @param _signedSimplexStateArray ABI-encoded `PbChain.SignedSimplexStateArray`.
     */
    function intendSettle(bytes calldata _signedSimplexStateArray) external;

    /**
     * @notice Settle additional pending pays via a `PayIdList` after `intendSettle`.
     * @dev Used for batched multi-pay clearing when a single tx data limit cannot
     *  carry all pay ids. Each call clears one segment of the linked list.
     * @param _channelId Channel being settled.
     * @param _peerFrom Peer whose simplex pending list is being walked.
     * @param _payIdList ABI-encoded `PbEntity.PayIdList` segment.
     */
    function clearPays(bytes32 _channelId, address _peerFrom, bytes calldata _payIdList) external;

    /**
     * @notice Finalize unilateral settlement after the challenge window has closed.
     * @param _channelId Channel to close.
     */
    function confirmSettle(bytes32 _channelId) external;

    /**
     * @notice Co-signed single-tx channel close.
     * @dev Skips the challenge window. The co-signed final balance distribution
     *  short-circuits all off-chain simplex state — the signature *is* the agreement.
     * @param _settleRequest ABI-encoded `PbChain.CooperativeSettleRequest`.
     */
    function cooperativeSettle(bytes calldata _settleRequest) external;

    /// @notice Number of channels currently in the given {LedgerStruct.ChannelStatus}.
    function getChannelStatusNum(uint256 _channelStatus) external view returns (uint256);

    /// @notice Address of the configured {INativeWrap}.
    function getNativeWrap() external view returns (address);

    /// @notice Address of the configured {IPayRegistry}.
    function getPayRegistry() external view returns (address);

    /// @notice Address of the configured {ICelerWallet}.
    function getCelerWallet() external view returns (address);

    /// @notice Emitted on successful {openChannel}.
    event OpenChannel(
        bytes32 indexed channelId,
        uint256 tokenType,
        address indexed tokenAddress,
        address[2] peerAddrs,
        uint256[2] initialDeposits
    );

    /// @notice Emitted on successful {deposit} or {depositInBatch}.
    event Deposit(bytes32 indexed channelId, address[2] peerAddrs, uint256[2] deposits, uint256[2] withdrawals);

    /// @notice Emitted on successful {snapshotStates}.
    event SnapshotStates(bytes32 indexed channelId, uint256[2] seqNums);

    /// @notice Emitted when {intendSettle} opens a settlement window.
    event IntendSettle(bytes32 indexed channelId, uint256[2] seqNums);

    /// @notice Emitted on each pay cleared via {intendSettle} / {clearPays}.
    event ClearOnePay(bytes32 indexed channelId, bytes32 indexed payId, address indexed peerFrom, uint256 amount);

    /// @notice Emitted on successful {confirmSettle}.
    event ConfirmSettle(bytes32 indexed channelId, uint256[2] settleBalance);

    /// @notice Emitted when {confirmSettle} cannot finalize and the channel returns to operable.
    event ConfirmSettleFail(bytes32 indexed channelId);

    /// @notice Emitted when {intendWithdraw} opens a withdrawal challenge window.
    event IntendWithdraw(bytes32 indexed channelId, address indexed receiver, uint256 amount);

    /// @notice Emitted on successful {confirmWithdraw}.
    event ConfirmWithdraw(
        bytes32 indexed channelId,
        uint256 withdrawnAmount,
        address indexed receiver,
        bytes32 indexed recipientChannelId,
        uint256[2] deposits,
        uint256[2] withdrawals
    );

    /// @notice Emitted on successful {vetoWithdraw}.
    event VetoWithdraw(bytes32 indexed channelId);

    /// @notice Emitted on successful {cooperativeWithdraw}.
    event CooperativeWithdraw(
        bytes32 indexed channelId,
        uint256 withdrawnAmount,
        address indexed receiver,
        bytes32 indexed recipientChannelId,
        uint256[2] deposits,
        uint256[2] withdrawals,
        uint256 seqNum
    );

    /// @notice Emitted on successful {cooperativeSettle}.
    event CooperativeSettle(bytes32 indexed channelId, uint256[2] settleBalance);

    // =========================================================================
    // LedgerChannel — view functions and channel-state derivations
    // =========================================================================

    /// @notice Unix timestamp (seconds) after which a settling channel can be confirmed.
    function getSettleFinalizedTime(bytes32 _channelId) external view returns (uint256);

    /// @notice ERC-20 token contract address for this channel (`address(0)` for native).
    function getTokenContract(bytes32 _channelId) external view returns (address);

    /// @notice Token type (NATIVE / ERC20) for this channel.
    function getTokenType(bytes32 _channelId) external view returns (PbEntity.TokenType);

    /// @notice Current channel status.
    function getChannelStatus(bytes32 _channelId) external view returns (LedgerStruct.ChannelStatus);

    /// @notice Latest cooperative-withdraw sequence number used for this channel.
    function getCooperativeWithdrawSeqNum(bytes32 _channelId) external view returns (uint256);

    /// @notice Total balance currently held by this channel across both peers.
    function getTotalBalance(bytes32 _channelId) external view returns (uint256);

    /**
     * @notice Per-peer balance breakdown.
     * @return addrs Peer addresses (sorted).
     * @return deposits Cumulative deposits per peer.
     * @return withdrawals Cumulative withdrawals per peer.
     */
    function getBalanceMap(bytes32 _channelId)
        external
        view
        returns (address[2] memory addrs, uint256[2] memory deposits, uint256[2] memory withdrawals);

    /**
     * @notice Bundle of fields used by a successor ledger during {migrateChannelFrom}.
     * @dev Order: dispute timeout, token type, token address, cooperative-withdraw seq num.
     */
    function getChannelMigrationArgs(bytes32 _channelId) external view returns (uint256, uint256, address, uint256);

    /**
     * @notice Per-peer migration snapshot used by {migrateChannelFrom}.
     * @dev Tuples are ordered: peer addresses, deposits, withdrawals, simplex seq nums,
     *  transfer-outs, pending pay-outs.
     */
    function getPeersMigrationInfo(bytes32 _channelId)
        external
        view
        returns (
            address[2] memory,
            uint256[2] memory,
            uint256[2] memory,
            uint256[2] memory,
            uint256[2] memory,
            uint256[2] memory
        );

    /// @notice Configured dispute-challenge window for this channel.
    function getDisputeTimeout(bytes32 _channelId) external view returns (uint256);

    /// @notice Address of the new ledger this channel migrated to (`address(0)` if not migrated).
    function getMigratedTo(bytes32 _channelId) external view returns (address);

    /// @notice Per-peer latest sequence numbers.
    function getStateSeqNumMap(bytes32 _channelId) external view returns (address[2] memory, uint256[2] memory);

    /// @notice Per-peer cumulative transferred-out amounts.
    function getTransferOutMap(bytes32 _channelId) external view returns (address[2] memory, uint256[2] memory);

    /// @notice Per-peer next-list hashes for batched pay clearing during settlement.
    function getNextPayIdListHashMap(bytes32 _channelId) external view returns (address[2] memory, bytes32[2] memory);

    /// @notice Per-peer pay-clear deadlines (the threshold past which `confirmSettle` is unconditionally eligible).
    function getPayClearDeadlineMap(bytes32 _channelId) external view returns (address[2] memory, uint256[2] memory);

    /// @notice Per-peer pending pay totals (locked amounts).
    function getPendingPayOutMap(bytes32 _channelId) external view returns (address[2] memory, uint256[2] memory);

    /**
     * @notice Active unilateral withdrawal intent for a channel, if any.
     * @return receiver Withdrawer address.
     * @return amount Pending withdraw amount.
     * @return requestTime Unix timestamp (seconds) when {intendWithdraw} fired.
     * @return recipientChannelId Optional redirect target.
     */
    function getWithdrawIntent(bytes32 _channelId)
        external
        view
        returns (address receiver, uint256 amount, uint256 requestTime, bytes32 recipientChannelId);

    // =========================================================================
    // LedgerBalanceLimit — per-channel deposit caps
    // =========================================================================

    /**
     * @notice Set the per-channel maximum deposit for one or more tokens.
     * @dev Owner-only. Limits are enforced by {deposit} / {openChannel} when enabled.
     * @param _tokenAddrs Token addresses (`address(0)` for native).
     * @param _limits New limits, indexed identically to `_tokenAddrs`.
     */
    function setBalanceLimits(address[] calldata _tokenAddrs, uint256[] calldata _limits) external;

    /// @notice Disable balance-limit enforcement for all tokens (owner only).
    function disableBalanceLimits() external;

    /// @notice Re-enable balance-limit enforcement for all tokens (owner only).
    function enableBalanceLimits() external;

    /// @notice Configured per-channel limit for a specific token (`address(0)` for native).
    function getBalanceLimit(address _tokenAddr) external view returns (uint256);

    /// @notice Whether balance-limit enforcement is currently enabled globally.
    function getBalanceLimitsEnabled() external view returns (bool);

    // =========================================================================
    // LedgerMigrate — peer-controlled cross-version migration
    // =========================================================================

    /**
     * @notice Called on the *old* ledger by a new ledger to begin migration.
     * @dev Verifies the co-signed migration request, transfers wallet operatorship to
     *  the new ledger, and marks the channel `Migrated`.
     * @param _migrationRequest ABI-encoded `PbChain.ChannelMigrationRequest`.
     * @return The migrated channel id.
     */
    function migrateChannelTo(bytes calldata _migrationRequest) external returns (bytes32);

    /**
     * @notice Called on the *new* ledger to import a channel from a previous ledger version.
     * @dev Orchestrates the migration end-to-end: validates the co-signed request,
     *  invokes `migrateChannelTo` on the old ledger, verifies operatorship has been
     *  transferred, and imports the channel state. The channel returns to `Operable`
     *  on the new ledger.
     * @param _fromLedgerAddr Address of the previous ledger version.
     * @param _migrationRequest ABI-encoded `PbChain.ChannelMigrationRequest`.
     */
    function migrateChannelFrom(address _fromLedgerAddr, bytes calldata _migrationRequest) external;

    /// @notice Emitted on the old ledger when a channel is migrated out.
    event MigrateChannelTo(bytes32 indexed channelId, address indexed newLedgerAddr);

    /// @notice Emitted on the new ledger when a channel is migrated in.
    event MigrateChannelFrom(bytes32 indexed channelId, address indexed oldLedgerAddr);
}
