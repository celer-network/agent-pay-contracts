// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AgentPayErrors} from "../src/lib/AgentPayErrors.sol";
import {CelerWallet} from "../src/CelerWallet.sol";
import {WalletTestHelper} from "../src/helper/WalletTestHelper.sol";
import {ERC20ExampleToken} from "../src/helper/ERC20ExampleToken.sol";

/**
 * @title CelerWallet tests
 * @notice Unit tests for the multi-owner / multi-token wallet that holds funds
 *  for every channel in the AgentPay network. Covers wallet creation, ETH /
 *  ERC-20 deposits and withdrawals, inter-wallet transfer, operator transfer
 *  (direct + multi-owner proposal), pause / drain controls, and getter behavior.
 *
 * @dev Pause control runs through `Ownable` — the contract owner is the pauser.
 */
contract CelerWalletTest is Test {
    // =========================================================================
    // Setup
    // =========================================================================

    CelerWallet internal wallet;
    WalletTestHelper internal walletHelper;
    ERC20ExampleToken internal token;

    address internal owner; // contract owner (deployer); pauses the wallet
    address internal owner0 = makeAddr("owner0"); // wallet owner #1
    address internal owner1 = makeAddr("owner1"); // wallet owner #2
    address internal operator = makeAddr("operator");
    address internal newOperator = makeAddr("newOperator");
    address internal stranger = makeAddr("stranger");

    address[] internal walletOwners;

    bytes32 internal walletId;
    bytes32 internal walletId2;

    event Paused(address account);
    event OperatorChanged(bytes32 indexed walletId, address indexed oldOperator, address indexed newOperator);
    event OperatorVoted(bytes32 indexed walletId, address indexed newOperator, address indexed proposer);
    event Deposited(bytes32 indexed walletId, address indexed tokenAddress, uint256 amount);
    event Withdrawn(bytes32 indexed walletId, address indexed tokenAddress, address indexed receiver, uint256 amount);
    event TransferredBetweenWallets(
        bytes32 indexed fromWalletId,
        bytes32 indexed toWalletId,
        address indexed tokenAddress,
        address receiver,
        uint256 amount
    );
    event TokenDrained(address indexed tokenAddress, address indexed receiver, uint256 amount);

    function setUp() public {
        owner = address(this);
        token = new ERC20ExampleToken();
        wallet = new CelerWallet();
        walletHelper = new WalletTestHelper(address(wallet));

        walletOwners.push(owner0);
        walletOwners.push(owner1);

        // Create two wallets sharing the same owner pair, and seed the first with
        // ETH + ERC-20 deposits so that withdraw / transfer / drain cases have
        // funds to operate on.
        walletHelper.create(walletOwners, operator, 0);
        walletId = _walletIdViaHelper(0);

        vm.deal(operator, 10 ether);
        vm.prank(operator);
        wallet.depositNative{value: 100}(walletId);

        token.transfer(owner0, 100_000);
        vm.prank(owner0);
        token.approve(address(wallet), 100_000);
        vm.prank(owner0);
        wallet.depositERC20(walletId, address(token), 200);

        walletHelper.create(walletOwners, operator, 1);
        walletId2 = _walletIdViaHelper(1);
    }

    /// @dev Replicates `WalletTestHelper.create` + `CelerWallet.create` id derivation:
    ///  helper hashes the user nonce into `bytes32 n`, then the wallet derives
    ///  `id = keccak256(chainid, walletAddr, helperAddr, n)`.
    function _walletIdViaHelper(uint256 _nonce) internal view returns (bytes32) {
        bytes32 n = keccak256(abi.encodePacked(_nonce));
        return keccak256(abi.encodePacked(block.chainid, address(wallet), address(walletHelper), n));
    }

    // =========================================================================
    // Initial state & wallet creation
    // =========================================================================

    function test_initialState_ownerIsDeployer_unpaused() public view {
        assertEq(wallet.owner(), owner);
        assertEq(wallet.paused(), false);
    }

    function test_walletNum_incrementsOnEachCreate() public view {
        assertEq(wallet.walletCount(), 2);
    }

    function test_create_revertsForZeroOperator() public {
        address[] memory owners = new address[](2);
        owners[0] = owner0;
        owners[1] = owner1;
        vm.expectRevert(AgentPayErrors.ZeroAddress.selector);
        wallet.create(owners, address(0), bytes32(uint256(99)));
    }

    function test_create_revertsForDuplicateId() public {
        address[] memory owners = new address[](2);
        owners[0] = owner0;
        owners[1] = owner1;
        wallet.create(owners, operator, bytes32(uint256(42)));
        vm.expectRevert(AgentPayErrors.WalletIdOccupied.selector);
        wallet.create(owners, operator, bytes32(uint256(42)));
    }

    function test_create_revertsForTooManyOwners() public {
        // Bound at MAX_OWNERS = 10. Pass 11 to exercise the gate.
        address[] memory owners = new address[](wallet.MAX_OWNERS() + 1);
        for (uint256 i = 0; i < owners.length; i++) {
            owners[i] = address(uint160(0x1000 + i));
        }
        vm.expectRevert(AgentPayErrors.TooManyOwners.selector);
        wallet.create(owners, operator, bytes32(uint256(7)));
    }

    function test_getWalletOwners_returnsBothOwners() public view {
        address[] memory owners = wallet.walletOwners(walletId);
        assertEq(owners.length, 2);
        assertEq(owners[0], owner0);
        assertEq(owners[1], owner1);
    }

    // =========================================================================
    // Deposits
    // =========================================================================

    function test_depositNative_emitsEvent_creditsBalance() public {
        vm.deal(stranger, 1 ether);
        vm.expectEmit(true, true, false, true, address(wallet));
        emit Deposited(walletId, address(0), 25);
        vm.prank(stranger);
        wallet.depositNative{value: 25}(walletId);

        assertEq(wallet.balanceOf(walletId, address(0)), 100 + 25);
    }

    function test_depositERC20_emitsEvent_pullsTokens() public {
        token.transfer(stranger, 1000);
        vm.prank(stranger);
        token.approve(address(wallet), 1000);

        vm.expectEmit(true, true, false, true, address(wallet));
        emit Deposited(walletId, address(token), 50);
        vm.prank(stranger);
        wallet.depositERC20(walletId, address(token), 50);

        assertEq(wallet.balanceOf(walletId, address(token)), 200 + 50);
    }

    // =========================================================================
    // Withdrawals
    // =========================================================================

    function test_withdraw_succeeds_emitsEvent() public {
        vm.expectEmit(true, true, true, true, address(wallet));
        emit Withdrawn(walletId, address(token), owner0, 80);
        vm.prank(operator);
        wallet.withdraw(walletId, address(token), owner0, 80);

        assertEq(wallet.balanceOf(walletId, address(token)), 200 - 80);
        assertEq(token.balanceOf(owner0), 100_000 - 200 + 80);
    }

    function test_withdraw_revertsForNonOperator() public {
        vm.expectRevert(AgentPayErrors.NotOperator.selector);
        vm.prank(stranger);
        wallet.withdraw(walletId, address(token), owner0, 50);
    }

    function test_withdraw_revertsForNonOwnerReceiver() public {
        vm.expectRevert(AgentPayErrors.NotWalletOwner.selector);
        vm.prank(operator);
        wallet.withdraw(walletId, address(token), stranger, 50);
    }

    // =========================================================================
    // Inter-wallet transfer
    // =========================================================================

    function test_transferToWallet_succeeds_emitsEvent() public {
        vm.expectEmit(true, true, true, true, address(wallet));
        emit TransferredBetweenWallets(walletId, walletId2, address(token), owner0, 50);
        vm.prank(operator);
        wallet.transferBetweenWallets(walletId, walletId2, address(token), owner0, 50);

        assertEq(wallet.balanceOf(walletId, address(token)), 200 - 50);
        assertEq(wallet.balanceOf(walletId2, address(token)), 50);
    }

    function test_transferToWallet_revertsForReceiverNotInBoth() public {
        vm.expectRevert(AgentPayErrors.NotWalletOwner.selector);
        vm.prank(operator);
        wallet.transferBetweenWallets(walletId, walletId2, address(token), stranger, 50);
    }

    // =========================================================================
    // Operator transfer — direct path & multi-owner proposal
    // =========================================================================

    function test_transferOperatorship_byOperator_succeeds_emitsEvent() public {
        vm.expectEmit(true, true, true, false, address(wallet));
        emit OperatorChanged(walletId, operator, newOperator);
        vm.prank(operator);
        wallet.transferOperatorship(walletId, newOperator);

        assertEq(wallet.walletOperator(walletId), newOperator);
    }

    function test_transferOperatorship_revertsForNonOperator() public {
        vm.expectRevert(AgentPayErrors.NotOperator.selector);
        vm.prank(stranger);
        wallet.transferOperatorship(walletId, newOperator);
    }

    function test_proposeNewOperator_unanimous_changesOperator() public {
        // First owner proposes — operator does not change yet.
        vm.expectEmit(true, true, true, false, address(wallet));
        emit OperatorVoted(walletId, newOperator, owner0);
        vm.prank(owner0);
        wallet.voteForOperator(walletId, newOperator);

        assertEq(wallet.walletOperator(walletId), operator);

        // Second owner agrees → operator changes; vote tally is then cleared.
        vm.expectEmit(true, true, true, false, address(wallet));
        emit OperatorVoted(walletId, newOperator, owner1);
        vm.expectEmit(true, true, true, false, address(wallet));
        emit OperatorChanged(walletId, operator, newOperator);
        vm.prank(owner1);
        wallet.voteForOperator(walletId, newOperator);

        assertEq(wallet.walletOperator(walletId), newOperator);
        assertEq(wallet.hasVoted(walletId, owner0), false);
        assertEq(wallet.hasVoted(walletId, owner1), false);
        // The proposed-new-operator slot is also cleared on success — leaving
        // it stale would confuse the next `proposeNewOperator` call's reset
        // condition (`_newOperator != w.proposedNewOperator`).
        assertEq(wallet.pendingOperator(walletId), address(0));
    }

    function test_transferOperatorship_clearsPendingProposal() public {
        // owner0 has an in-flight proposal for `newOperator`.
        vm.prank(owner0);
        wallet.voteForOperator(walletId, newOperator);
        assertEq(wallet.pendingOperator(walletId), newOperator);
        assertEq(wallet.hasVoted(walletId, owner0), true);

        // Current operator transfers operatorship directly — should also wipe
        // any pending proposal + vote tally.
        vm.prank(operator);
        wallet.transferOperatorship(walletId, newOperator);

        assertEq(wallet.pendingOperator(walletId), address(0));
        assertEq(wallet.hasVoted(walletId, owner0), false);
    }

    function test_proposeNewOperator_differentProposalResetsVotes() public {
        vm.prank(owner0);
        wallet.voteForOperator(walletId, newOperator);
        assertEq(wallet.hasVoted(walletId, owner0), true);

        // owner1 proposes a different address — the prior tally is wiped.
        address otherCandidate = makeAddr("otherCandidate");
        vm.prank(owner1);
        wallet.voteForOperator(walletId, otherCandidate);

        assertEq(wallet.hasVoted(walletId, owner0), false);
        assertEq(wallet.hasVoted(walletId, owner1), true);
        assertEq(wallet.pendingOperator(walletId), otherCandidate);
        assertEq(wallet.walletOperator(walletId), operator);
    }

    function test_proposeNewOperator_revertsForZeroAddress() public {
        vm.expectRevert(AgentPayErrors.ZeroAddress.selector);
        vm.prank(owner0);
        wallet.voteForOperator(walletId, address(0));
    }

    function test_proposeNewOperator_revertsForNonOwner() public {
        vm.expectRevert(AgentPayErrors.NotWalletOwner.selector);
        vm.prank(stranger);
        wallet.voteForOperator(walletId, newOperator);
    }

    function test_proposeNewOperator_succeedsEvenWhenPaused() public {
        wallet.pause();

        vm.expectEmit(true, true, true, false, address(wallet));
        emit OperatorVoted(walletId, stranger, owner0);
        vm.prank(owner0);
        wallet.voteForOperator(walletId, stranger);

        assertEq(wallet.pendingOperator(walletId), stranger);
    }

    // =========================================================================
    // Pause / unpause / drain
    // =========================================================================

    function test_pause_succeedsForOwner_emitsPaused() public {
        vm.expectEmit(false, false, false, true, address(wallet));
        emit Paused(owner);

        wallet.pause();

        assertTrue(wallet.paused());
    }

    function test_pause_revertsForNonOwner() public {
        vm.expectRevert();
        vm.prank(stranger);
        wallet.pause();
    }

    function test_unpause_byOwner_resumesOperations() public {
        wallet.pause();
        wallet.unpause();
        assertFalse(wallet.paused());

        // Deposits work again after unpause.
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        wallet.depositNative{value: 5}(walletId);
        assertEq(wallet.balanceOf(walletId, address(0)), 100 + 5);
    }

    function test_unpause_revertsForNonOwner() public {
        wallet.pause();
        vm.expectRevert();
        vm.prank(stranger);
        wallet.unpause();
    }

    function test_paused_blocksDepositsAndOperatorActions() public {
        wallet.pause();

        address[] memory localOwners = new address[](2);
        localOwners[0] = owner0;
        localOwners[1] = owner1;
        vm.expectRevert();
        walletHelper.create(localOwners, operator, 99);

        vm.deal(operator, 1 ether);
        vm.expectRevert();
        vm.prank(operator);
        wallet.depositNative{value: 100}(walletId);

        vm.expectRevert();
        vm.prank(owner0);
        wallet.depositERC20(walletId, address(token), 200);

        vm.expectRevert();
        vm.prank(operator);
        wallet.withdraw(walletId, address(token), owner0, 100);

        vm.expectRevert();
        vm.prank(operator);
        wallet.transferBetweenWallets(walletId, walletId2, address(token), owner0, 50);

        vm.expectRevert();
        vm.prank(operator);
        wallet.transferOperatorship(walletId, stranger);
    }

    function test_drainToken_revertsWhenNotPaused() public {
        vm.expectRevert();
        wallet.drainToken(address(0), owner, 100);

        vm.expectRevert();
        wallet.drainToken(address(token), owner, 200);
    }

    function test_drainToken_succeedsWhenPaused() public {
        // Use an EOA recipient so the ETH transfer succeeds.
        address drainRecipient = makeAddr("drainRecipient");

        wallet.pause();

        vm.expectEmit(true, true, false, true, address(wallet));
        emit TokenDrained(address(0), drainRecipient, 100);
        wallet.drainToken(address(0), drainRecipient, 100);
        assertEq(drainRecipient.balance, 100);

        vm.expectEmit(true, true, false, true, address(wallet));
        emit TokenDrained(address(token), stranger, 200);
        wallet.drainToken(address(token), stranger, 200);
        assertEq(token.balanceOf(stranger), 200);
    }

    // =========================================================================
    // Getters (revert paths)
    // =========================================================================

    function test_getProposalVote_returnsFalseForNonOwner() public view {
        // The vote map is non-sensitive — non-owners can read freely; their
        // unset entry returns the default (false).
        assertEq(wallet.hasVoted(walletId, stranger), false);
    }

    function test_getProposedNewOperator_zeroByDefault() public view {
        assertEq(wallet.pendingOperator(walletId), address(0));
    }
}
