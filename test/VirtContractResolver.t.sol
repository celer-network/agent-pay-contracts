// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VirtContractResolver} from "../src/VirtContractResolver.sol";

/**
 * @title VirtContractResolver tests
 * @notice Unit tests for {VirtContractResolver}. Exercises the `CREATE`-based
 *  virtual-contract materialization path: deploy bytecode under a deterministic
 *  virtual address, resolve known / unknown addresses, and reject re-deploy
 *  under the same `(code, nonce)`.
 */
contract VirtContractResolverTest is Test {
    VirtContractResolver internal resolver;

    // Minimal runtime bytecode that returns success when called. Used as the body
    // of a virtual contract for deployment tests.
    //
    // Deploy code: PUSH1 0x06 (size) DUP1 PUSH1 0x0a (offset) PUSH1 0x00 CODECOPY
    //              PUSH1 0x00 RETURN
    // Runtime:     PUSH1 0x01 PUSH1 0x00 MSTORE PUSH1 0x20 PUSH1 0x00 RETURN
    bytes internal constant SAMPLE_CODE = hex"60068060093d393df3" hex"6001600052602060f3";

    event Deploy(bytes32 indexed virtAddr);

    function setUp() public {
        resolver = new VirtContractResolver();
    }

    function test_resolve_revertsForUnknownVirtAddr() public {
        vm.expectRevert(bytes("Nonexistent virtual address"));
        resolver.resolve(bytes32(uint256(1)));
    }

    function test_deploy_createsContract_emitsEventAndMapsAddress() public {
        bytes32 expectedVirtAddr = keccak256(abi.encodePacked(SAMPLE_CODE, uint256(1024)));

        vm.expectEmit(true, false, false, false, address(resolver));
        emit Deploy(expectedVirtAddr);

        bool ok = resolver.deploy(SAMPLE_CODE, 1024);
        assertTrue(ok);

        address deployed = resolver.resolve(expectedVirtAddr);
        assertTrue(deployed != address(0));
        // The mapped address must contain the runtime bytecode (non-empty extcodesize).
        assertGt(deployed.code.length, 0);
    }

    function test_deploy_revertsIfAlreadyDeployed() public {
        resolver.deploy(SAMPLE_CODE, 7);

        vm.expectRevert(bytes("Current real address is not 0"));
        resolver.deploy(SAMPLE_CODE, 7);
    }
}
