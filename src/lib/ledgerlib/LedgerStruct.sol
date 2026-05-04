// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interface/ICelerWallet.sol";
import "../interface/IEthPool.sol";
import "../interface/IPayRegistry.sol";
import "../data/PbEntity.sol";

/**
 * @title LedgerStruct
 * @notice Shared struct and enum definitions used across all CelerLedger libraries.
 *  No logic — types only. Field semantics map onto the protobuf messages defined in
 *  `proto/entity.proto`; field numbers in those `.proto` files are noted alongside the
 *  Solidity counterparts where relevant.
 */
library LedgerStruct {
    /**
     * @notice Lifecycle status of a channel inside a CelerLedger instance.
     * @dev `Uninitialized` is the implicit default when a channel id is not present in
     *  `Ledger.channelMap`. State transitions: see `docs/architecture-summary.md`.
     */
    enum ChannelStatus {
        Uninitialized,
        Operable,
        Settling,
        Closed,
        Migrated
    }

    /**
     * @notice Snapshot of a peer's simplex state as last accepted on-chain.
     * @dev Mirrors fields 3, 4, 6, 7 of `entity.proto::SimplexPaymentChannel`.
     *  Only the cumulative *transferOut* is tracked: the inverse direction's
     *  transferOut is recorded on the other peer's PeerState.
     */
    struct PeerState {
        uint256 seqNum;
        // Cumulative balance sent to the other peer; monotonically increasing.
        uint256 transferOut;
        bytes32 nextPayIdListHash;
        uint256 payClearDeadline;
        uint256 pendingPayOut;
    }

    /// @notice Per-peer profile: account info + deposit/withdraw history + simplex state.
    struct PeerProfile {
        address peerAddr;
        // Cumulative deposits into this channel; monotonically increasing.
        uint256 deposit;
        // Cumulative withdrawals from this channel; monotonically increasing.
        uint256 withdrawal;
        PeerState state;
    }

    /// @notice Active unilateral withdraw intent (if any) for a channel.
    struct WithdrawIntent {
        address receiver;
        uint256 amount;
        uint256 requestTime;
        bytes32 recipientChannelId;
    }

    /**
     * @notice On-chain representation of a duplex state channel between two peers.
     * @dev Funds physically reside in {ICelerWallet}; this struct holds only state
     *  and metadata. Peers may cooperatively migrate a channel to a new CelerLedger
     *  version, in which case `status = Migrated` and `migratedTo` is set on the old
     *  ledger.
     */
    struct Channel {
        // Unix timestamp (seconds) after which peers may call confirmSettle, and before
        // which peers may still call intendSettle.
        uint256 settleFinalizedTime;
        // Dispute-challenge window length in seconds.
        uint256 disputeTimeout;
        PbEntity.TokenInfo token;
        ChannelStatus status;
        // Address of the successor CelerLedger after migration, if any.
        address migratedTo;
        // Two-peer channels only.
        PeerProfile[2] peerProfiles;
        uint256 cooperativeWithdrawSeqNum;
        WithdrawIntent withdrawIntent;
    }

    /**
     * @notice Top-level ledger storage: many channels under one operation logic.
     * @dev Held in CelerLedger as a single private state variable. Each Ledger
     *  binds to one CelerWallet (asset custody), one PayRegistry (resolved-pay
     *  results), and one EthPool (ETH wrapper).
     */
    struct Ledger {
        // ChannelStatus value => number of channels currently in that status.
        mapping(uint256 => uint256) channelStatusNums;
        IEthPool ethPool;
        IPayRegistry payRegistry;
        ICelerWallet celerWallet;
        // Per-token per-channel deposit caps.
        mapping(address => uint256) balanceLimits;
        // Whether balance-limit enforcement is currently active.
        bool balanceLimitsEnabled;
        mapping(bytes32 => Channel) channelMap;
    }
}
