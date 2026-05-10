// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title AgentPayErrors
 * @notice Shared custom-error vocabulary for every production contract in
 *  AgentPay. All errors live under one namespace (`AgentPayErrors.X`) so the
 *  symbol's origin is unambiguous on every call site.
 *
 *  Conventions:
 *  - Errors with parameters carry runtime values that meaningfully aid
 *    debugging — `expected vs actual` mismatches, `attempted vs limit`
 *    bounds, replay-protection mismatches.
 *  - Errors without parameters are named so the name *is* the diagnosis;
 *    the call shape itself disambiguates which check fired.
 *  - Errors used by multiple contracts (e.g. `LengthMismatch`,
 *    `ChainIdMismatch`, `InvalidCoSignatures`) are defined once and reused.
 *  - Naming style: `XMismatch` for value mismatches, `InvalidX` for
 *    structural invalidity, `XExceeded` for limit overruns. Avoid `Wrong*`
 *    and `*Failed` — they tell you the outcome but not the diagnosis.
 */
library AgentPayErrors {
    // -------------------------------------------------------------------------
    // Parameterized — args carry diagnostic value
    // -------------------------------------------------------------------------

    /// @notice Two arrays whose lengths must match did not. `a` and `b` are
    ///  the two observed lengths.
    error LengthMismatch(uint256 a, uint256 b);

    /// @notice Cross-chain replay protection — the message's bound chain id
    ///  did not match `block.chainid`.
    error ChainIdMismatch(uint256 expected, uint256 actual);

    /// @notice `msg.value` did not match the amount the call shape requires.
    ///  Hit on the native-funding path of `openChannel` and `deposit`.
    error MsgValueMismatch(uint256 expected, uint256 actual);

    /// @notice An attempted deposit / open would push the channel over the
    ///  configured per-token cap.
    error BalanceLimitExceeded(uint256 attempted, uint256 limit);

    /// @notice `confirmWithdraw`'s post-update withdraw-limit gate. The
    ///  pending intent's amount exceeds what the receiver can claim given
    ///  the current accounting.
    error WithdrawLimitExceeded(uint256 amount, uint256 limit);

    /// @notice Pay-resolution amount exceeds the `ConditionalPay`'s
    ///  declared `transferFunc.maxTransfer`.
    error MaxTransferExceeded(uint256 attempted, uint256 max);

    /// @notice Co-signed simplex / cooperative-withdraw / cooperative-settle
    ///  seqNum was not strictly greater than (or, for cooperativeWithdraw,
    ///  exactly +1 above) the on-chain seqNum.
    error SeqNumOutOfOrder(uint256 onchain, uint256 proposed);

    // -------------------------------------------------------------------------
    // Shared unparameterized — name *is* the diagnosis
    // -------------------------------------------------------------------------

    /// @notice A user-supplied address parameter was `address(0)`.
    ///  Covers operator / wallet-owner / nativeWrap-address checks.
    error ZeroAddress();

    /// @notice A time-bound deadline (open / withdraw / settle / migration /
    ///  pay-resolve) has expired. The call shape disambiguates which
    ///  deadline was checked.
    /// @dev The pay-resolution *update* window has its own
    ///  {ResolveUpdateWindowClosed} since the two failure modes lead
    ///  operators to different remediation paths.
    error DeadlinePassed();

    /// @notice Co-signed message's recovered signers did not both match the
    ///  required signing pair. Used by channel-state co-sigs (peer0 + peer1)
    ///  in `LedgerOperation` / `LedgerMigrate`, and by vouched pay results
    ///  (`pay.src` + `pay.dest`) in `PayResolver`.
    error InvalidCoSignatures();

    /// @notice Single-sig message's recovered signer did not match the
    ///  required peer.
    error InvalidSignature();

    // -------------------------------------------------------------------------
    // AgentPayLedger
    // -------------------------------------------------------------------------

    /// @notice Constructor's `_nativeWrap` argument has no deployed
    ///  bytecode. Catches EOA / unrelated-address misconfiguration at
    ///  deploy time.
    error NativeWrapNotContract();

    /// @notice Restricted `receive()` rejected a direct native send. Only
    ///  the `nativeWrap` contract's `withdraw(...)` callback may credit the
    ///  ledger with native; everyone else reverts to keep accidental dust
    ///  from getting stranded.
    error CallerNotNativeWrap();

    // -------------------------------------------------------------------------
    // AgentPayWallet
    // -------------------------------------------------------------------------

    /// @notice `msg.sender` is not the wallet's operator.
    error NotOperator();

    /// @notice The given address is not an owner of the wallet.
    error NotWalletOwner();

    /// @notice A wallet with the derived id already exists.
    error WalletIdOccupied();

    /// @notice Native transfer via `payable.call{value:}` returned false.
    error NativeTransferFailed();

    /// @notice `create` was called with more owners than `MAX_OWNERS`.
    ///  Bounds the loop costs of `_isWalletOwner` / `_clearVotes` /
    ///  `_checkAllVotes` so a malicious caller can't DoS wallet ops by
    ///  inflating the owner list.
    error TooManyOwners();

    // -------------------------------------------------------------------------
    // LedgerOperation: openChannel
    // -------------------------------------------------------------------------

    /// @notice `initDistribution.distribution.length != 2`. AgentPay only
    ///  supports two-peer channels.
    error WrongPeerCount();

    /// @notice Initializer's `ledgerAddress` did not match `address(this)`.
    ///  Same-chain wrong-ledger replay protection.
    error LedgerAddressMismatch();

    /// @notice The two peers' addresses are not strictly ascending.
    ///  Required so per-peer ordering is canonical without per-call sort.
    error PeersNotAscending();

    /// @notice ERC-20 path requires `msg.value == 0`. Distinct from
    ///  `MsgValueMismatch` (the native-funding amount mismatch).
    error MsgValueMustBeZero();

    /// @notice Initializer's `tokenType` is neither NATIVE nor ERC20.
    error InvalidTokenType();

    /// @notice ERC-20 path: token contract has no deployed bytecode.
    error TokenNotContract();

    /// @notice Token type / address pairing is inconsistent — NATIVE channel
    ///  with non-zero token address, or ERC-20 channel with `address(0)`.
    error InvalidTokenAddress();

    /// @notice Wallet creation derived `bytes32(0)` for the channel id —
    ///  the zero value is reserved as a non-channel sentinel. Defensive
    ///  check; only reachable on a hash-collision of the wallet-id derivation.
    error ZeroChannelId();

    /// @notice The derived channel id collides with an existing channel.
    ///  Defensive check that pairs with `ZeroChannelId`.
    error ChannelIdOccupied();

    // -------------------------------------------------------------------------
    // LedgerOperation: deposit / withdraw
    // -------------------------------------------------------------------------

    /// @notice Channel must be in the Operable status for this call.
    ///  Replaces the ambiguous `"Channel status error"` string.
    error ChannelNotOperable();

    /// @notice `msg.sender` is not one of the channel's peers.
    error NotPeer();

    /// @notice An unresolved unilateral withdraw intent already exists for
    ///  this channel. Veto or wait for it before opening a new one.
    error WithdrawIntentExists();

    /// @notice There is no unilateral withdraw intent to confirm or veto.
    error NoWithdrawIntent();

    /// @notice The dispute window has not yet elapsed; cannot confirm yet.
    error DisputeNotElapsed();

    /// @notice Recipient channel's token type / address does not match the
    ///  source channel's. Withdraw-into-channel must keep token consistent.
    error RecipientChannelTokenMismatch();

    // -------------------------------------------------------------------------
    // LedgerOperation: snapshot / settle
    // -------------------------------------------------------------------------

    /// @notice Multi-channel batch in `snapshotStates` / `intendSettle` was
    ///  not in ascending channel-id order.
    error NonAscendingChannelIds();

    /// @notice `intendSettle` peer-path requires the channel to be Operable
    ///  or Settling.
    error ChannelNotOperableOrSettling();

    /// @notice `intendSettle` non-peer path requires the channel to already
    ///  be Settling — a non-peer cannot start the settlement window.
    error ChannelNotSettling();

    /// @notice `intendSettle` cannot run once the dispute window has
    ///  closed; only `confirmSettle` is legal in that state.
    error IntendSettleWindowClosed();

    /// @notice Null-state `intendSettle` requires no prior settlement
    ///  attempt — but `settleFinalizedTime` is non-zero.
    error SettlementAlreadyActive();

    /// @notice `cooperativeSettle` settle accounts did not match the
    ///  channel's two peers (in canonical ascending order).
    error SettlePeersMismatch();

    /// @notice `cooperativeSettle` settle amounts do not sum to the
    ///  channel's total balance.
    error SettleBalanceSumMismatch();

    /// @notice `confirmSettle` cannot run before
    ///  `block.timestamp >= settleFinalizedTime`.
    error ConfirmSettleTooEarly();

    /// @notice A pay's resolution result is not yet final. Fires from
    ///  `PayRegistry.getPayAmounts` (the per-pay or caller-supplied
    ///  resolve deadline has not elapsed) and from `confirmSettle` (a
    ///  multi-segment pay list remains uncleared past its
    ///  `payClearDeadline`).
    error PaymentNotFinalized();

    /// @notice In `clearPays`, the head of the supplied pay-id list does
    ///  not hash to the on-chain `nextPayIdListHash`.
    error PayListHashMismatch();

    // -------------------------------------------------------------------------
    // LedgerMigrate
    // -------------------------------------------------------------------------

    /// @notice Migration request's `fromLedgerAddress` is not this ledger.
    error FromLedgerAddressMismatch();

    /// @notice Migration request's `toLedgerAddress` is not `msg.sender`
    ///  (the caller acting as the new ledger).
    error ToLedgerAddressMismatch();

    /// @notice Channel already exists on the destination ledger.
    error ChannelAlreadyMigrated();

    /// @notice Operatorship was not transferred to the new ledger by the
    ///  old ledger before `migrateChannelFrom`.
    error OperatorshipNotTransferred();

    // -------------------------------------------------------------------------
    // PayResolver
    // -------------------------------------------------------------------------

    /// @notice `pay.payResolver != address(this)`. Same-chain
    ///  wrong-resolver replay protection.
    error ResolverAddressMismatch();

    /// @notice A pay was previously resolved and the registry's stored
    ///  `resolveDeadline` has now passed — no further amount updates are
    ///  allowed (only the *first* resolution is unconditional; subsequent
    ///  updates are gated by this window). Distinct from {DeadlinePassed}
    ///  which fires when the pay's *own* signed `resolveDeadline` has
    ///  passed (the pay can never be resolved at all). Pairs with
    ///  {AmountNotGreater}, the other update-path gate.
    error ResolveUpdateWindowClosed();

    /// @notice New on-chain resolved amount must strictly exceed the
    ///  current resolved amount (monotonic resolution).
    error AmountNotGreater();

    /// @notice New on-chain resolve deadline cannot be zero.
    error ZeroDeadline();

    /// @notice Hash-lock condition's preimage hash did not match the
    ///  declared hash.
    error PreimageMismatch();

    /// @notice Dependent contract reports the condition is not yet
    ///  finalized.
    error ConditionNotFinalized();

    /// @notice Condition's declared type is outside the supported enum
    ///  range.
    error InvalidConditionType();

    // -------------------------------------------------------------------------
    // VirtContractResolver
    // -------------------------------------------------------------------------

    /// @notice The virtual address has already been resolved to a real
    ///  deployed address.
    error VirtAddressOccupied();

    /// @notice CREATE returned `address(0)` (deployment failed).
    error CreateContractFailed();

    /// @notice The virtual address has not been resolved yet.
    error VirtAddressUnresolved();

    // -------------------------------------------------------------------------
    // RouterRegistry
    // -------------------------------------------------------------------------

    /// @notice Router has already self-registered.
    error RouterAlreadyRegistered();

    /// @notice Router has not registered (or has been removed).
    error RouterNotRegistered();
}
