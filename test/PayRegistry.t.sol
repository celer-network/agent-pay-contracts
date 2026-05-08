// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AgentPayErrors} from "../src/lib/AgentPayErrors.sol";
import {PayRegistry} from "../src/PayRegistry.sol";

/**
 * @title PayRegistry tests
 * @notice Unit tests for {PayRegistry}. Covers the namespaced `payId` derivation,
 *  per-pay setters (`setPayAmount` / `setPayDeadline` / `setPayInfo`) plus their
 *  batched variants, multi-setter independence, the bulk `getPayAmounts` read
 *  path used during channel settlement, and `payInfoMap`'s public getter.
 */
contract PayRegistryTest is Test {
    PayRegistry internal registry;

    address internal setterA = makeAddr("setterA");
    address internal setterB = makeAddr("setterB");

    bytes32 internal payHash1 = keccak256("pay-1");
    bytes32 internal payHash2 = keccak256("pay-2");

    event PayInfoUpdate(bytes32 indexed payId, uint256 amount, uint256 resolveDeadline);

    function setUp() public {
        // Anchor block.timestamp far above zero so deadline math like
        // `block.timestamp - 1` cannot underflow.
        vm.warp(1_000_000);

        registry = new PayRegistry();
    }

    // -------------------------------------------------------------------------
    // calculatePayId
    // -------------------------------------------------------------------------

    function test_calculatePayId_matchesSpec() public view {
        bytes32 expected = keccak256(abi.encodePacked(payHash1, setterA));
        assertEq(registry.calculatePayId(payHash1, setterA), expected);
    }

    function test_calculatePayId_differsBySetter() public view {
        bytes32 idA = registry.calculatePayId(payHash1, setterA);
        bytes32 idB = registry.calculatePayId(payHash1, setterB);
        assertTrue(idA != idB);
    }

    // -------------------------------------------------------------------------
    // setPayAmount / setPayDeadline / setPayInfo
    // -------------------------------------------------------------------------

    function test_setPayAmount_writesAmount_emitsEvent() public {
        bytes32 expectedId = registry.calculatePayId(payHash1, setterA);

        vm.expectEmit(true, false, false, true, address(registry));
        emit PayInfoUpdate(expectedId, 100, 0);

        vm.prank(setterA);
        registry.setPayAmount(payHash1, 100);

        (uint256 amount, uint256 deadline) = registry.getPayInfo(expectedId);
        assertEq(amount, 100);
        assertEq(deadline, 0);
    }

    function test_setPayDeadline_writesDeadline_emitsEvent() public {
        bytes32 expectedId = registry.calculatePayId(payHash1, setterA);

        vm.expectEmit(true, false, false, true, address(registry));
        emit PayInfoUpdate(expectedId, 0, 999);

        vm.prank(setterA);
        registry.setPayDeadline(payHash1, 999);

        (uint256 amount, uint256 deadline) = registry.getPayInfo(expectedId);
        assertEq(amount, 0);
        assertEq(deadline, 999);
    }

    function test_setPayInfo_writesBoth_emitsEvent() public {
        bytes32 expectedId = registry.calculatePayId(payHash1, setterA);

        vm.expectEmit(true, false, false, true, address(registry));
        emit PayInfoUpdate(expectedId, 42, 1000);

        vm.prank(setterA);
        registry.setPayInfo(payHash1, 42, 1000);

        (uint256 amount, uint256 deadline) = registry.getPayInfo(expectedId);
        assertEq(amount, 42);
        assertEq(deadline, 1000);
    }

    function test_differentSetters_writeIndependentEntries() public {
        vm.prank(setterA);
        registry.setPayInfo(payHash1, 1, 100);

        vm.prank(setterB);
        registry.setPayInfo(payHash1, 2, 200);

        (uint256 amountA, uint256 deadlineA) = registry.getPayInfo(registry.calculatePayId(payHash1, setterA));
        (uint256 amountB, uint256 deadlineB) = registry.getPayInfo(registry.calculatePayId(payHash1, setterB));

        assertEq(amountA, 1);
        assertEq(deadlineA, 100);
        assertEq(amountB, 2);
        assertEq(deadlineB, 200);
    }

    // -------------------------------------------------------------------------
    // Batched setters
    // -------------------------------------------------------------------------

    function test_setPayAmounts_batched() public {
        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = payHash1;
        hashes[1] = payHash2;
        uint256[] memory amts = new uint256[](2);
        amts[0] = 11;
        amts[1] = 22;

        vm.prank(setterA);
        registry.setPayAmounts(hashes, amts);

        (uint256 amount1,) = registry.getPayInfo(registry.calculatePayId(payHash1, setterA));
        (uint256 amount2,) = registry.getPayInfo(registry.calculatePayId(payHash2, setterA));
        assertEq(amount1, 11);
        assertEq(amount2, 22);
    }

    function test_setPayAmounts_revertsIfLengthMismatch() public {
        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = payHash1;
        hashes[1] = payHash2;
        uint256[] memory amts = new uint256[](1);
        amts[0] = 11;

        // Full-payload assertion — locks down the (a, b) lengths so a future
        // edit that swaps argument order or returns the wrong sides still fails.
        vm.expectRevert(abi.encodeWithSelector(AgentPayErrors.LengthMismatch.selector, uint256(2), uint256(1)));
        vm.prank(setterA);
        registry.setPayAmounts(hashes, amts);
    }

    function test_setPayDeadlines_batched() public {
        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = payHash1;
        hashes[1] = payHash2;
        uint256[] memory deadlines = new uint256[](2);
        deadlines[0] = 500;
        deadlines[1] = 600;

        vm.prank(setterA);
        registry.setPayDeadlines(hashes, deadlines);

        (, uint256 deadline1) = registry.getPayInfo(registry.calculatePayId(payHash1, setterA));
        (, uint256 deadline2) = registry.getPayInfo(registry.calculatePayId(payHash2, setterA));
        assertEq(deadline1, 500);
        assertEq(deadline2, 600);
    }

    function test_setPayInfos_batched() public {
        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = payHash1;
        hashes[1] = payHash2;
        uint256[] memory amts = new uint256[](2);
        amts[0] = 1;
        amts[1] = 2;
        uint256[] memory deadlines = new uint256[](2);
        deadlines[0] = 10;
        deadlines[1] = 20;

        vm.prank(setterA);
        registry.setPayInfos(hashes, amts, deadlines);

        (uint256 a1, uint256 d1) = registry.getPayInfo(registry.calculatePayId(payHash1, setterA));
        (uint256 a2, uint256 d2) = registry.getPayInfo(registry.calculatePayId(payHash2, setterA));
        assertEq(a1, 1);
        assertEq(d1, 10);
        assertEq(a2, 2);
        assertEq(d2, 20);
    }

    function test_setPayInfos_revertsIfLengthMismatch() public {
        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = payHash1;
        hashes[1] = payHash2;
        uint256[] memory amts = new uint256[](2);
        uint256[] memory deadlines = new uint256[](1);

        vm.expectPartialRevert(AgentPayErrors.LengthMismatch.selector);
        vm.prank(setterA);
        registry.setPayInfos(hashes, amts, deadlines);
    }

    // -------------------------------------------------------------------------
    // getPayAmounts (used during channel settlement)
    // -------------------------------------------------------------------------

    function test_getPayAmounts_returnsResolvedAmounts_whenDeadlinePassed() public {
        vm.prank(setterA);
        registry.setPayInfo(payHash1, 50, block.timestamp + 5);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = registry.calculatePayId(payHash1, setterA);

        // Roll past the per-pay deadline so the pay is finalized.
        vm.warp(block.timestamp + 6);

        uint256[] memory amounts = registry.getPayAmounts(ids, block.timestamp);
        assertEq(amounts.length, 1);
        assertEq(amounts[0], 50);
    }

    function test_getPayAmounts_revertsIfPayNotFinalized() public {
        vm.prank(setterA);
        registry.setPayInfo(payHash1, 50, block.timestamp + 100);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = registry.calculatePayId(payHash1, setterA);

        // Per-pay deadline is in the future; should revert.
        vm.expectRevert(AgentPayErrors.PaymentNotFinalized.selector);
        registry.getPayAmounts(ids, block.timestamp);
    }

    function test_getPayAmounts_unsetPay_passesIfChannelDeadlineExceeded() public {
        // No setPayInfo for payHash1 → resolveDeadline == 0 → falls through to the
        // channel-level payClearDeadline check.
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = registry.calculatePayId(payHash1, setterA);

        // Channel-level payClearDeadline is in the past → ok to read.
        vm.warp(block.timestamp + 10);
        uint256[] memory amounts = registry.getPayAmounts(ids, block.timestamp - 1);
        assertEq(amounts[0], 0);
    }

    function test_getPayAmounts_unsetPay_revertsIfChannelDeadlineNotExceeded() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = registry.calculatePayId(payHash1, setterA);

        // Channel-level payClearDeadline is in the future → revert.
        vm.expectRevert(AgentPayErrors.PaymentNotFinalized.selector);
        registry.getPayAmounts(ids, block.timestamp + 100);
    }

    // -------------------------------------------------------------------------
    // payInfoMap auto-getter
    // -------------------------------------------------------------------------

    function test_payInfoMap_publicGetter() public {
        vm.prank(setterA);
        registry.setPayInfo(payHash1, 7, 8);

        (uint256 amount, uint256 deadline) = registry.payInfoMap(registry.calculatePayId(payHash1, setterA));
        assertEq(amount, 7);
        assertEq(deadline, 8);
    }
}
