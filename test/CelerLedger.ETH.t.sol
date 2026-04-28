// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LedgerTestBase} from "./utils/LedgerTestBase.t.sol";
import {LedgerStruct} from "../src/lib/ledgerlib/LedgerStruct.sol";
import {Fixtures} from "./utils/Fixtures.sol";
import {SignUtil} from "./utils/SignUtil.sol";

/**
 * @title CelerLedger ETH-channel tests
 * @notice Comprehensive unit tests for `CelerLedger`'s ETH-channel paths.
 *  Covers the channel state machine, balance-limit admin, deposit, cooperative
 *  and unilateral withdraw, snapshot states, intend / confirm / cooperative
 *  settle, `clearPays` segment chaining, the recipient-channel rebalance
 *  withdraw path, and the invalid-balance settle-recovery path.
 *
 * @dev Sections:
 *  1. Channel state machine
 *  2. Open channel
 *  3. Balance-limit admin
 *  4. Deposit
 *  5. Cooperative withdraw
 *  6. Unilateral withdraw
 *  7. Snapshot states
 *  8. Cooperative settle
 *  9. Unilateral settle / clear pays / confirm settle
 *  10. State / migration getters
 *  11. Connection getters
 *  12. Internal helpers
 */
contract CelerLedgerEthTest is LedgerTestBase {
    // =========================================================================
    // 1. Channel state machine
    // =========================================================================

    function test_uninitializedChannel_returnsStatusZero() public view {
        bytes32 unknownId = bytes32(uint256(0x123));
        assertEq(uint256(celerLedger.getChannelStatus(unknownId)), uint256(LedgerStruct.ChannelStatus.Uninitialized));
    }

    // =========================================================================
    // 2. Open channel
    // =========================================================================

    function test_openChannel_zeroDeposit_succeeds() public {
        bytes32 channelId = _openZeroEthChannel();

        assertEq(uint256(celerLedger.getChannelStatus(channelId)), uint256(LedgerStruct.ChannelStatus.Operable));
        assertEq(celerLedger.getTokenContract(channelId), address(0));
        assertEq(celerLedger.getTotalBalance(channelId), 0);
    }

    function test_openChannel_afterDeadline_reverts() public {
        // Roll forward so any small openDeadline is already past.
        vm.roll(100);
        (bytes memory request,,) = _buildOpenEth([uint256(0), 0], 0, 1);

        vm.expectRevert(bytes("Open deadline passed"));
        celerLedger.openChannel(request);
    }

    function test_openChannel_sameInitializerTwice_reverts() public {
        // Build with a fixed deadline so both attempts use the same initializer hash.
        uint256 deadline = openDeadlineCursor++;
        (bytes memory request,,) = _buildOpenEth([uint256(0), 0], 0, deadline);
        celerLedger.openChannel(request);

        vm.expectRevert(bytes("Occupied wallet id"));
        celerLedger.openChannel(request);
    }

    function test_openChannel_withFunds_revertsBeforeBalanceLimit() public {
        // Default: balance limits enabled but limit for ETH is unset (== 0).
        (bytes memory request,,) = _buildOpenEth([uint256(100), 200], 0, openDeadlineCursor++);

        vm.expectRevert(bytes("Balance exceeds limit"));
        vm.prank(peer0);
        celerLedger.openChannel{value: 100}(request);
    }

    function test_openChannel_withFunds_succeedsAfterBalanceLimit() public {
        _setEthBalanceLimit(1_000_000);

        bytes32 channelId = _openFundedEthChannel([uint256(100), 200]);

        assertEq(celerLedger.getTotalBalance(channelId), 300);
        (, uint256[2] memory deposits,) = celerLedger.getBalanceMap(channelId);
        assertEq(deposits[0], 100);
        assertEq(deposits[1], 200);
    }

    // =========================================================================
    // 3. Balance-limit admin
    // =========================================================================

    function test_setBalanceLimits_revertsForNonOwner() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(0);
        uint256[] memory limits = new uint256[](1);
        limits[0] = 1_000_000;

        vm.expectRevert();
        vm.prank(stranger);
        celerLedger.setBalanceLimits(tokens, limits);
    }

    function test_setBalanceLimits_storesLimit() public {
        _setEthBalanceLimit(1_000_000);
        assertEq(celerLedger.getBalanceLimit(address(0)), 1_000_000);
    }

    function test_disableBalanceLimits_revertsForNonOwner() public {
        vm.expectRevert();
        vm.prank(stranger);
        celerLedger.disableBalanceLimits();
    }

    function test_enableBalanceLimits_revertsForNonOwner() public {
        celerLedger.disableBalanceLimits();
        vm.expectRevert();
        vm.prank(stranger);
        celerLedger.enableBalanceLimits();
    }

    function test_disableBalanceLimits_allowsLargeDeposit() public {
        _setEthBalanceLimit(50);
        bytes32 channelId = _openZeroEthChannel();

        celerLedger.disableBalanceLimits();
        assertEq(celerLedger.getBalanceLimitsEnabled(), false);

        vm.prank(peer0);
        celerLedger.deposit{value: 1000}(channelId, peer0, 0);
        assertEq(celerLedger.getTotalBalance(channelId), 1000);
    }

    // =========================================================================
    // 4. Deposit
    // =========================================================================

    function test_deposit_viaMsgValue_succeeds() public {
        _setEthBalanceLimit(1_000_000);
        bytes32 channelId = _openZeroEthChannel();

        vm.prank(peer0);
        celerLedger.deposit{value: 50}(channelId, peer0, 0);

        assertEq(celerLedger.getTotalBalance(channelId), 50);
    }

    function test_deposit_viaEthPool_succeeds() public {
        _setEthBalanceLimit(1_000_000);
        bytes32 channelId = _openZeroEthChannel();

        vm.prank(peer0);
        celerLedger.deposit(channelId, peer0, 100);

        assertEq(celerLedger.getTotalBalance(channelId), 100);
    }

    function test_deposit_byStranger_succeeds() public {
        _setEthBalanceLimit(1_000_000);
        bytes32 channelId = _openZeroEthChannel();

        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        celerLedger.deposit{value: 25}(channelId, peer0, 0);

        assertEq(celerLedger.getTotalBalance(channelId), 25);
    }

    function test_deposit_overBalanceLimit_reverts() public {
        _setEthBalanceLimit(100);
        bytes32 channelId = _openZeroEthChannel();

        vm.expectRevert(bytes("Balance exceeds limit"));
        vm.prank(peer0);
        celerLedger.deposit{value: 200}(channelId, peer0, 0);
    }

    function test_deposit_toNonPeer_reverts() public {
        celerLedger.disableBalanceLimits();
        bytes32 channelId = _openZeroEthChannel();

        vm.deal(stranger, 1 ether);
        vm.expectRevert(bytes("Nonexist peer"));
        vm.prank(stranger);
        celerLedger.deposit{value: 25}(channelId, stranger, 0);
    }

    function test_depositInBatch_succeeds() public {
        celerLedger.disableBalanceLimits();
        bytes32 ch1 = _openZeroEthChannel();
        bytes32 ch2 = _openZeroEthChannel();

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = ch1;
        ids[1] = ch2;
        address[] memory receivers = new address[](2);
        receivers[0] = peer0;
        receivers[1] = peer0;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 30;
        amounts[1] = 70;

        vm.prank(peer0);
        celerLedger.depositInBatch(ids, receivers, amounts);

        assertEq(celerLedger.getTotalBalance(ch1), 30);
        assertEq(celerLedger.getTotalBalance(ch2), 70);
    }

    function test_depositInBatch_lengthMismatch_reverts() public {
        bytes32 channelId = _openZeroEthChannel();

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = channelId;
        ids[1] = channelId;
        address[] memory receivers = new address[](1);
        receivers[0] = peer0;
        uint256[] memory amounts = new uint256[](2);

        vm.expectRevert(bytes("Lengths do not match"));
        celerLedger.depositInBatch(ids, receivers, amounts);
    }

    // =========================================================================
    // 5. Cooperative withdraw
    // =========================================================================

    function test_cooperativeWithdraw_succeeds() public {
        celerLedger.disableBalanceLimits();
        bytes32 channelId = _openFundedEthChannel([uint256(200), 0]);

        bytes memory request = _buildCoopWithdraw(channelId, 1, peer0, 100, block.number + 1000, bytes32(0));

        uint256 peer0BalBefore = peer0.balance;
        celerLedger.cooperativeWithdraw(request);

        assertEq(peer0.balance, peer0BalBefore + 100);
        assertEq(celerLedger.getTotalBalance(channelId), 100);
        assertEq(celerLedger.getCooperativeWithdrawSeqNum(channelId), 1);
    }

    function test_cooperativeWithdraw_toRecipientChannel_movesFundsAcrossChannels() public {
        celerLedger.disableBalanceLimits();
        bytes32 srcChannel = _openFundedEthChannel([uint256(200), 0]);
        bytes32 dstChannel = _openZeroEthChannel();

        bytes memory request = _buildCoopWithdraw(srcChannel, 1, peer0, 80, block.number + 1000, dstChannel);
        celerLedger.cooperativeWithdraw(request);

        // Source channel debited 80; destination channel credited 80 to peer0.
        assertEq(celerLedger.getTotalBalance(srcChannel), 200 - 80);
        assertEq(celerLedger.getTotalBalance(dstChannel), 80);

        (, uint256[2] memory dstDeposits,) = celerLedger.getBalanceMap(dstChannel);
        assertEq(dstDeposits[0], 80);
        assertEq(dstDeposits[1], 0);
    }

    function test_cooperativeWithdraw_expiredDeadline_reverts() public {
        celerLedger.disableBalanceLimits();
        bytes32 channelId = _openFundedEthChannel([uint256(200), 0]);

        vm.roll(2);
        bytes memory request = _buildCoopWithdraw(channelId, 1, peer0, 100, 1, bytes32(0));

        vm.expectRevert(bytes("Withdraw deadline passed"));
        celerLedger.cooperativeWithdraw(request);
    }

    function test_cooperativeWithdraw_outOfOrderSeqNum_reverts() public {
        celerLedger.disableBalanceLimits();
        bytes32 channelId = _openFundedEthChannel([uint256(200), 0]);

        // First withdraw at seqNum=1 (must be exactly current+1).
        bytes memory r1 = _buildCoopWithdraw(channelId, 1, peer0, 50, block.number + 1000, bytes32(0));
        celerLedger.cooperativeWithdraw(r1);

        // Try seqNum=1 again (should be 2 next) — reverts.
        bytes memory r2 = _buildCoopWithdraw(channelId, 1, peer0, 50, block.number + 1000, bytes32(0));
        vm.expectRevert(bytes("seqNum error"));
        celerLedger.cooperativeWithdraw(r2);
    }

    function test_cooperativeWithdraw_toMismatchedTokenChannel_reverts() public {
        celerLedger.disableBalanceLimits();

        // Fund an ERC20 channel to use as a (mismatched) recipient.
        erc20.transfer(peer0, 1_000);
        erc20.transfer(peer1, 1_000);
        vm.prank(peer0);
        erc20.approve(address(celerLedger), type(uint256).max);
        vm.prank(peer1);
        erc20.approve(address(celerLedger), type(uint256).max);

        uint256 deadline = openDeadlineCursor++;
        (bytes memory openReq,, bytes32 erc20Channel) = _buildOpenErc20(address(erc20), [uint256(0), 0], deadline);
        celerLedger.openChannel(openReq);

        bytes32 ethChannel = _openFundedEthChannel([uint256(200), 0]);
        bytes memory request = _buildCoopWithdraw(ethChannel, 1, peer0, 50, block.number + 1000, erc20Channel);

        vm.expectRevert(bytes("Token mismatch of recipient channel"));
        celerLedger.cooperativeWithdraw(request);
    }

    function test_cooperativeWithdraw_badSignatures_reverts() public {
        celerLedger.disableBalanceLimits();
        bytes32 channelId = _openFundedEthChannel([uint256(200), 0]);

        Fixtures.CooperativeWithdrawInfo memory w = Fixtures.CooperativeWithdrawInfo({
            channelId: channelId,
            seqNum: 1,
            withdrawAccount: peer0,
            withdrawAmount: 50,
            withdrawDeadline: block.number + 1000,
            recipientChannelId: bytes32(0)
        });
        bytes memory body = Fixtures.encCooperativeWithdrawInfo(w);

        // Sign with a non-peer key for the first signature.
        (, uint256 strangerPk) = makeAddrAndKey("strangerPk");
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = SignUtil.sign(strangerPk, body);
        sigs[1] = SignUtil.sign(peer1Pk, body);
        bytes memory request = Fixtures.encCooperativeWithdrawRequest(body, sigs);

        vm.expectRevert(bytes("Check co-sigs failed"));
        celerLedger.cooperativeWithdraw(request);
    }

    // =========================================================================
    // 6. Unilateral withdraw
    // =========================================================================

    function test_intendWithdraw_succeeds_emitsEvent() public {
        celerLedger.disableBalanceLimits();
        bytes32 channelId = _openFundedEthChannel([uint256(200), 0]);

        vm.prank(peer0);
        celerLedger.intendWithdraw(channelId, 50, bytes32(0));

        (address receiver, uint256 amount,, bytes32 recipient) = celerLedger.getWithdrawIntent(channelId);
        assertEq(receiver, peer0);
        assertEq(amount, 50);
        assertEq(recipient, bytes32(0));
    }

    function test_intendWithdraw_byNonPeer_reverts() public {
        celerLedger.disableBalanceLimits();
        bytes32 channelId = _openFundedEthChannel([uint256(200), 0]);

        vm.expectRevert();
        vm.prank(stranger);
        celerLedger.intendWithdraw(channelId, 50, bytes32(0));
    }

    function test_intendWithdraw_pendingExists_reverts() public {
        celerLedger.disableBalanceLimits();
        bytes32 channelId = _openFundedEthChannel([uint256(200), 0]);

        vm.prank(peer0);
        celerLedger.intendWithdraw(channelId, 30, bytes32(0));

        vm.expectRevert(bytes("Pending withdraw intent exists"));
        vm.prank(peer1);
        celerLedger.intendWithdraw(channelId, 50, bytes32(0));
    }

    function test_intendWithdraw_confirmAfterTimeout_succeeds() public {
        celerLedger.disableBalanceLimits();
        bytes32 channelId = _openFundedEthChannel([uint256(200), 0]);

        vm.prank(peer0);
        celerLedger.intendWithdraw(channelId, 50, bytes32(0));

        vm.roll(block.number + DISPUTE_TIMEOUT + 1);

        uint256 peer0BalBefore = peer0.balance;
        celerLedger.confirmWithdraw(channelId);

        assertEq(peer0.balance, peer0BalBefore + 50);
        assertEq(celerLedger.getTotalBalance(channelId), 150);
    }

    function test_intendWithdraw_toRecipientChannel_succeeds() public {
        celerLedger.disableBalanceLimits();
        bytes32 srcChannel = _openFundedEthChannel([uint256(200), 0]);
        bytes32 dstChannel = _openZeroEthChannel();

        vm.prank(peer0);
        celerLedger.intendWithdraw(srcChannel, 60, dstChannel);

        vm.roll(block.number + DISPUTE_TIMEOUT + 1);
        celerLedger.confirmWithdraw(srcChannel);

        assertEq(celerLedger.getTotalBalance(srcChannel), 140);
        assertEq(celerLedger.getTotalBalance(dstChannel), 60);
    }

    function test_confirmWithdraw_beforeDisputeWindow_reverts() public {
        celerLedger.disableBalanceLimits();
        bytes32 channelId = _openFundedEthChannel([uint256(200), 0]);

        vm.prank(peer0);
        celerLedger.intendWithdraw(channelId, 50, bytes32(0));

        vm.expectRevert(bytes("Dispute not timeout"));
        celerLedger.confirmWithdraw(channelId);
    }

    function test_confirmWithdraw_doubleConfirm_reverts() public {
        celerLedger.disableBalanceLimits();
        bytes32 channelId = _openFundedEthChannel([uint256(200), 0]);

        vm.prank(peer0);
        celerLedger.intendWithdraw(channelId, 50, bytes32(0));

        vm.roll(block.number + DISPUTE_TIMEOUT + 1);
        celerLedger.confirmWithdraw(channelId);

        vm.expectRevert();
        celerLedger.confirmWithdraw(channelId);
    }

    function test_vetoWithdraw_clearsIntent() public {
        celerLedger.disableBalanceLimits();
        bytes32 channelId = _openFundedEthChannel([uint256(200), 0]);

        vm.prank(peer0);
        celerLedger.intendWithdraw(channelId, 50, bytes32(0));

        vm.prank(peer1);
        celerLedger.vetoWithdraw(channelId);

        (address receiver,,,) = celerLedger.getWithdrawIntent(channelId);
        assertEq(receiver, address(0));
    }

    // =========================================================================
    // 7. Snapshot states
    // =========================================================================

    function test_snapshotStates_recordsLatest() public {
        celerLedger.disableBalanceLimits();
        bytes32 channelId = _openFundedEthChannel([uint256(200), 0]);

        bytes memory simplex = _buildSignedSimplex(channelId, peer0, 1, 50);
        bytes memory array = _wrapStateArray(simplex, "");
        celerLedger.snapshotStates(array);

        (, uint256[2] memory seqs) = celerLedger.getStateSeqNumMap(channelId);
        assertEq(seqs[0], 1);
        (, uint256[2] memory transferOuts) = celerLedger.getTransferOutMap(channelId);
        assertEq(transferOuts[0], 50);
    }

    function test_snapshotStates_multiChannel_emitsPerChannel() public {
        celerLedger.disableBalanceLimits();
        bytes32 ch1 = _openFundedEthChannel([uint256(100), 0]);
        bytes32 ch2 = _openFundedEthChannel([uint256(150), 0]);
        bytes32 first = ch1 < ch2 ? ch1 : ch2;
        bytes32 second = ch1 < ch2 ? ch2 : ch1;

        bytes memory s0 = _buildSignedSimplex(first, peer0, 1, 10);
        bytes memory s1 = _buildSignedSimplex(second, peer0, 1, 20);
        bytes[] memory states = new bytes[](2);
        states[0] = s0;
        states[1] = s1;
        bytes memory array = Fixtures.encSignedSimplexStateArray(states);

        celerLedger.snapshotStates(array);

        (, uint256[2] memory firstSeqs) = celerLedger.getStateSeqNumMap(first);
        (, uint256[2] memory secondSeqs) = celerLedger.getStateSeqNumMap(second);
        assertEq(firstSeqs[0], 1);
        assertEq(secondSeqs[0], 1);
    }

    function test_snapshotStates_nonAscendingChannelIds_reverts() public {
        celerLedger.disableBalanceLimits();
        bytes32 ch1 = _openFundedEthChannel([uint256(100), 0]);
        bytes32 ch2 = _openFundedEthChannel([uint256(150), 0]);
        bytes32 high = ch1 > ch2 ? ch1 : ch2;
        bytes32 low = ch1 > ch2 ? ch2 : ch1;

        bytes memory sHigh = _buildSignedSimplex(high, peer0, 1, 0);
        bytes memory sLow = _buildSignedSimplex(low, peer0, 1, 0);
        bytes[] memory states = new bytes[](2);
        states[0] = sHigh;
        states[1] = sLow;
        bytes memory array = Fixtures.encSignedSimplexStateArray(states);

        vm.expectRevert(bytes("Non-ascending channelIds"));
        celerLedger.snapshotStates(array);
    }

    function test_snapshotStates_badSignature_reverts() public {
        celerLedger.disableBalanceLimits();
        bytes32 channelId = _openFundedEthChannel([uint256(100), 0]);

        Fixtures.SimplexState memory s = Fixtures.SimplexState({
            channelId: channelId,
            peerFrom: peer0,
            seqNum: 1,
            transferAmount: 10,
            pendingPayIds: bytes(""),
            lastPayResolveDeadline: 0,
            totalPendingAmount: 0
        });
        bytes memory simplex = Fixtures.encSimplexPaymentChannel(s);

        // Sign with a non-peer key for the first signature.
        (, uint256 strangerPk) = makeAddrAndKey("strangerPk");
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = SignUtil.sign(strangerPk, simplex);
        sigs[1] = SignUtil.sign(peer1Pk, simplex);
        bytes memory signed = Fixtures.encSignedSimplexState(simplex, sigs);

        bytes[] memory states = new bytes[](1);
        states[0] = signed;
        bytes memory array = Fixtures.encSignedSimplexStateArray(states);

        vm.expectRevert(bytes("Check co-sigs failed"));
        celerLedger.snapshotStates(array);
    }

    // =========================================================================
    // 8. Cooperative settle
    // =========================================================================

    function test_cooperativeSettle_closesChannel_distributesBalance() public {
        celerLedger.disableBalanceLimits();
        bytes32 channelId = _openFundedEthChannel([uint256(200), 0]);

        bytes memory request = _buildCoopSettle(channelId, 1, [uint256(120), 80], block.number + 1000);

        uint256 peer0Before = peer0.balance;
        uint256 peer1Before = peer1.balance;
        celerLedger.cooperativeSettle(request);

        assertEq(uint256(celerLedger.getChannelStatus(channelId)), uint256(LedgerStruct.ChannelStatus.Closed));
        assertEq(peer0.balance, peer0Before + 120);
        assertEq(peer1.balance, peer1Before + 80);
    }

    function test_cooperativeSettle_balanceSumMismatch_reverts() public {
        celerLedger.disableBalanceLimits();
        bytes32 channelId = _openFundedEthChannel([uint256(200), 0]);

        // Total = 200 but settleBalance = 100 + 50 = 150 → revert.
        bytes memory request = _buildCoopSettle(channelId, 1, [uint256(100), 50], block.number + 1000);

        vm.expectRevert(bytes("Balance sum mismatch"));
        celerLedger.cooperativeSettle(request);
    }

    function test_cooperativeSettle_expiredDeadline_reverts() public {
        celerLedger.disableBalanceLimits();
        bytes32 channelId = _openFundedEthChannel([uint256(200), 0]);

        // Deadline = 1, then roll past.
        bytes memory request = _buildCoopSettle(channelId, 1, [uint256(120), 80], 1);
        vm.roll(2);

        vm.expectRevert(bytes("Settle deadline passed"));
        celerLedger.cooperativeSettle(request);
    }

    function test_cooperativeSettle_lowSeqNum_reverts() public {
        celerLedger.disableBalanceLimits();
        bytes32 channelId = _openFundedEthChannel([uint256(200), 0]);

        // Bump peer0's seqNum to 1 via snapshot first.
        bytes memory simplex = _buildSignedSimplex(channelId, peer0, 1, 0);
        celerLedger.snapshotStates(_wrapStateArray(simplex, ""));

        // settleInfo seqNum must be > both peer seqNums; 1 fails (peer0 already 1).
        bytes memory request = _buildCoopSettle(channelId, 1, [uint256(120), 80], block.number + 1000);
        vm.expectRevert(bytes("seqNum error"));
        celerLedger.cooperativeSettle(request);
    }

    function test_cooperativeSettle_singleSignature_reverts() public {
        celerLedger.disableBalanceLimits();
        bytes32 channelId = _openFundedEthChannel([uint256(200), 0]);

        Fixtures.CooperativeSettleInfo memory s = Fixtures.CooperativeSettleInfo({
            channelId: channelId,
            seqNum: 1,
            settleAccounts: [peer0, peer1],
            settleAmounts: [uint256(120), 80],
            settleDeadline: block.number + 1000
        });
        bytes memory body = Fixtures.encCooperativeSettleInfo(s);
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = SignUtil.sign(peer0Pk, body);
        bytes memory request = Fixtures.encCooperativeSettleRequest(body, sigs);

        vm.expectRevert(bytes("Check co-sigs failed"));
        celerLedger.cooperativeSettle(request);
    }

    // =========================================================================
    // 9. Unilateral settle / clear pays / confirm settle
    // =========================================================================

    function test_intendSettle_thenConfirmSettle_noPays_closesChannel() public {
        celerLedger.disableBalanceLimits();
        bytes32 channelId = _openFundedEthChannel([uint256(200), 0]);

        bytes memory s0 = _buildSignedSimplex(channelId, peer0, 1, 0);
        bytes memory s1 = _buildSignedSimplex(channelId, peer1, 1, 0);
        bytes memory array = _wrapStateArray(s0, s1);

        // Caller of intendSettle must be a channel peer.
        vm.prank(peer0);
        celerLedger.intendSettle(array);
        assertEq(uint256(celerLedger.getChannelStatus(channelId)), uint256(LedgerStruct.ChannelStatus.Settling));

        vm.roll(block.number + DISPUTE_TIMEOUT + 1);
        uint256 peer0Before = peer0.balance;
        celerLedger.confirmSettle(channelId);

        assertEq(uint256(celerLedger.getChannelStatus(channelId)), uint256(LedgerStruct.ChannelStatus.Closed));
        // peer0 deposited 200; with no transferOut, peer0 keeps everything.
        assertEq(peer0.balance, peer0Before + 200);
    }

    function test_intendSettle_withTransferOut_distributesOnConfirm() public {
        celerLedger.disableBalanceLimits();
        bytes32 channelId = _openFundedEthChannel([uint256(200), 0]);

        // peer0 transferred 50 to peer1; peer1's simplex is null.
        bytes memory s0 = _buildSignedSimplex(channelId, peer0, 1, 50);
        bytes memory s1 = _buildSignedSimplex(channelId, peer1, 1, 0);
        bytes memory array = _wrapStateArray(s0, s1);

        vm.prank(peer0);
        celerLedger.intendSettle(array);

        vm.roll(block.number + DISPUTE_TIMEOUT + 1);
        uint256 peer0Before = peer0.balance;
        uint256 peer1Before = peer1.balance;
        celerLedger.confirmSettle(channelId);

        // peer0 keeps 200 - 50 = 150; peer1 receives 50.
        assertEq(peer0.balance, peer0Before + 150);
        assertEq(peer1.balance, peer1Before + 50);
    }

    function test_intendSettle_multiChannelBatch_putsAllSettling() public {
        celerLedger.disableBalanceLimits();
        bytes32 ch1 = _openFundedEthChannel([uint256(100), 0]);
        bytes32 ch2 = _openFundedEthChannel([uint256(150), 0]);

        bytes32 firstId = ch1 < ch2 ? ch1 : ch2;
        bytes32 secondId = ch1 < ch2 ? ch2 : ch1;

        bytes memory s0a = _buildSignedSimplex(firstId, peer0, 1, 0);
        bytes memory s0b = _buildSignedSimplex(firstId, peer1, 1, 0);
        bytes memory s1a = _buildSignedSimplex(secondId, peer0, 1, 0);
        bytes memory s1b = _buildSignedSimplex(secondId, peer1, 1, 0);

        bytes[] memory states = new bytes[](4);
        states[0] = s0a;
        states[1] = s0b;
        states[2] = s1a;
        states[3] = s1b;
        bytes memory array = Fixtures.encSignedSimplexStateArray(states);

        vm.prank(peer0);
        celerLedger.intendSettle(array);

        assertEq(uint256(celerLedger.getChannelStatus(firstId)), uint256(LedgerStruct.ChannelStatus.Settling));
        assertEq(uint256(celerLedger.getChannelStatus(secondId)), uint256(LedgerStruct.ChannelStatus.Settling));
    }

    function test_intendSettle_nullState_singleSignedByOnePeer() public {
        celerLedger.disableBalanceLimits();
        bytes32 channelId = _openFundedEthChannel([uint256(200), 0]);

        // Both states null (seqNum=0), each signed by exactly one peer.
        bytes memory s0 = _buildNullSimplex(channelId, peer0Pk);
        bytes memory s1 = _buildNullSimplex(channelId, peer1Pk);
        bytes memory array = _wrapStateArray(s0, s1);

        vm.prank(peer0);
        celerLedger.intendSettle(array);

        assertEq(uint256(celerLedger.getChannelStatus(channelId)), uint256(LedgerStruct.ChannelStatus.Settling));
    }

    function test_intendSettle_challengeWithHigherSeqNum_overrides() public {
        celerLedger.disableBalanceLimits();
        bytes32 channelId = _openFundedEthChannel([uint256(200), 0]);

        // First intendSettle at seqNum=1 (peer0 transferred 30).
        bytes memory s0v1 = _buildSignedSimplex(channelId, peer0, 1, 30);
        bytes memory s1null = _buildSignedSimplex(channelId, peer1, 1, 0);
        bytes memory array1 = _wrapStateArray(s0v1, s1null);
        vm.prank(peer0);
        celerLedger.intendSettle(array1);

        // Counterparty challenges with seqNum=2 showing peer0 actually transferred 60.
        bytes memory s0v2 = _buildSignedSimplex(channelId, peer0, 2, 60);
        bytes memory s1null2 = _buildSignedSimplex(channelId, peer1, 2, 0);
        bytes memory array2 = _wrapStateArray(s0v2, s1null2);
        vm.prank(peer1);
        celerLedger.intendSettle(array2);

        (, uint256[2] memory transferOuts) = celerLedger.getTransferOutMap(channelId);
        assertEq(transferOuts[0], 60);

        vm.roll(block.number + DISPUTE_TIMEOUT + 1);
        uint256 peer1Before = peer1.balance;
        celerLedger.confirmSettle(channelId);
        assertEq(peer1.balance, peer1Before + 60);
    }

    function test_intendSettle_withPendingPays_clearsAndDistributes() public {
        celerLedger.disableBalanceLimits();
        bytes32 channelId = _openFundedEthChannel([uint256(200), 0]);

        // Resolve a single hash-lock-only pay to max amount on the registry.
        bytes32 payId = _resolveSingleHashLockPay(25, "preimage", 1);

        // peer0's simplex state references this pay in pending list.
        bytes memory signedSimplexWithPays = _buildSimplexWithSinglePay(channelId, payId, 25);
        bytes memory s1 = _buildSignedSimplex(channelId, peer1, 1, 0);
        bytes memory array = _wrapStateArray(signedSimplexWithPays, s1);

        // Roll past the pay's onchain resolve deadline so getPayAmounts reads it.
        vm.roll(block.number + 10);

        vm.prank(peer0);
        celerLedger.intendSettle(array);

        (, uint256[2] memory transferOuts) = celerLedger.getTransferOutMap(channelId);
        assertEq(transferOuts[0], 25);

        vm.roll(block.number + DISPUTE_TIMEOUT + 1);
        uint256 peer1Before = peer1.balance;
        celerLedger.confirmSettle(channelId);

        assertEq(peer1.balance, peer1Before + 25);
    }

    function test_clearPays_multiSegmentList_processesSecondSegment() public {
        celerLedger.disableBalanceLimits();
        bytes32 channelId = _openFundedEthChannel([uint256(200), 0]);

        // Resolve two pays so we have two distinct pay ids.
        bytes32 payId1 = _resolveSingleHashLockPay(15, "preimage1", 1);
        bytes32 payId2 = _resolveSingleHashLockPay(20, "preimage2", 2);

        // Build a tail PayIdList containing payId2.
        bytes32[] memory tailIds = new bytes32[](1);
        tailIds[0] = payId2;
        bytes memory tailList = Fixtures.encPayIdList(tailIds, bytes32(0));
        bytes32 tailHash = keccak256(tailList);

        // Build the head PayIdList containing payId1, pointing at the tail.
        bytes32[] memory headIds = new bytes32[](1);
        headIds[0] = payId1;
        bytes memory headList = Fixtures.encPayIdList(headIds, tailHash);

        // peer0's simplex state references the head list. Total pending = 35.
        bytes memory signedSimplex = _buildSimplexWithPayList(channelId, headList, 35);
        bytes memory s1 = _buildSignedSimplex(channelId, peer1, 1, 0);
        bytes memory array = _wrapStateArray(signedSimplex, s1);

        vm.roll(block.number + 10);

        // intendSettle clears the head list.
        vm.prank(peer0);
        celerLedger.intendSettle(array);

        (, uint256[2] memory transferOuts1) = celerLedger.getTransferOutMap(channelId);
        assertEq(transferOuts1[0], 15);
        (, bytes32[2] memory nextHashes) = celerLedger.getNextPayIdListHashMap(channelId);
        assertEq(nextHashes[0], tailHash);

        // Public clearPays processes the tail.
        celerLedger.clearPays(channelId, peer0, tailList);

        (, uint256[2] memory transferOuts2) = celerLedger.getTransferOutMap(channelId);
        assertEq(transferOuts2[0], 35);
    }

    function test_clearPays_wrongStatus_reverts() public {
        celerLedger.disableBalanceLimits();
        bytes32 channelId = _openZeroEthChannel();

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1));
        bytes memory list = Fixtures.encPayIdList(ids, bytes32(0));

        // Channel is Operable, not Settling.
        vm.expectRevert(bytes("Channel status error"));
        celerLedger.clearPays(channelId, peer0, list);
    }

    function test_clearPays_listHashMismatch_reverts() public {
        celerLedger.disableBalanceLimits();
        bytes32 channelId = _openFundedEthChannel([uint256(200), 0]);

        // Put channel in Settling with no pending pays.
        bytes memory s0 = _buildSignedSimplex(channelId, peer0, 1, 0);
        bytes memory s1 = _buildSignedSimplex(channelId, peer1, 1, 0);
        bytes memory array = _wrapStateArray(s0, s1);
        vm.prank(peer0);
        celerLedger.intendSettle(array);

        // Try to clear an arbitrary list — peer's nextPayIdListHash is bytes32(0).
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1));
        bytes memory list = Fixtures.encPayIdList(ids, bytes32(0));

        vm.expectRevert(bytes("List hash mismatch"));
        celerLedger.clearPays(channelId, peer0, list);
    }

    function test_confirmSettle_beforeFinalizedTime_reverts() public {
        celerLedger.disableBalanceLimits();
        bytes32 channelId = _openFundedEthChannel([uint256(200), 0]);

        bytes memory s0 = _buildSignedSimplex(channelId, peer0, 1, 0);
        bytes memory s1 = _buildSignedSimplex(channelId, peer1, 1, 0);
        bytes memory array = _wrapStateArray(s0, s1);
        vm.prank(peer0);
        celerLedger.intendSettle(array);

        vm.expectRevert(bytes("Settle is not finalized"));
        celerLedger.confirmSettle(channelId);
    }

    function test_confirmSettle_wrongStatus_reverts() public {
        celerLedger.disableBalanceLimits();
        bytes32 channelId = _openFundedEthChannel([uint256(200), 0]);

        // Channel is Operable, not Settling.
        vm.expectRevert(bytes("Channel status error"));
        celerLedger.confirmSettle(channelId);
    }

    function test_confirmSettle_invalidBalance_resetsToOperable() public {
        celerLedger.disableBalanceLimits();
        bytes32 channelId = _openFundedEthChannel([uint256(100), 0]);

        // Construct a settle scenario where peer0's transferOut > peer0's deposit.
        // settleBalance underflows in `_validateSettleBalance` and returns invalid.
        // peer0 deposit = 100, transferOut = 200.
        bytes memory s0 = _buildSignedSimplex(channelId, peer0, 1, 200);
        bytes memory s1 = _buildSignedSimplex(channelId, peer1, 1, 0);
        bytes memory array = _wrapStateArray(s0, s1);

        vm.prank(peer0);
        celerLedger.intendSettle(array);

        vm.roll(block.number + DISPUTE_TIMEOUT + 1);
        celerLedger.confirmSettle(channelId);

        // Channel must reset to Operable, not Closed.
        assertEq(uint256(celerLedger.getChannelStatus(channelId)), uint256(LedgerStruct.ChannelStatus.Operable));
        // Per-peer state should have been wiped.
        (, uint256[2] memory transferOuts) = celerLedger.getTransferOutMap(channelId);
        assertEq(transferOuts[0], 0);
        assertEq(transferOuts[1], 0);
    }

    // =========================================================================
    // 10. State / migration getters
    // =========================================================================

    function test_getChannelStatusNum_tracksOperableCount() public {
        assertEq(celerLedger.getChannelStatusNum(uint256(LedgerStruct.ChannelStatus.Operable)), 0);

        _openZeroEthChannel();
        assertEq(celerLedger.getChannelStatusNum(uint256(LedgerStruct.ChannelStatus.Operable)), 1);

        _openZeroEthChannel();
        assertEq(celerLedger.getChannelStatusNum(uint256(LedgerStruct.ChannelStatus.Operable)), 2);
    }

    function test_getTokenContract_andTokenType_forEthChannel() public {
        bytes32 channelId = _openZeroEthChannel();
        assertEq(celerLedger.getTokenContract(channelId), address(0));
        // PbEntity.TokenType.ETH = 1
        assertEq(uint256(celerLedger.getTokenType(channelId)), 1);
    }

    function test_getCooperativeWithdrawSeqNum_returnsLatestSeq() public {
        celerLedger.disableBalanceLimits();
        bytes32 channelId = _openFundedEthChannel([uint256(200), 0]);
        assertEq(celerLedger.getCooperativeWithdrawSeqNum(channelId), 0);

        bytes memory request = _buildCoopWithdraw(channelId, 1, peer0, 50, block.number + 1000, bytes32(0));
        celerLedger.cooperativeWithdraw(request);

        assertEq(celerLedger.getCooperativeWithdrawSeqNum(channelId), 1);
    }

    function test_getMigratedTo_zeroIfNotMigrated() public {
        bytes32 channelId = _openZeroEthChannel();
        assertEq(celerLedger.getMigratedTo(channelId), address(0));
    }

    function test_getDisputeTimeout_returnsConfigured() public {
        bytes32 channelId = _openZeroEthChannel();
        assertEq(celerLedger.getDisputeTimeout(channelId), DISPUTE_TIMEOUT);
    }

    function test_getStateSeqNumMap_initiallyZero() public {
        bytes32 channelId = _openZeroEthChannel();
        (address[2] memory addrs, uint256[2] memory seqs) = celerLedger.getStateSeqNumMap(channelId);
        assertEq(addrs[0], peer0);
        assertEq(addrs[1], peer1);
        assertEq(seqs[0], 0);
        assertEq(seqs[1], 0);
    }

    function test_getTransferOutMap_initiallyZero() public {
        bytes32 channelId = _openZeroEthChannel();
        (, uint256[2] memory transferOuts) = celerLedger.getTransferOutMap(channelId);
        assertEq(transferOuts[0], 0);
        assertEq(transferOuts[1], 0);
    }

    function test_getNextPayIdListHashMap_initiallyZero() public {
        bytes32 channelId = _openZeroEthChannel();
        (, bytes32[2] memory hashes) = celerLedger.getNextPayIdListHashMap(channelId);
        assertEq(hashes[0], bytes32(0));
        assertEq(hashes[1], bytes32(0));
    }

    function test_getLastPayResolveDeadlineMap_initiallyZero() public {
        bytes32 channelId = _openZeroEthChannel();
        (, uint256[2] memory deadlines) = celerLedger.getLastPayResolveDeadlineMap(channelId);
        assertEq(deadlines[0], 0);
        assertEq(deadlines[1], 0);
    }

    function test_getPendingPayOutMap_initiallyZero() public {
        bytes32 channelId = _openZeroEthChannel();
        (, uint256[2] memory pending) = celerLedger.getPendingPayOutMap(channelId);
        assertEq(pending[0], 0);
        assertEq(pending[1], 0);
    }

    // =========================================================================
    // 11. Connection getters
    // =========================================================================

    function test_getEthPool_returnsConfiguredPool() public view {
        assertEq(celerLedger.getEthPool(), address(ethPool));
    }

    function test_getPayRegistry_returnsConfiguredRegistry() public view {
        assertEq(celerLedger.getPayRegistry(), address(payRegistry));
    }

    function test_getCelerWallet_returnsConfiguredWallet() public view {
        assertEq(celerLedger.getCelerWallet(), address(celerWallet));
    }

    function test_getBalanceLimit_returnsZeroByDefault() public view {
        assertEq(celerLedger.getBalanceLimit(address(0)), 0);
    }

    // =========================================================================
    // 12. Internal helpers
    // =========================================================================

    function _setEthBalanceLimit(uint256 _limit) internal {
        address[] memory tokens = new address[](1);
        tokens[0] = address(0);
        uint256[] memory limits = new uint256[](1);
        limits[0] = _limit;
        celerLedger.setBalanceLimits(tokens, limits);
    }

    /// @dev Resolve a single hash-lock-only ConditionalPay (peer0 → peer1) at max
    ///  amount. Returns the resulting pay id.
    function _resolveSingleHashLockPay(uint256 _maxAmount, bytes memory _preimage, uint256 _payTimestamp)
        internal
        returns (bytes32)
    {
        Fixtures.Condition[] memory conds = new Fixtures.Condition[](1);
        conds[0] = Fixtures.condHashLock(keccak256(_preimage));

        Fixtures.ConditionalPay memory pay = Fixtures.ConditionalPay({
            payTimestamp: _payTimestamp,
            src: peer0,
            dest: peer1,
            conditions: conds,
            logicType: 0,
            maxAmount: _maxAmount,
            resolveDeadline: 9_999_999,
            resolveTimeout: 5,
            payResolver: address(payResolver)
        });
        bytes memory payBytes = Fixtures.encConditionalPay(pay);

        bytes[] memory preimages = new bytes[](1);
        preimages[0] = _preimage;
        payResolver.resolvePaymentByConditions(Fixtures.encResolvePayByConditionsRequest(payBytes, preimages));

        return keccak256(abi.encodePacked(keccak256(payBytes), address(payResolver)));
    }

    /// @dev Build a co-signed simplex state for peer0 with a single-pay PayIdList.
    function _buildSimplexWithSinglePay(bytes32 _channelId, bytes32 _payId, uint256 _totalPending)
        internal
        view
        returns (bytes memory)
    {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = _payId;
        return _buildSimplexWithPayList(_channelId, Fixtures.encPayIdList(ids, bytes32(0)), _totalPending);
    }

    /// @dev Build a co-signed simplex state for peer0 with a custom PayIdList payload.
    function _buildSimplexWithPayList(bytes32 _channelId, bytes memory _payIdList, uint256 _totalPending)
        internal
        view
        returns (bytes memory)
    {
        Fixtures.SimplexState memory s = Fixtures.SimplexState({
            channelId: _channelId,
            peerFrom: peer0,
            seqNum: 1,
            transferAmount: 0,
            pendingPayIds: _payIdList,
            lastPayResolveDeadline: block.number + 1000,
            totalPendingAmount: _totalPending
        });
        bytes memory simplex = Fixtures.encSimplexPaymentChannel(s);
        bytes[] memory sigs = SignUtil.coSign(peer0Pk, peer1Pk, simplex);
        return Fixtures.encSignedSimplexState(simplex, sigs);
    }
}
