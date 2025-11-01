// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../data/PbEntity.sol";
import "../ledgerlib/LedgerStruct.sol";

/**
 * @title CelerLedger interface
 * @dev any changes in this interface must be synchronized to corresponding libraries
 * @dev events in this interface must be exactly same in corresponding used libraries
 */
interface ICelerLedger {
    /********** LedgerOperation related functions and events **********/
    function openChannel(bytes calldata _openChannelRequest) external payable;

    function deposit(bytes32 _channelId, address _receiver, uint256 _transferFromAmount) external payable;

    function depositInBatch(
        bytes32[] calldata _channelIds,
        address[] calldata _receivers,
        uint256[] calldata _transferFromAmounts
    ) external;

    function snapshotStates(bytes calldata _signedSimplexStateArray) external;

    function intendWithdraw(bytes32 _channelId, uint256 _amount, bytes32 _recipientChannelId) external;
    
    function confirmWithdraw(bytes32 _channelId) external;

    function vetoWithdraw(bytes32 _channelId) external;
    
    function cooperativeWithdraw(bytes calldata _cooperativeWithdrawRequest) external;
    
    function intendSettle(bytes calldata _signedSimplexStateArray) external;
    
    function clearPays(bytes32 _channelId, address _peerFrom, bytes calldata _payIdList) external;
    
    function confirmSettle(bytes32 _channelId) external;
    
    function cooperativeSettle(bytes calldata _settleRequest) external;
    
    function getChannelStatusNum(uint256 _channelStatus) external view returns(uint256);

    function getEthPool() external view returns(address);

    function getPayRegistry() external view returns(address);

    function getCelerWallet() external view returns(address);

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
    /********** End of LedgerOperation related functions and events **********/


    /********** LedgerChannel related functions and events **********/
    function getSettleFinalizedTime(bytes32 _channelId) external view returns(uint256);

    function getTokenContract(bytes32 _channelId) external view returns(address);

    function getTokenType(bytes32 _channelId) external view returns(PbEntity.TokenType);

    function getChannelStatus(bytes32 _channelId) external view returns(LedgerStruct.ChannelStatus);

    function getCooperativeWithdrawSeqNum(bytes32 _channelId) external view returns(uint256);

    function getTotalBalance(bytes32 _channelId) external view returns(uint256);

    function getBalanceMap(bytes32 _channelId) external view returns(address[2] memory, uint256[2] memory, uint256[2] memory);

    function getChannelMigrationArgs(bytes32 _channelId) external view returns(uint256, uint256, address, uint256);

    function getPeersMigrationInfo(bytes32 _channelId) external view returns(
        address[2] memory,
        uint256[2] memory,
        uint256[2] memory,
        uint256[2] memory,
        uint256[2] memory,
        uint256[2] memory
    );

    function getDisputeTimeout(bytes32 _channelId) external view returns(uint256);

    function getMigratedTo(bytes32 _channelId) external view returns(address);

    function getStateSeqNumMap(bytes32 _channelId) external view returns(address[2] memory, uint256[2] memory);

    function getTransferOutMap(bytes32 _channelId) external view returns(
        address[2] memory,
        uint256[2] memory
    );

    function getNextPayIdListHashMap(bytes32 _channelId) external view returns(
        address[2] memory,
        bytes32[2] memory
    );

    function getLastPayResolveDeadlineMap(bytes32 _channelId) external view returns(
        address[2] memory,
        uint256[2] memory
    );

    function getPendingPayOutMap(bytes32 _channelId) external view returns(
        address[2] memory,
        uint256[2] memory
    );

    function getWithdrawIntent(bytes32 _channelId) external view returns(address, uint256, uint256, bytes32);
    /********** End of LedgerChannel related functions and events **********/


    /********** LedgerBalanceLimit related functions and events **********/
    function setBalanceLimits(address[] calldata _tokenAddrs, uint256[] calldata _limits) external;

    function disableBalanceLimits() external;

    function enableBalanceLimits() external;

    function getBalanceLimit(address _tokenAddr) external view returns(uint256);

    function getBalanceLimitsEnabled() external view returns(bool);
    /********** End of LedgerBalanceLimit related functions and events **********/


    /********** LedgerMigrate related functions and events **********/
    function migrateChannelTo(bytes calldata _migrationRequest) external returns(bytes32);

    function migrateChannelFrom(address _fromLedgerAddr, bytes calldata _migrationRequest) external;

    event MigrateChannelTo(bytes32 indexed channelId, address indexed newLedgerAddr);

    event MigrateChannelFrom(bytes32 indexed channelId, address indexed oldLedgerAddr);
    /********** End of LedgerMigrate related functions and events **********/
}
