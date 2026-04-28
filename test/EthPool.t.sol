// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {EthPool} from "../src/EthPool.sol";

/**
 * @title EthPool tests
 * @notice Unit tests for {EthPool}. Verifies the ERC20-shaped wrapper for
 *  native ETH: deposit, withdraw, allowance management, and `transferFrom`.
 */
contract EthPoolTest is Test {
    EthPool internal pool;

    address payable internal alice;
    address payable internal bob;
    address payable internal recipient = payable(address(0x123456789));

    event Deposit(address indexed receiver, uint256 value);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        pool = new EthPool();
        alice = payable(makeAddr("alice"));
        bob = payable(makeAddr("bob"));

        // Fund alice and bob with ETH so they can interact with the pool.
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    // -------------------------------------------------------------------------
    // deposit
    // -------------------------------------------------------------------------

    function test_deposit_creditsReceiver_emitsEvent() public {
        vm.expectEmit(true, false, false, true, address(pool));
        emit Deposit(bob, 100);

        vm.prank(alice);
        pool.deposit{value: 100}(bob);

        assertEq(pool.balanceOf(bob), 100);
    }

    function test_deposit_revertsForZeroReceiver() public {
        vm.expectRevert(bytes("Receiver address is 0"));
        pool.deposit{value: 1}(address(0));
    }

    // -------------------------------------------------------------------------
    // withdraw
    // -------------------------------------------------------------------------

    function test_withdraw_failsWithoutDeposit() public {
        // Solidity 0.8 will revert with arithmetic underflow when subtracting from 0.
        vm.expectRevert();
        vm.prank(alice);
        pool.withdraw(100);
    }

    function test_withdraw_succeedsAfterDeposit_emitsTransfer() public {
        // Deposit 100 to alice's balance.
        vm.prank(alice);
        pool.deposit{value: 100}(alice);

        uint256 aliceBalanceBefore = alice.balance;

        vm.expectEmit(true, true, false, true, address(pool));
        emit Transfer(alice, alice, 100);

        vm.prank(alice);
        pool.withdraw(100);

        assertEq(pool.balanceOf(alice), 0);
        assertEq(alice.balance, aliceBalanceBefore + 100);
    }

    // -------------------------------------------------------------------------
    // approve / allowance
    // -------------------------------------------------------------------------

    function test_approve_setsAllowance_emitsEvent() public {
        vm.expectEmit(true, true, false, true, address(pool));
        emit Approval(alice, bob, 200);

        vm.prank(alice);
        bool ok = pool.approve(bob, 200);

        assertTrue(ok);
        assertEq(pool.allowance(alice, bob), 200);
    }

    function test_approve_revertsForZeroSpender() public {
        vm.expectRevert(bytes("Spender address is 0"));
        vm.prank(alice);
        pool.approve(address(0), 100);
    }

    // -------------------------------------------------------------------------
    // transferFrom
    // -------------------------------------------------------------------------

    function test_transferFrom_movesEthAndDecrementsAllowance() public {
        // alice deposits 200 and approves bob for 200.
        vm.prank(alice);
        pool.deposit{value: 200}(alice);
        vm.prank(alice);
        pool.approve(bob, 200);

        uint256 recipientBefore = recipient.balance;

        // bob transfers 150 from alice's pool balance to recipient.
        vm.expectEmit(true, true, false, true, address(pool));
        emit Approval(alice, bob, 50); // remaining allowance after decrement
        vm.expectEmit(true, true, false, true, address(pool));
        emit Transfer(alice, recipient, 150);

        vm.prank(bob);
        bool ok = pool.transferFrom(alice, recipient, 150);
        assertTrue(ok);

        assertEq(pool.balanceOf(alice), 50);
        assertEq(pool.allowance(alice, bob), 50);
        assertEq(recipient.balance, recipientBefore + 150);
    }

    function test_transferFrom_revertsWhenAllowanceTooSmall() public {
        // alice deposits 200, approves bob for only 50.
        vm.prank(alice);
        pool.deposit{value: 200}(alice);
        vm.prank(alice);
        pool.approve(bob, 50);

        vm.expectRevert();
        vm.prank(bob);
        pool.transferFrom(alice, recipient, 100);
    }

    // -------------------------------------------------------------------------
    // increaseAllowance / decreaseAllowance
    // -------------------------------------------------------------------------

    function test_increaseAllowance_addsToCurrent() public {
        vm.prank(alice);
        pool.approve(bob, 50);

        vm.expectEmit(true, true, false, true, address(pool));
        emit Approval(alice, bob, 100);

        vm.prank(alice);
        bool ok = pool.increaseAllowance(bob, 50);

        assertTrue(ok);
        assertEq(pool.allowance(alice, bob), 100);
    }

    function test_decreaseAllowance_subtractsFromCurrent() public {
        vm.prank(alice);
        pool.approve(bob, 100);

        vm.expectEmit(true, true, false, true, address(pool));
        emit Approval(alice, bob, 20);

        vm.prank(alice);
        bool ok = pool.decreaseAllowance(bob, 80);

        assertTrue(ok);
        assertEq(pool.allowance(alice, bob), 20);
    }

    // -------------------------------------------------------------------------
    // Round-trip fuzz
    // -------------------------------------------------------------------------

    function testFuzz_depositWithdraw_roundTripPreservesBalance(uint96 _amount) public {
        vm.assume(_amount > 0);
        vm.deal(alice, uint256(_amount));

        uint256 aliceEthBefore = alice.balance;

        vm.prank(alice);
        pool.deposit{value: _amount}(alice);
        assertEq(pool.balanceOf(alice), _amount);

        vm.prank(alice);
        pool.withdraw(_amount);
        assertEq(pool.balanceOf(alice), 0);
        assertEq(alice.balance, aliceEthBefore);
    }
}
