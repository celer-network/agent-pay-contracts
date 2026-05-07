// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CelerWallet} from "../../src/CelerWallet.sol";
import {CelerLedger} from "../../src/CelerLedger.sol";
import {NativeWrapMock} from "../../src/helper/NativeWrapMock.sol";
import {PayRegistry} from "../../src/PayRegistry.sol";
import {PayResolver} from "../../src/PayResolver.sol";
import {VirtContractResolver} from "../../src/VirtContractResolver.sol";
import {ERC20ExampleToken} from "../../src/helper/ERC20ExampleToken.sol";

/**
 * @title BaseTest
 * @notice Common deployment + helper utilities for AgentPay Foundry tests. Inherit
 *  this from individual test contracts to get a fully wired contract graph
 *  (`celerWallet`, `celerLedger`, `nativeWrap`, `payRegistry`, `payResolver`,
 *  `virtResolver`, `erc20`) and a few addressing helpers.
 * @dev `setUp()` here can be called from a child's own `setUp()` via `super.setUp()`.
 *  Tests that don't need every dependency may reach into the contracts directly
 *  rather than calling this — see `RouterRegistry.t.sol` for a minimal example.
 */
contract BaseTest is Test {
    // -------------------------------------------------------------------------
    // Deployed contracts
    // -------------------------------------------------------------------------
    CelerWallet internal celerWallet;
    CelerLedger internal celerLedger;
    NativeWrapMock internal nativeWrap;
    PayRegistry internal payRegistry;
    PayResolver internal payResolver;
    VirtContractResolver internal virtResolver;
    ERC20ExampleToken internal erc20;

    // -------------------------------------------------------------------------
    // Common test addresses
    // -------------------------------------------------------------------------
    address internal admin = address(this);

    // Channel peers — addresses are deterministically sorted (peer0 < peer1) so they
    // can be passed directly to functions that require ascending peer order.
    address internal peer0;
    address internal peer1;
    uint256 internal peer0Pk;
    uint256 internal peer1Pk;

    // Payment source / destination — used in PayResolver tests.
    address internal client0;
    address internal client1;
    uint256 internal client0Pk;
    uint256 internal client1Pk;

    // Generic third-party
    address internal stranger;

    function setUp() public virtual {
        // Anchor block.timestamp far above zero so deadline math like
        // `block.timestamp - DISPUTE_TIMEOUT` cannot underflow in tests that
        // simulate states predating the channel's open time.
        vm.warp(1_000_000);

        // Deploy the full contract graph in dependency order.
        nativeWrap = new NativeWrapMock();
        payRegistry = new PayRegistry();
        virtResolver = new VirtContractResolver();
        payResolver = new PayResolver(address(payRegistry), address(virtResolver));
        celerWallet = new CelerWallet();
        celerLedger = new CelerLedger(address(nativeWrap), address(payRegistry), address(celerWallet));
        erc20 = new ERC20ExampleToken();

        vm.label(address(celerWallet), "CelerWallet");
        vm.label(address(celerLedger), "CelerLedger");
        vm.label(address(nativeWrap), "NativeWrap");
        vm.label(address(payRegistry), "PayRegistry");
        vm.label(address(payResolver), "PayResolver");
        vm.label(address(virtResolver), "VirtContractResolver");
        vm.label(address(erc20), "ERC20ExampleToken");

        // Generate sorted peer pair (peer0 < peer1) for channel tests.
        (peer0, peer1, peer0Pk, peer1Pk) = _makeSortedPeerPair("peer0", "peer1");
        (client0, client1, client0Pk, client1Pk) = _makeSortedPeerPair("client0", "client1");

        stranger = makeAddr("stranger");

        vm.label(peer0, "peer0");
        vm.label(peer1, "peer1");
        vm.label(client0, "client0");
        vm.label(client1, "client1");
        vm.label(stranger, "stranger");
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    /// @dev Produce two named addresses sorted ascending by address value, with their
    ///  private keys. The contracts require peers in ascending order; this avoids
    ///  ordering bugs in tests.
    function _makeSortedPeerPair(string memory _name0, string memory _name1)
        internal
        returns (address a0, address a1, uint256 pk0, uint256 pk1)
    {
        (address candidate0, uint256 candidate0Pk) = makeAddrAndKey(_name0);
        (address candidate1, uint256 candidate1Pk) = makeAddrAndKey(_name1);
        if (candidate0 < candidate1) {
            return (candidate0, candidate1, candidate0Pk, candidate1Pk);
        } else {
            return (candidate1, candidate0, candidate1Pk, candidate0Pk);
        }
    }

    /// @dev Sort an address pair ascending. Returns `[low, high]`.
    function _sortAddrs(address _a, address _b) internal pure returns (address[] memory out) {
        out = new address[](2);
        if (_a < _b) {
            out[0] = _a;
            out[1] = _b;
        } else {
            out[0] = _b;
            out[1] = _a;
        }
    }
}
