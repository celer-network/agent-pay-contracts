// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseTest} from "./Base.t.sol";
import {Fixtures} from "./Fixtures.sol";
import {SignUtil} from "./SignUtil.sol";

/**
 * @title LedgerTestBase
 * @notice CelerLedger-specific helpers layered on top of {BaseTest}: open-channel
 *  fixture builders, channelId derivation, and pre-funded peer pool. Used by
 *  every CelerLedger test file (ETH, ERC20, Migrate).
 */
contract LedgerTestBase is BaseTest {
    uint256 internal constant DISPUTE_TIMEOUT = 20;
    uint256 internal constant POOL_DEPOSIT = 10_000_000;

    // Each test that opens a channel should bump this so consecutive openInitializers
    // hash to distinct values (since they share the same peers).
    uint256 internal openDeadlineCursor = 1_000_000;

    function setUp() public virtual override {
        super.setUp();

        // Pre-fund the peers in EthPool so deposits via the pool path work.
        vm.deal(peer0, 100 ether);
        vm.deal(peer1, 100 ether);
        vm.prank(peer0);
        ethPool.deposit{value: POOL_DEPOSIT}(peer0);
        vm.prank(peer1);
        ethPool.deposit{value: POOL_DEPOSIT}(peer1);

        // Approve the ledger to draw from the pool.
        vm.prank(peer0);
        ethPool.approve(address(celerLedger), type(uint256).max);
        vm.prank(peer1);
        ethPool.approve(address(celerLedger), type(uint256).max);
    }

    // -------------------------------------------------------------------------
    // Channel-id derivation
    // -------------------------------------------------------------------------

    /// @dev Derive the channel id that `openChannel` will produce for a given
    ///  initializer-bytes payload. Mirrors `CelerWallet.create` id derivation:
    ///  `keccak256(chainid, wallet, ledger, keccak256(initializer))`.
    function _deriveChannelId(bytes memory _initializer) internal view returns (bytes32) {
        bytes32 nonce = keccak256(_initializer);
        return keccak256(abi.encodePacked(block.chainid, address(celerWallet), address(celerLedger), nonce));
    }

    // -------------------------------------------------------------------------
    // Open-channel fixture
    // -------------------------------------------------------------------------

    /// @dev Build an `OpenChannelRequest` for an ETH channel.
    ///  `_amounts` are the per-peer initial deposits (sorted same as peer addresses).
    function _buildOpenEth(uint256[2] memory _amounts, uint256 _msgValueReceiver, uint256 _openDeadline)
        internal
        view
        returns (bytes memory request, bytes memory initializer, bytes32 channelId)
    {
        Fixtures.PaymentChannelInitializer memory init = Fixtures.PaymentChannelInitializer({
            tokenType: 1, // ETH
            tokenAddress: address(0),
            peers: [peer0, peer1],
            amounts: _amounts,
            openDeadline: _openDeadline,
            disputeTimeout: DISPUTE_TIMEOUT,
            msgValueReceiver: _msgValueReceiver,
            chainId: block.chainid,
            ledgerAddress: address(celerLedger)
        });
        initializer = Fixtures.encPaymentChannelInitializer(init);

        bytes[] memory sigs = SignUtil.coSign(peer0Pk, peer1Pk, initializer);
        request = Fixtures.encOpenChannelRequest(initializer, sigs);
        channelId = _deriveChannelId(initializer);
    }

    /// @dev Build an `OpenChannelRequest` for an ERC20 channel.
    function _buildOpenErc20(address _token, uint256[2] memory _amounts, uint256 _openDeadline)
        internal
        view
        returns (bytes memory request, bytes memory initializer, bytes32 channelId)
    {
        Fixtures.PaymentChannelInitializer memory init = Fixtures.PaymentChannelInitializer({
            tokenType: 2, // ERC20
            tokenAddress: _token,
            peers: [peer0, peer1],
            amounts: _amounts,
            openDeadline: _openDeadline,
            disputeTimeout: DISPUTE_TIMEOUT,
            msgValueReceiver: 0,
            chainId: block.chainid,
            ledgerAddress: address(celerLedger)
        });
        initializer = Fixtures.encPaymentChannelInitializer(init);

        bytes[] memory sigs = SignUtil.coSign(peer0Pk, peer1Pk, initializer);
        request = Fixtures.encOpenChannelRequest(initializer, sigs);
        channelId = _deriveChannelId(initializer);
    }

    /// @dev Open a zero-deposit ETH channel and return its channel id.
    function _openZeroEthChannel() internal returns (bytes32 channelId) {
        uint256 deadline = openDeadlineCursor++;
        (bytes memory request,, bytes32 derivedId) = _buildOpenEth([uint256(0), 0], 0, deadline);
        celerLedger.openChannel(request);
        return derivedId;
    }

    /// @dev Open a funded ETH channel via msg.value (peer 0 pays).
    function _openFundedEthChannel(uint256[2] memory _amounts) internal returns (bytes32 channelId) {
        uint256 deadline = openDeadlineCursor++;
        (bytes memory request,, bytes32 derivedId) = _buildOpenEth(_amounts, 0, deadline);
        // peer0 sends msg.value = amounts[0]; remainder pulled from peer1's EthPool balance.
        vm.prank(peer0);
        celerLedger.openChannel{value: _amounts[0]}(request);
        return derivedId;
    }

    // -------------------------------------------------------------------------
    // Cooperative withdraw fixture
    // -------------------------------------------------------------------------

    function _buildCoopWithdraw(
        bytes32 _channelId,
        uint256 _seqNum,
        address _receiver,
        uint256 _amount,
        uint256 _withdrawDeadline,
        bytes32 _recipientChannelId
    ) internal view returns (bytes memory) {
        Fixtures.CooperativeWithdrawInfo memory w = Fixtures.CooperativeWithdrawInfo({
            channelId: _channelId,
            seqNum: _seqNum,
            withdrawAccount: _receiver,
            withdrawAmount: _amount,
            withdrawDeadline: _withdrawDeadline,
            recipientChannelId: _recipientChannelId
        });
        bytes memory body = Fixtures.encCooperativeWithdrawInfo(w);
        bytes[] memory sigs = SignUtil.coSign(peer0Pk, peer1Pk, body);
        return Fixtures.encCooperativeWithdrawRequest(body, sigs);
    }

    // -------------------------------------------------------------------------
    // Cooperative settle fixture
    // -------------------------------------------------------------------------

    function _buildCoopSettle(
        bytes32 _channelId,
        uint256 _seqNum,
        uint256[2] memory _settleAmounts,
        uint256 _settleDeadline
    ) internal view returns (bytes memory) {
        Fixtures.CooperativeSettleInfo memory s = Fixtures.CooperativeSettleInfo({
            channelId: _channelId,
            seqNum: _seqNum,
            settleAccounts: [peer0, peer1],
            settleAmounts: _settleAmounts,
            settleDeadline: _settleDeadline
        });
        bytes memory body = Fixtures.encCooperativeSettleInfo(s);
        bytes[] memory sigs = SignUtil.coSign(peer0Pk, peer1Pk, body);
        return Fixtures.encCooperativeSettleRequest(body, sigs);
    }

    // -------------------------------------------------------------------------
    // Simplex state fixture (for snapshotStates / intendSettle)
    // -------------------------------------------------------------------------

    /// @dev Build a co-signed simplex state with no pending pays.
    function _buildSignedSimplex(bytes32 _channelId, address _peerFrom, uint256 _seqNum, uint256 _transferAmount)
        internal
        view
        returns (bytes memory)
    {
        Fixtures.SimplexState memory s = Fixtures.SimplexState({
            channelId: _channelId,
            peerFrom: _peerFrom,
            seqNum: _seqNum,
            transferAmount: _transferAmount,
            pendingPayIds: bytes(""),
            lastPayResolveDeadline: 0,
            totalPendingAmount: 0
        });
        bytes memory simplex = Fixtures.encSimplexPaymentChannel(s);
        bytes[] memory sigs = SignUtil.coSign(peer0Pk, peer1Pk, simplex);
        return Fixtures.encSignedSimplexState(simplex, sigs);
    }

    /// @dev Build a single-signed null simplex state (seqNum = 0). Used for the
    ///  side of a duplex channel that has no activity in `intendSettle`.
    function _buildNullSimplex(bytes32 _channelId, uint256 _signerPk) internal pure returns (bytes memory) {
        Fixtures.SimplexState memory s = Fixtures.SimplexState({
            channelId: _channelId,
            peerFrom: address(0),
            seqNum: 0,
            transferAmount: 0,
            pendingPayIds: bytes(""),
            lastPayResolveDeadline: 0,
            totalPendingAmount: 0
        });
        bytes memory simplex = Fixtures.encSimplexPaymentChannel(s);
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = SignUtil.sign(_signerPk, simplex);
        return Fixtures.encSignedSimplexState(simplex, sigs);
    }

    /// @dev Wrap one or two signed simplex states into a `SignedSimplexStateArray`.
    function _wrapStateArray(bytes memory _state0, bytes memory _state1) internal pure returns (bytes memory) {
        bytes[] memory states;
        if (_state1.length == 0) {
            states = new bytes[](1);
            states[0] = _state0;
        } else {
            states = new bytes[](2);
            states[0] = _state0;
            states[1] = _state1;
        }
        return Fixtures.encSignedSimplexStateArray(states);
    }
}
