// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {RouterRegistry} from "../src/RouterRegistry.sol";
import {IRouterRegistry} from "../src/interfaces/IRouterRegistry.sol";

/**
 * @title RouterRegistry tests
 * @notice Unit tests for {RouterRegistry}. Exercises the optional relay-router
 *  self-advertisement registry: register / deregister / refresh and their
 *  revert paths, plus `routerInfo` readback semantics.
 */
contract RouterRegistryTest is Test {
    RouterRegistry internal registry;

    address internal router0 = makeAddr("router0");
    address internal router1 = makeAddr("router1");

    event RouterUpdated(IRouterRegistry.RouterOperation indexed op, address indexed routerAddress);

    function setUp() public {
        // Anchor block.timestamp far above zero so timestamp comparisons in
        // tests can't underflow.
        vm.warp(1_000_000);

        registry = new RouterRegistry();
    }

    // -------------------------------------------------------------------------
    // registerRouter
    // -------------------------------------------------------------------------

    function test_registerRouter_succeedsForNewAddress_emitsAdd() public {
        vm.expectEmit(true, true, false, false, address(registry));
        emit RouterUpdated(IRouterRegistry.RouterOperation.Add, router0);

        vm.prank(router0);
        registry.registerRouter();

        assertEq(registry.routerInfo(router0), block.timestamp);
    }

    function test_registerRouter_revertsForAlreadyRegistered() public {
        vm.prank(router0);
        registry.registerRouter();

        vm.expectRevert(bytes("Router address already exists"));
        vm.prank(router0);
        registry.registerRouter();
    }

    // -------------------------------------------------------------------------
    // deregisterRouter
    // -------------------------------------------------------------------------

    function test_deregisterRouter_succeedsForRegistered_emitsRemove() public {
        vm.prank(router0);
        registry.registerRouter();

        vm.expectEmit(true, true, false, false, address(registry));
        emit RouterUpdated(IRouterRegistry.RouterOperation.Remove, router0);

        vm.prank(router0);
        registry.deregisterRouter();

        assertEq(registry.routerInfo(router0), 0);
    }

    function test_deregisterRouter_revertsForUnregistered() public {
        vm.expectRevert(bytes("Router address does not exist"));
        vm.prank(router0);
        registry.deregisterRouter();
    }

    // -------------------------------------------------------------------------
    // refreshRouter
    // -------------------------------------------------------------------------

    function test_refreshRouter_updatesTimestamp_emitsRefresh() public {
        vm.prank(router0);
        registry.registerRouter();
        uint256 firstTime = block.timestamp;

        // Advance and refresh.
        vm.warp(firstTime + 50);

        vm.expectEmit(true, true, false, false, address(registry));
        emit RouterUpdated(IRouterRegistry.RouterOperation.Refresh, router0);

        vm.prank(router0);
        registry.refreshRouter();

        assertEq(registry.routerInfo(router0), firstTime + 50);
    }

    function test_refreshRouter_revertsForUnregistered() public {
        vm.expectRevert(bytes("Router address does not exist"));
        vm.prank(router0);
        registry.refreshRouter();
    }

    // -------------------------------------------------------------------------
    // routerInfo public getter
    // -------------------------------------------------------------------------

    function test_routerInfo_returnsTimestampForRegistered() public {
        vm.prank(router0);
        registry.registerRouter();

        assertEq(registry.routerInfo(router0), block.timestamp);
    }

    function test_routerInfo_returnsZeroForUnregistered() public {
        // router1 was never registered.
        assertEq(registry.routerInfo(router1), 0);
    }
}
