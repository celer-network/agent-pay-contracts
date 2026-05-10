// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LedgerTestBase} from "./utils/LedgerTestBase.t.sol";
import {AgentPayErrors} from "../src/lib/AgentPayErrors.sol";
import {LedgerStruct} from "../src/lib/ledgerlib/LedgerStruct.sol";

/**
 * @title AgentPayLedger ERC20-channel tests
 * @notice Unit tests for `AgentPayLedger`'s ERC-20-channel paths. Focuses on
 *  ERC-20-specific behavior — open with / without funds, balance-limit gates,
 *  deposit (including by a non-peer third party), `msg.value` rejection,
 *  cooperative settle, and intend + confirm settle distributing tokens.
 *  ETH-side flows are validated in `AgentPayLedger.ETH.t.sol`.
 */
contract AgentPayLedgerErc20Test is LedgerTestBase {
    function setUp() public override {
        super.setUp();

        // Fund both peers with the example ERC20 token and approve the ledger.
        erc20.transfer(peer0, 1_000_000);
        erc20.transfer(peer1, 1_000_000);

        vm.prank(peer0);
        erc20.approve(address(ledger), type(uint256).max);
        vm.prank(peer1);
        erc20.approve(address(ledger), type(uint256).max);
    }

    function test_openErc20Channel_zeroDeposit_succeeds() public {
        uint256 deadline = openDeadlineCursor++;
        (bytes memory request,, bytes32 channelId) = _buildOpenErc20(address(erc20), [uint256(0), 0], deadline);
        ledger.openChannel(request);

        assertEq(uint256(ledger.getChannelStatus(channelId)), uint256(LedgerStruct.ChannelStatus.Operable));
        assertEq(ledger.getTokenContract(channelId), address(erc20));
        assertEq(ledger.getTotalBalance(channelId), 0);
    }

    function test_openErc20Channel_withFunds_revertsBeforeBalanceLimit() public {
        uint256 deadline = openDeadlineCursor++;
        (bytes memory request,,) = _buildOpenErc20(address(erc20), [uint256(100), 200], deadline);
        vm.expectPartialRevert(AgentPayErrors.BalanceLimitExceeded.selector);
        ledger.openChannel(request);
    }

    function test_openErc20Channel_withFunds_succeedsAfterBalanceLimit() public {
        _setErc20BalanceLimit(1_000_000);
        uint256 deadline = openDeadlineCursor++;
        (bytes memory request,, bytes32 channelId) = _buildOpenErc20(address(erc20), [uint256(100), 200], deadline);
        ledger.openChannel(request);

        assertEq(ledger.getTotalBalance(channelId), 300);
        // Balances pulled from peer0 and peer1.
        assertEq(erc20.balanceOf(peer0), 1_000_000 - 100);
        assertEq(erc20.balanceOf(peer1), 1_000_000 - 200);
    }

    function test_deposit_byPeer_succeeds() public {
        ledger.disableBalanceLimits();
        bytes32 channelId = _openZeroErc20Channel();

        vm.prank(peer0);
        ledger.deposit(channelId, peer0, 25);

        assertEq(ledger.getTotalBalance(channelId), 25);
    }

    function test_deposit_byNonPeerThirdParty_succeeds() public {
        ledger.disableBalanceLimits();
        bytes32 channelId = _openZeroErc20Channel();

        // Stranger has no tokens — fund and approve.
        erc20.transfer(stranger, 1000);
        vm.prank(stranger);
        erc20.approve(address(ledger), 1000);

        vm.prank(stranger);
        ledger.deposit(channelId, peer0, 25);

        assertEq(ledger.getTotalBalance(channelId), 25);
    }

    function test_deposit_overBalanceLimit_reverts() public {
        _setErc20BalanceLimit(50);
        bytes32 channelId = _openZeroErc20Channel();

        vm.expectPartialRevert(AgentPayErrors.BalanceLimitExceeded.selector);
        vm.prank(peer0);
        ledger.deposit(channelId, peer0, 100);
    }

    function test_deposit_withMsgValueNonZero_reverts() public {
        ledger.disableBalanceLimits();
        bytes32 channelId = _openZeroErc20Channel();

        // ERC20 channel deposit must not have msg.value.
        vm.deal(peer0, 1 ether);
        vm.expectRevert(AgentPayErrors.MsgValueMustBeZero.selector);
        vm.prank(peer0);
        ledger.deposit{value: 1}(channelId, peer0, 25);
    }

    function test_cooperativeSettle_distributesErc20() public {
        ledger.disableBalanceLimits();
        bytes32 channelId = _openFundedErc20Channel([uint256(200), 0]);

        bytes memory request = _buildCoopSettle(channelId, 1, [uint256(120), 80], block.timestamp + 1000);

        uint256 peer0Before = erc20.balanceOf(peer0);
        uint256 peer1Before = erc20.balanceOf(peer1);
        ledger.cooperativeSettle(request);

        assertEq(uint256(ledger.getChannelStatus(channelId)), uint256(LedgerStruct.ChannelStatus.Closed));
        assertEq(erc20.balanceOf(peer0), peer0Before + 120);
        assertEq(erc20.balanceOf(peer1), peer1Before + 80);
    }

    function test_intendSettle_thenConfirmSettle_noPays_distributesErc20() public {
        ledger.disableBalanceLimits();
        bytes32 channelId = _openFundedErc20Channel([uint256(200), 0]);

        bytes memory s0 = _buildSignedSimplex(channelId, peer0, 1, 0);
        bytes memory s1 = _buildSignedSimplex(channelId, peer1, 1, 0);
        bytes memory array = _wrapStateArray(s0, s1);

        vm.prank(peer0);
        ledger.intendSettle(array);

        vm.warp(block.timestamp + DISPUTE_TIMEOUT + 1);
        uint256 peer0Before = erc20.balanceOf(peer0);
        ledger.confirmSettle(channelId);

        assertEq(uint256(ledger.getChannelStatus(channelId)), uint256(LedgerStruct.ChannelStatus.Closed));
        assertEq(erc20.balanceOf(peer0), peer0Before + 200);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _setErc20BalanceLimit(uint256 _limit) internal {
        address[] memory tokens = new address[](1);
        tokens[0] = address(erc20);
        uint256[] memory limits = new uint256[](1);
        limits[0] = _limit;
        ledger.setBalanceLimits(tokens, limits);
    }

    function _openZeroErc20Channel() internal returns (bytes32) {
        uint256 deadline = openDeadlineCursor++;
        (bytes memory request,, bytes32 channelId) = _buildOpenErc20(address(erc20), [uint256(0), 0], deadline);
        ledger.openChannel(request);
        return channelId;
    }

    function _openFundedErc20Channel(uint256[2] memory _amounts) internal returns (bytes32) {
        uint256 deadline = openDeadlineCursor++;
        (bytes memory request,, bytes32 channelId) = _buildOpenErc20(address(erc20), _amounts, deadline);
        ledger.openChannel(request);
        return channelId;
    }
}
