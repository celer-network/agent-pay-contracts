// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./lib/ledgerlib/LedgerStruct.sol";
import "./lib/ledgerlib/LedgerOperation.sol";
import "./lib/ledgerlib/LedgerBalanceLimit.sol";
import "./lib/ledgerlib/LedgerMigrate.sol";
import "./lib/ledgerlib/LedgerChannel.sol";
import "./lib/interface/ICelerWallet.sol";
import "./lib/interface/IEthPool.sol";
import "./lib/interface/IPayRegistry.sol";

contract CelerLedgerMock {
    using LedgerChannel for LedgerStruct.Channel;

    LedgerStruct.Ledger private ledger;
    bytes32 public tmpChannelId;
    bytes32[] public tmpChannelIds;

    /**
     * @notice CelerLedger constructor
     * @param _ethPool address of ETH pool
     * @param _payRegistry address of PayRegistry
     */
    constructor(address _ethPool, address _payRegistry, address _celerWallet) {
        ledger.ethPool = IEthPool(_ethPool);
        ledger.payRegistry = IPayRegistry(_payRegistry);
        ledger.celerWallet = ICelerWallet(_celerWallet);
        // enable balance limits in default
        ledger.balanceLimitsEnabled = true;
    }

    function openChannelMockSet(
        bytes32 _channelId,
        uint256 _disputeTimeout,
        address _tokenAddress,
        uint256 _tokenType,
        address[2] calldata _peerAddrs,
        uint256[2] calldata _deposits
    ) external {
        tmpChannelId = _channelId;

        LedgerStruct.Channel storage c = ledger.channelMap[_channelId];
        c.disputeTimeout = _disputeTimeout;
        _updateChannelStatus(c, LedgerStruct.ChannelStatus.Operable);
        c.token.tokenAddress = _tokenAddress;
        c.token.tokenType = PbEntity.TokenType(_tokenType);
        c.peerProfiles[0].peerAddr = _peerAddrs[0];
        c.peerProfiles[0].deposit = _deposits[0];
        c.peerProfiles[1].peerAddr = _peerAddrs[1];
        c.peerProfiles[1].deposit = _deposits[1];
    }

    /**
     * @notice Open a state channel through auth withdraw message
     * @param _openRequest bytes of open channel request message
     */
    function openChannel(bytes calldata _openRequest) external payable {
        // silence unused
        require(_openRequest.length >= 0, "");
        LedgerStruct.Channel storage c = ledger.channelMap[tmpChannelId];
        address[2] memory peerAddrs = [c.peerProfiles[0].peerAddr, c.peerProfiles[1].peerAddr];
        uint256[2] memory amounts = [c.peerProfiles[0].deposit, c.peerProfiles[1].deposit];

        emit OpenChannel(tmpChannelId, uint256(c.token.tokenType), c.token.tokenAddress, peerAddrs, amounts);
    }

    /**
     * @notice Deposit ETH or ERC20 tokens into the channel
     * @dev total deposit amount = msg.value(must be 0 for ERC20) + _transferFromAmount
     * @param _channelId ID of the channel
     * @param _receiver address of the receiver
     * @param _transferFromAmount amount of funds to be transfered from EthPool for ETH
     *   or ERC20 contract for ERC20 tokens
     */
    function deposit(bytes32 _channelId, address _receiver, uint256 _transferFromAmount) external payable {
        LedgerStruct.Channel storage c = ledger.channelMap[_channelId];
        uint256 rid = c._getPeerId(_receiver);
        uint256 amount = _transferFromAmount + msg.value;
        c.peerProfiles[rid].deposit = c.peerProfiles[rid].deposit + amount;

        (address[2] memory peerAddrs, uint256[2] memory deposits, uint256[2] memory withdrawals) = c.getBalanceMap();
        emit Deposit(_channelId, peerAddrs, deposits, withdrawals);
    }

    function snapshotStatesMockSet(
        bytes32[] calldata _channelIds,
        address[] calldata _peerFroms,
        uint256[] calldata _seqNums,
        uint256[] calldata _transferOuts,
        uint256[] calldata _pendingPayOuts
    ) external {
        for (uint256 i = 0; i < _channelIds.length; i++) {
            LedgerStruct.Channel storage c = ledger.channelMap[_channelIds[i]];
            uint256 peerFromId = c._getPeerId(_peerFroms[i]);
            LedgerStruct.PeerState storage state = c.peerProfiles[peerFromId].state;

            state.seqNum = _seqNums[i];
            state.transferOut = _transferOuts[i];
            state.pendingPayOut = _pendingPayOuts[i];
        }

        tmpChannelIds = _channelIds;
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
        // silence unused
        require(_signedSimplexStateArray.length >= 0, "");
        for (uint256 i = 0; i < tmpChannelIds.length; i++) {
            LedgerStruct.Channel storage c = ledger.channelMap[tmpChannelIds[i]];
            emit SnapshotStates(tmpChannelIds[i], c._getStateSeqNums());
        }
    }

    function intendWithdrawMockSet(bytes32 _channelId, uint256 _amount, bytes32 _recipientChannelId, address _receiver)
        external
    {
        LedgerStruct.Channel storage c = ledger.channelMap[_channelId];
        LedgerStruct.WithdrawIntent storage withdrawIntent = c.withdrawIntent;

        withdrawIntent.receiver = _receiver;
        withdrawIntent.amount = _amount;
        withdrawIntent.requestTime = block.number;
        withdrawIntent.recipientChannelId = _recipientChannelId;

        tmpChannelId = _channelId;
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
        // silence unused param
        _recipientChannelId;
        LedgerStruct.Channel storage c = ledger.channelMap[_channelId];

        emit IntendWithdraw(_channelId, c.withdrawIntent.receiver, _amount);
    }

    /**
     * @notice Confirm channel withdrawal
     * @dev anyone can confirm a withdrawal intent
     * @param _channelId ID of the channel
     */
    function confirmWithdraw(bytes32 _channelId) external {
        LedgerStruct.Channel storage c = ledger.channelMap[_channelId];

        address receiver = c.withdrawIntent.receiver;
        uint256 amount = c.withdrawIntent.amount;
        bytes32 recipientChannelId = c.withdrawIntent.recipientChannelId;
        delete c.withdrawIntent;

        c._addWithdrawal(receiver, amount);

        (, uint256[2] memory deposits, uint256[2] memory withdrawals) = c.getBalanceMap();
        emit ConfirmWithdraw(_channelId, amount, receiver, recipientChannelId, deposits, withdrawals);
    }

    /**
     * @notice Veto current withdrawal intent
     * @dev only peers can veto a withdrawal intent;
     *   peers can veto a withdrawal intent even after (requestTime + disputeTimeout)
     * @param _channelId ID of the channel
     */
    function vetoWithdraw(bytes32 _channelId) external {
        LedgerStruct.Channel storage c = ledger.channelMap[_channelId];
        require(c.status == LedgerStruct.ChannelStatus.Operable, "Channel status error");
        require(c.withdrawIntent.receiver != address(0), "No pending withdraw intent");
        require(c._isPeer(msg.sender), "msg.sender is not peer");

        delete c.withdrawIntent;

        emit VetoWithdraw(_channelId);
    }

    // only support intendSettle with one state for mock tests
    function intendSettleMockSet(
        bytes32 _channelId,
        address _peerFrom,
        uint256 _seqNum,
        uint256 _transferOut,
        bytes32 _nextPayIdListHash,
        uint256 _lastPayResolveDeadline,
        uint256 _pendingPayOut
    ) external {
        LedgerStruct.Channel storage c = ledger.channelMap[_channelId];
        uint256 peerFromId = c._getPeerId(_peerFrom);
        LedgerStruct.PeerState storage state = c.peerProfiles[peerFromId].state;

        state.seqNum = _seqNum;
        state.transferOut = _transferOut;
        state.nextPayIdListHash = _nextPayIdListHash;
        state.lastPayResolveDeadline = _lastPayResolveDeadline;
        state.pendingPayOut = _pendingPayOut;

        _updateOverallStatesByIntendState(_channelId);

        tmpChannelId = _channelId;
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
        // silence unused
        require(_signedSimplexStateArray.length >= 0, "");
        LedgerStruct.Channel storage c = ledger.channelMap[tmpChannelId];

        emit IntendSettle(tmpChannelId, c._getStateSeqNums());
    }

    function intendSettleRevert(bytes calldata _signedSimplexStateArray) external pure {
        // silence unused
        _signedSimplexStateArray;
        revert();
    }

    /**
     * @notice Confirm channel settlement
     * @dev This must be called after settleFinalizedTime
     * @param _channelId ID of the channel
     */
    function confirmSettle(bytes32 _channelId) external {
        LedgerStruct.Channel storage c = ledger.channelMap[_channelId];
        (bool validBalance, uint256[2] memory settleBalance) = c._validateSettleBalance();
        if (!validBalance) {
            _resetDuplexState(c);
            emit ConfirmSettleFail(_channelId);
            return;
        }

        _updateChannelStatus(c, LedgerStruct.ChannelStatus.Closed);

        emit ConfirmSettle(_channelId, settleBalance);
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
     * @notice Return lastPayResolveDeadline map of a duplex channel
     * @param _channelId ID of the channel to be viewed
     * @return peers' addresses
     * @return lastPayResolveDeadlines of two simplex channels
     */
    function getLastPayResolveDeadlineMap(bytes32 _channelId)
        external
        view
        returns (address[2] memory, uint256[2] memory)
    {
        LedgerStruct.Channel storage c = ledger.channelMap[_channelId];
        return c.getLastPayResolveDeadlineMap();
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
        return ledger.channelStatusNums[_channelStatus];
    }

    /**
     * @notice Return EthPool used by this CelerLedger contract
     * @return EthPool address
     */
    function getEthPool() external view returns (address) {
        return address(ledger.ethPool);
    }

    /**
     * @notice Return PayRegistry used by this CelerLedger contract
     * @return PayRegistry address
     */
    function getPayRegistry() external view returns (address) {
        return address(ledger.payRegistry);
    }

    /**
     * @notice Return CelerWallet used by this CelerLedger contract
     * @return CelerWallet address
     */
    function getCelerWallet() external view returns (address) {
        return address(ledger.celerWallet);
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

    /**
     * @notice Update status of a channel
     * @param _c the channel
     * @param _newStatus new channel status
     */
    function _updateChannelStatus(LedgerStruct.Channel storage _c, LedgerStruct.ChannelStatus _newStatus) internal {
        if (_c.status == _newStatus) {
            return;
        }

        // update counter of old status
        if (_c.status != LedgerStruct.ChannelStatus.Uninitialized) {
            ledger.channelStatusNums[uint256(_c.status)] = ledger.channelStatusNums[uint256(_c.status)] - 1;
        }

        // update counter of new status
        ledger.channelStatusNums[uint256(_newStatus)] = ledger.channelStatusNums[uint256(_newStatus)] + 1;

        _c.status = _newStatus;
    }

    function _updateOverallStatesByIntendState(bytes32 _channelId) internal {
        LedgerStruct.Channel storage c = ledger.channelMap[_channelId];
        c.settleFinalizedTime = block.number + c.disputeTimeout;
        _updateChannelStatus(c, LedgerStruct.ChannelStatus.Settling);
    }

    /**
     * @notice Reset the state of the channel
     * @param _c the channel
     */
    function _resetDuplexState(LedgerStruct.Channel storage _c) internal {
        delete _c.settleFinalizedTime;
        _updateChannelStatus(_c, LedgerStruct.ChannelStatus.Operable);
        delete _c.peerProfiles[0].state;
        delete _c.peerProfiles[1].state;
        // reset possibly remaining WithdrawIntent freezed by previous intendSettle()
        delete _c.withdrawIntent;
    }

    /**
     * events ****
     */
    event OpenChannel(
        bytes32 indexed channelId,
        uint256 tokenType,
        address indexed tokenAddress,
        address[2] peerAddrs,
        uint256[2] initialDeposits
    );

    event Deposit(bytes32 indexed channelId, address[2] peerAddrs, uint256[2] deposits, uint256[2] withdrawals);

    event SnapshotStates(bytes32 indexed channelId, uint256[2] seqNums);

    event IntendSettle(bytes32 indexed channelId, uint256[2] seqNums);

    event ClearOnePay(bytes32 indexed channelId, bytes32 indexed payId, address indexed peerFrom, uint256 amount);

    event ConfirmSettle(bytes32 indexed channelId, uint256[2] settleBalance);

    event ConfirmSettleFail(bytes32 indexed channelId);

    event IntendWithdraw(bytes32 indexed channelId, address indexed receiver, uint256 amount);

    event ConfirmWithdraw(
        bytes32 indexed channelId,
        uint256 withdrawnAmount,
        address indexed receiver,
        bytes32 indexed recipientChannelId,
        uint256[2] deposits,
        uint256[2] withdrawals
    );

    event VetoWithdraw(bytes32 indexed channelId);

    event CooperativeWithdraw(
        bytes32 indexed channelId,
        uint256 withdrawnAmount,
        address indexed receiver,
        bytes32 indexed recipientChannelId,
        uint256[2] deposits,
        uint256[2] withdrawals,
        uint256 seqNum
    );

    event CooperativeSettle(bytes32 indexed channelId, uint256[2] settleBalance);
}
