// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./lib/ledgerlib/LedgerStruct.sol";
import "./lib/ledgerlib/LedgerOperation.sol";
import "./lib/ledgerlib/LedgerMigrate.sol";
import "./lib/ledgerlib/LedgerChannel.sol";
import "./lib/AgentPayErrors.sol";
import "./interfaces/IAgentPayWallet.sol";
import "./interfaces/INativeWrap.sol";
import "./interfaces/IPayRegistry.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title AgentPayLedger
 * @notice Channel state machine and primary user entry point for AgentPay. The
 *  contract itself is a thin wrapper — the bulk of channel logic lives in the
 *  libraries under `src/lib/ledgerlib/` (LedgerOperation, LedgerChannel, LedgerMigrate)
 *  attached via `using ... for ...`. Balance-limit admin and ledger-wide config
 *  getters live directly on this contract since they are pure storage reads /
 *  writes that don't justify a separate library hop. AgentPayLedger acts as the
 *  operator of a {IAgentPayWallet}; cooperative migration to a future ledger version
 *  is supported via {migrateChannelTo} / {migrateChannelFrom}.
 * @dev See {IAgentPayLedger} for canonical NatSpec on each function.
 */
contract AgentPayLedger is IAgentPayLedger, Ownable {
    using LedgerOperation for LedgerStruct.Ledger;
    using LedgerMigrate for LedgerStruct.Ledger;
    using LedgerChannel for LedgerStruct.Channel;

    LedgerStruct.Ledger private ledger;

    /**
     * @notice Construct the ledger and wire it to its dependencies.
     * @dev Balance limits are enabled by default; configure or disable via the
     *  owner-only admin functions. `_nativeWrap` is constructor-set with no
     *  setter — effectively immutable for the lifetime of this ledger
     *  instance.
     * @param _nativeWrap Address of the chain's canonical wrapped-native
     *  (wrapped-native) contract. Used internally as a funding-flow
     *  primitive for native-token channels; never user-visible.
     * @param _payRegistry Address of the deployed {IPayRegistry}.
     * @param _wallet Address of the deployed {IAgentPayWallet} — this ledger must
     *  later become its operator (during channel opening or via wallet creation).
     */
    constructor(address _nativeWrap, address _payRegistry, address _wallet) Ownable(msg.sender) {
        require(_nativeWrap != address(0), AgentPayErrors.ZeroAddress());
        require(_nativeWrap.code.length > 0, AgentPayErrors.NativeWrapNotContract());
        ledger.nativeWrap = INativeWrap(_nativeWrap);
        ledger.payRegistry = IPayRegistry(_payRegistry);
        ledger.wallet = IAgentPayWallet(_wallet);
        // enable balance limits in default
        ledger.balanceLimitsEnabled = true;
    }

    /**
     * @notice Restricted `receive()` — accepts native only from `nativeWrap`'s
     *  `withdraw(...)` callback. Reverts on direct sends from any other address
     *  to keep accidental dust from getting stranded (the ledger has no
     *  native-drain path).
     */
    receive() external payable {
        require(msg.sender == address(ledger.nativeWrap), AgentPayErrors.CallerNotNativeWrap());
    }

    /**
     * @notice Set the per-channel balance limits of given tokens
     * @param _tokenAddrs addresses of the tokens (address(0) is for native)
     * @param _limits balance limits of the tokens
     */
    function setBalanceLimits(address[] calldata _tokenAddrs, uint256[] calldata _limits) external onlyOwner {
        require(_tokenAddrs.length == _limits.length, AgentPayErrors.LengthMismatch(_tokenAddrs.length, _limits.length));
        for (uint256 i = 0; i < _tokenAddrs.length; i++) {
            ledger.balanceLimits[_tokenAddrs[i]] = _limits[i];
        }
    }

    /**
     * @notice Disable balance limits of all tokens
     */
    function disableBalanceLimits() external onlyOwner {
        ledger.balanceLimitsEnabled = false;
    }

    /**
     * @notice Enable balance limits of all tokens
     */
    function enableBalanceLimits() external onlyOwner {
        ledger.balanceLimitsEnabled = true;
    }

    /**
     * @notice Open a state channel through auth withdraw message
     * @param _openRequest bytes of open channel request message
     */
    function openChannel(bytes calldata _openRequest) external payable {
        ledger.openChannel(_openRequest);
    }

    /**
     * @notice Deposit native or ERC20 tokens into the channel
     * @dev total deposit amount = msg.value(must be 0 for ERC20) + _transferFromAmount
     * @param _channelId ID of the channel
     * @param _receiver address of the receiver
     * @param _transferFromAmount amount of funds to be transferred from `nativeWrap` (wrapped-native) for native channels
     *   or ERC20 contract for ERC20 tokens
     */
    function deposit(bytes32 _channelId, address _receiver, uint256 _transferFromAmount) external payable {
        ledger.deposit(_channelId, _receiver, _transferFromAmount);
    }

    /**
     * @notice Batched variant of {deposit} across multiple channels in one tx.
     * @dev Not payable: native-channel entries are funded only via pre-approved
     *   wrapped-native (pulled from `nativeWrap` and unwrapped per channel);
     *   `msg.value` funding is unsupported in the batch path. ERC-20 entries
     *   pull from the corresponding token contract. Index in the three arrays
     *   must match.
     * @param _channelIds IDs of the channels
     * @param _receivers addresses of the receivers
     * @param _transferFromAmounts amounts of funds to be transferred from `nativeWrap` (wrapped-native) for native channels
     *   or ERC20 contract for ERC20 tokens
     */
    function depositInBatch(
        bytes32[] calldata _channelIds,
        address[] calldata _receivers,
        uint256[] calldata _transferFromAmounts
    ) external {
        require(
            _channelIds.length == _receivers.length,
            AgentPayErrors.LengthMismatch(_channelIds.length, _receivers.length)
        );
        require(
            _receivers.length == _transferFromAmounts.length,
            AgentPayErrors.LengthMismatch(_receivers.length, _transferFromAmounts.length)
        );
        for (uint256 i = 0; i < _channelIds.length; i++) {
            ledger.deposit(_channelIds[i], _receivers[i], _transferFromAmounts[i]);
        }
    }

    /**
     * @notice Store signed simplex states on-chain as checkpoints
     * @dev simplex states in this array are not necessarily in the same channel,
     *   which means snapshotStates natively supports multi-channel batch processing.
     *   This function only updates seqNum, transferOut, pendingPayOut of each on-chain
     *   simplex state. It can't ensure that the pending pays will be cleared during
     *   settling the channel, which requires users call intendSettle with the same state.
     * @param _signedSimplexStateArray bytes of SignedSimplexStateArray message
     */
    function snapshotStates(bytes calldata _signedSimplexStateArray) external {
        ledger.snapshotStates(_signedSimplexStateArray);
    }

    /**
     * @notice Intend to withdraw funds from channel
     * @dev only peers can call intendWithdraw
     * @param _channelId ID of the channel
     * @param _amount amount of funds to withdraw
     * @param _recipientChannelId withdraw to receiver address if 0,
     *   otherwise deposit to receiver address in the recipient channel
     */
    function intendWithdraw(bytes32 _channelId, uint256 _amount, bytes32 _recipientChannelId) external {
        ledger.intendWithdraw(_channelId, _amount, _recipientChannelId);
    }

    /**
     * @notice Confirm channel withdrawal
     * @dev anyone can confirm a withdrawal intent
     * @param _channelId ID of the channel
     */
    function confirmWithdraw(bytes32 _channelId) external {
        ledger.confirmWithdraw(_channelId);
    }

    /**
     * @notice Veto current withdrawal intent
     * @dev only peers can veto a withdrawal intent;
     *   peers can veto a withdrawal intent even after (requestTime + disputeTimeout)
     * @param _channelId ID of the channel
     */
    function vetoWithdraw(bytes32 _channelId) external {
        ledger.vetoWithdraw(_channelId);
    }

    /**
     * @notice Cooperatively withdraw specific amount of balance
     * @param _cooperativeWithdrawRequest bytes of cooperative withdraw request message
     */
    function cooperativeWithdraw(bytes calldata _cooperativeWithdrawRequest) external {
        ledger.cooperativeWithdraw(_cooperativeWithdrawRequest);
    }

    /**
     * @notice Intend to settle channel(s) with an array of signed simplex states
     * @dev simplex states in this array are not necessarily in the same channel,
     *   which means intendSettle natively supports multi-channel batch processing.
     *   A simplex state with non-zero seqNum (non-null state) must be co-signed by both peers,
     *   while a simplex state with seqNum=0 (null state) only needs to be signed by one peer.
     * @param _signedSimplexStateArray bytes of SignedSimplexStateArray message
     */
    function intendSettle(bytes calldata _signedSimplexStateArray) external {
        ledger.intendSettle(_signedSimplexStateArray);
    }

    /**
     * @notice Read payment results and add results to corresponding simplex payment channel
     * @param _channelId ID of the channel
     * @param _peerFrom address of the peer who send out funds
     * @param _payIdList bytes of a pay hash list
     */
    function clearPays(bytes32 _channelId, address _peerFrom, bytes calldata _payIdList) external {
        ledger.clearPays(_channelId, _peerFrom, _payIdList);
    }

    /**
     * @notice Confirm channel settlement
     * @dev This must be called after settleFinalizedTime
     * @param _channelId ID of the channel
     */
    function confirmSettle(bytes32 _channelId) external {
        ledger.confirmSettle(_channelId);
    }

    /**
     * @notice Cooperatively settle the channel
     * @param _settleRequest bytes of cooperative settle request message
     */
    function cooperativeSettle(bytes calldata _settleRequest) external {
        ledger.cooperativeSettle(_settleRequest);
    }

    /**
     * @notice Migrate a channel from this AgentPayLedger to a new AgentPayLedger
     * @param _migrationRequest bytes of migration request message
     * @return migrated channel id
     */
    function migrateChannelTo(bytes calldata _migrationRequest) external returns (bytes32) {
        return ledger.migrateChannelTo(_migrationRequest);
    }

    /**
     * @notice Migrate a channel from an old AgentPayLedger to this AgentPayLedger
     * @param _fromLedgerAddr the old ledger address to migrate from
     * @param _migrationRequest bytes of migration request message
     */
    function migrateChannelFrom(address _fromLedgerAddr, bytes calldata _migrationRequest) external {
        ledger.migrateChannelFrom(_fromLedgerAddr, _migrationRequest);
    }

    /**
     * @notice Get channel confirm settle open time
     * @param _channelId ID of the channel to be viewed
     * @return channel confirm settle open time
     */
    function getSettleFinalizedTime(bytes32 _channelId) public view returns (uint256) {
        LedgerStruct.Channel storage c = ledger.channelMap[_channelId];
        return c.getSettleFinalizedTime();
    }

    /**
     * @notice Get channel token contract address
     * @param _channelId ID of the channel to be viewed
     * @return channel token contract address
     */
    function getTokenContract(bytes32 _channelId) public view returns (address) {
        LedgerStruct.Channel storage c = ledger.channelMap[_channelId];
        return c.getTokenContract();
    }

    /**
     * @notice Get channel token type
     * @param _channelId ID of the channel to be viewed
     * @return channel token type
     */
    function getTokenType(bytes32 _channelId) public view returns (PbEntity.TokenType) {
        LedgerStruct.Channel storage c = ledger.channelMap[_channelId];
        return c.getTokenType();
    }

    /**
     * @notice Get channel status
     * @param _channelId ID of the channel to be viewed
     * @return channel status
     */
    function getChannelStatus(bytes32 _channelId) public view returns (LedgerStruct.ChannelStatus) {
        LedgerStruct.Channel storage c = ledger.channelMap[_channelId];
        return c.getChannelStatus();
    }

    /**
     * @notice Get cooperative withdraw seqNum
     * @param _channelId ID of the channel to be viewed
     * @return cooperative withdraw seqNum
     */
    function getCooperativeWithdrawSeqNum(bytes32 _channelId) public view returns (uint256) {
        LedgerStruct.Channel storage c = ledger.channelMap[_channelId];
        return c.getCooperativeWithdrawSeqNum();
    }

    /**
     * @notice Return one channel's total balance amount
     * @param _channelId ID of the channel to be viewed
     * @return channel's balance amount
     */
    function getTotalBalance(bytes32 _channelId) public view returns (uint256) {
        LedgerStruct.Channel storage c = ledger.channelMap[_channelId];
        return c.getTotalBalance();
    }

    /**
     * @notice Return one channel's balance info (depositMap and withdrawalMap)
     * @dev Solidity can't directly return an array of struct for now
     * @param _channelId ID of the channel to be viewed
     * @return addresses of peers in the channel
     * @return corresponding deposits of the peers (with matched index)
     * @return corresponding withdrawals of the peers (with matched index)
     */
    function getBalanceMap(bytes32 _channelId)
        public
        view
        returns (address[2] memory, uint256[2] memory, uint256[2] memory)
    {
        LedgerStruct.Channel storage c = ledger.channelMap[_channelId];
        return c.getBalanceMap();
    }

    /**
     * @notice Return channel-level migration arguments
     * @param _channelId ID of the channel to be viewed
     * @return channel dispute timeout
     * @return channel tokey type converted to uint
     * @return channel token address
     * @return sequence number of cooperative withdraw
     */
    function getChannelMigrationArgs(bytes32 _channelId) external view returns (uint256, uint256, address, uint256) {
        LedgerStruct.Channel storage c = ledger.channelMap[_channelId];
        return c.getChannelMigrationArgs();
    }

    /**
     * @notice Return migration info of the peers in the channel
     * @param _channelId ID of the channel to be viewed
     * @return peers' addresses
     * @return peers' deposits
     * @return peers' withdrawals
     * @return peers' state sequence numbers
     * @return peers' transferOut map
     * @return peers' pendingPayOut map
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
        )
    {
        LedgerStruct.Channel storage c = ledger.channelMap[_channelId];
        return c.getPeersMigrationInfo();
    }

    /**
     * @notice Return channel's dispute timeout
     * @param _channelId ID of the channel to be viewed
     * @return channel's dispute timeout
     */
    function getDisputeTimeout(bytes32 _channelId) external view returns (uint256) {
        LedgerStruct.Channel storage c = ledger.channelMap[_channelId];
        return c.getDisputeTimeout();
    }

    /**
     * @notice Return channel's migratedTo address
     * @param _channelId ID of the channel to be viewed
     * @return channel's migratedTo address
     */
    function getMigratedTo(bytes32 _channelId) external view returns (address) {
        LedgerStruct.Channel storage c = ledger.channelMap[_channelId];
        return c.getMigratedTo();
    }

    /**
     * @notice Return state seqNum map of a duplex channel
     * @param _channelId ID of the channel to be viewed
     * @return peers' addresses
     * @return two simplex state sequence numbers
     */
    function getStateSeqNumMap(bytes32 _channelId) external view returns (address[2] memory, uint256[2] memory) {
        LedgerStruct.Channel storage c = ledger.channelMap[_channelId];
        return c.getStateSeqNumMap();
    }

    /**
     * @notice Return transferOut map of a duplex channel
     * @param _channelId ID of the channel to be viewed
     * @return peers' addresses
     * @return transferOuts of two simplex channels
     */
    function getTransferOutMap(bytes32 _channelId) external view returns (address[2] memory, uint256[2] memory) {
        LedgerStruct.Channel storage c = ledger.channelMap[_channelId];
        return c.getTransferOutMap();
    }

    /**
     * @notice Return nextPayIdListHash map of a duplex channel
     * @param _channelId ID of the channel to be viewed
     * @return peers' addresses
     * @return nextPayIdListHashes of two simplex channels
     */
    function getNextPayIdListHashMap(bytes32 _channelId) external view returns (address[2] memory, bytes32[2] memory) {
        LedgerStruct.Channel storage c = ledger.channelMap[_channelId];
        return c.getNextPayIdListHashMap();
    }

    /**
     * @notice Return payClearDeadline map of a duplex channel
     * @param _channelId ID of the channel to be viewed
     * @return peers' addresses
     * @return payClearDeadlines of two simplex channels
     */
    function getPayClearDeadlineMap(bytes32 _channelId) external view returns (address[2] memory, uint256[2] memory) {
        LedgerStruct.Channel storage c = ledger.channelMap[_channelId];
        return c.getPayClearDeadlineMap();
    }

    /**
     * @notice Return pendingPayOut map of a duplex channel
     * @param _channelId ID of the channel to be viewed
     * @return peers' addresses
     * @return pendingPayOuts of two simplex channels
     */
    function getPendingPayOutMap(bytes32 _channelId) external view returns (address[2] memory, uint256[2] memory) {
        LedgerStruct.Channel storage c = ledger.channelMap[_channelId];
        return c.getPendingPayOutMap();
    }

    /**
     * @notice Return the withdraw intent info of the channel
     * @param _channelId ID of the channel to be viewed
     * @return receiver of the withdraw intent
     * @return amount of the withdraw intent
     * @return requestTime of the withdraw intent
     * @return recipientChannelId of the withdraw intent
     */
    function getWithdrawIntent(bytes32 _channelId) external view returns (address, uint256, uint256, bytes32) {
        LedgerStruct.Channel storage c = ledger.channelMap[_channelId];
        return c.getWithdrawIntent();
    }

    /**
     * @notice Return channel number of given status in this contract
     * @param _channelStatus query channel status converted to uint
     * @return channel number of the status
     */
    function getChannelStatusNum(uint256 _channelStatus) external view returns (uint256) {
        return ledger.getChannelStatusNum(_channelStatus);
    }

    /**
     * @notice Return the wrapped-native contract used by this AgentPayLedger
     * @return wrapped-native contract address
     */
    function getNativeWrap() external view returns (address) {
        return address(ledger.nativeWrap);
    }

    /**
     * @notice Return PayRegistry used by this AgentPayLedger contract
     * @return PayRegistry address
     */
    function getPayRegistry() external view returns (address) {
        return address(ledger.payRegistry);
    }

    /**
     * @notice Return AgentPayWallet used by this AgentPayLedger contract
     * @return AgentPayWallet address
     */
    function getAgentPayWallet() external view returns (address) {
        return address(ledger.wallet);
    }

    /**
     * @notice Return balance limit of given token
     * @param _tokenAddr query token address
     * @return token balance limit
     */
    function getBalanceLimit(address _tokenAddr) external view returns (uint256) {
        return ledger.balanceLimits[_tokenAddr];
    }

    /**
     * @notice Return balanceLimitsEnabled
     * @return balanceLimitsEnabled
     */
    function getBalanceLimitsEnabled() external view returns (bool) {
        return ledger.balanceLimitsEnabled;
    }
}
