// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LedgerTestBase} from "../utils/LedgerTestBase.t.sol";
import {LedgerStruct} from "../../src/lib/ledgerlib/LedgerStruct.sol";
import {ChannelHandler} from "./handlers/ChannelHandler.sol";

/**
 * @title ChannelInvariants
 * @notice Foundry invariant tests for `CelerLedger`. A {ChannelHandler} drives
 *  random sequences of channel actions across both native and ERC-20 channels:
 *  open / deposit / cooperative withdraw / cooperative settle / unilateral
 *  withdraw + veto + confirm / snapshotStates / intendSettle / confirmSettle.
 *  After every call sequence Foundry re-evaluates each `invariant_*` function.
 *
 *  Properties checked:
 *
 *  1. Channel-status transitions are legal — see {LedgerStruct.ChannelStatus}.
 *  2. Per-peer cumulative `deposit` and `withdrawal` are monotonically non-decreasing.
 *  3. Per-peer `state.transferOut` and `state.seqNum` never decrease *except*
 *     on the documented `Settling → Operable` rebound (failed `confirmSettle`)
 *     where {LedgerOperation._resetDuplexState} explicitly clears them.
 *  4. Wallet-side balance equals total deposits minus total withdrawals while
 *     the channel is Operable / Settling, and is fully drained on Closed.
 *  5. Handler ghost accumulators agree with on-chain `peerProfiles.deposit` /
 *     `peerProfiles.withdrawal`.
 *
 *  Cross-version migration is out of scope (covered by direct tests in
 *  `CelerLedger.Migrate.t.sol`); pending pay lists in simplex states are also
 *  out of scope (handler always passes empty lists).
 */
contract ChannelInvariants is LedgerTestBase {
    ChannelHandler internal handler;

    // Snapshot of last-observed monotonic fields per channel and peer index.
    // Refreshed after every invariant pass; used to assert non-decrease.
    mapping(bytes32 => uint256[2]) internal lastDeposit;
    mapping(bytes32 => uint256[2]) internal lastWithdrawal;
    mapping(bytes32 => uint256[2]) internal lastTransferOut;
    mapping(bytes32 => uint256[2]) internal lastSeqNum;
    mapping(bytes32 => uint256) internal lastStatusValue;
    // Separate status snapshot for the simplex-monotonic invariant so it can
    // detect the Settling → Operable rebound independently of the status
    // invariant's own bookkeeping.
    mapping(bytes32 => uint256) internal lastStatusForSimplex;

    function setUp() public override {
        super.setUp();

        // Disable per-token deposit caps so fuzzed open / deposit calls aren't
        // gated by uninitialized limits.
        celerLedger.disableBalanceLimits();

        // Seed peer ERC-20 balances + approvals upfront. The handler's
        // `_ensureErc20Balance` will top up later if a peer drains, but
        // doing the initial approval here avoids relying on lazy init for the
        // first few opens.
        deal(address(erc20), peer0, 100 ether);
        deal(address(erc20), peer1, 100 ether);
        vm.prank(peer0);
        erc20.approve(address(celerLedger), type(uint256).max);
        vm.prank(peer1);
        erc20.approve(address(celerLedger), type(uint256).max);

        handler = new ChannelHandler(celerLedger, celerWallet, nativeWrap, erc20, peer0, peer1, peer0Pk, peer1Pk);

        // Restrict Foundry's fuzzer to the handler — otherwise it would call
        // every public function on the inherited test scaffolding.
        targetContract(address(handler));
    }

    // -------------------------------------------------------------------------
    // Invariant 1 — channel-status transitions follow the legal state machine.
    // Legal transitions:
    //   Operable → {Operable, Settling, Closed}
    //   Settling → {Settling, Operable (rebound on confirmSettle failure), Closed}
    //   Closed → Closed (terminal)
    // (Migrated is out of scope for this test.)
    // -------------------------------------------------------------------------
    function invariant_statusTransitionsLegal() public {
        uint256 n = handler.channelCount();
        for (uint256 i = 0; i < n; i++) {
            bytes32 id = handler.channelIds(i);
            uint256 prev = lastStatusValue[id];
            uint256 curr = uint256(celerLedger.getChannelStatus(id));

            if (prev == 0) {
                lastStatusValue[id] = curr;
                continue;
            }

            if (prev == uint256(LedgerStruct.ChannelStatus.Closed)) {
                assertEq(curr, prev, "Closed must remain Closed");
            }

            if (curr < prev) {
                assertTrue(
                    prev == uint256(LedgerStruct.ChannelStatus.Settling)
                        && curr == uint256(LedgerStruct.ChannelStatus.Operable),
                    "Illegal status backslide"
                );
            }

            lastStatusValue[id] = curr;
        }
    }

    // -------------------------------------------------------------------------
    // Invariant 2 — per-peer `deposit` and `withdrawal` are monotonic.
    // -------------------------------------------------------------------------
    function invariant_peerAccountingMonotonic() public {
        uint256 n = handler.channelCount();
        for (uint256 i = 0; i < n; i++) {
            bytes32 id = handler.channelIds(i);
            (, uint256[2] memory deps, uint256[2] memory wds) = celerLedger.getBalanceMap(id);

            assertGe(deps[0], lastDeposit[id][0], "peer0 deposit decreased");
            assertGe(deps[1], lastDeposit[id][1], "peer1 deposit decreased");
            assertGe(wds[0], lastWithdrawal[id][0], "peer0 withdrawal decreased");
            assertGe(wds[1], lastWithdrawal[id][1], "peer1 withdrawal decreased");

            lastDeposit[id] = deps;
            lastWithdrawal[id] = wds;
        }
    }

    // -------------------------------------------------------------------------
    // Invariant 3 — `state.transferOut` and `state.seqNum` are monotonic
    //  except across the documented `Settling → Operable` rebound, where
    //  `_resetDuplexState` deliberately clears the duplex state so a fresh
    //  `intendSettle` sequence can run.
    // -------------------------------------------------------------------------
    function invariant_simplexStateMonotonic() public {
        uint256 n = handler.channelCount();
        for (uint256 i = 0; i < n; i++) {
            bytes32 id = handler.channelIds(i);
            uint256 currStatus = uint256(celerLedger.getChannelStatus(id));
            uint256 prevStatus = lastStatusForSimplex[id];

            (, uint256[2] memory seqs) = celerLedger.getStateSeqNumMap(id);
            (, uint256[2] memory tos) = celerLedger.getTransferOutMap(id);

            bool rebound = prevStatus == uint256(LedgerStruct.ChannelStatus.Settling)
                && currStatus == uint256(LedgerStruct.ChannelStatus.Operable);

            if (!rebound) {
                assertGe(seqs[0], lastSeqNum[id][0], "peer0 seqNum decreased");
                assertGe(seqs[1], lastSeqNum[id][1], "peer1 seqNum decreased");
                assertGe(tos[0], lastTransferOut[id][0], "peer0 transferOut decreased");
                assertGe(tos[1], lastTransferOut[id][1], "peer1 transferOut decreased");
            }

            lastSeqNum[id] = seqs;
            lastTransferOut[id] = tos;
            lastStatusForSimplex[id] = currStatus;
        }
    }

    // -------------------------------------------------------------------------
    // Invariant 4 — wallet balance equals net of cumulative deposits/withdrawals.
    //  Routes through `channelToken[id]` so both native and ERC-20 channels are
    //  checked against the right token. Closed channels must show a fully
    //  drained wallet entry.
    // -------------------------------------------------------------------------
    function invariant_walletBalanceMatchesNetDeposits() public view {
        uint256 n = handler.channelCount();
        for (uint256 i = 0; i < n; i++) {
            bytes32 id = handler.channelIds(i);
            uint256 status = uint256(celerLedger.getChannelStatus(id));
            address token = handler.channelToken(id);
            uint256 walletBal = celerWallet.balanceOf(id, token);

            (, uint256[2] memory deps, uint256[2] memory wds) = celerLedger.getBalanceMap(id);
            uint256 netLedger = deps[0] + deps[1] - wds[0] - wds[1];

            if (
                status == uint256(LedgerStruct.ChannelStatus.Operable)
                    || status == uint256(LedgerStruct.ChannelStatus.Settling)
            ) {
                assertEq(walletBal, netLedger, "wallet vs ledger accounting drift");
            } else if (status == uint256(LedgerStruct.ChannelStatus.Closed)) {
                assertEq(walletBal, 0, "Closed channel still holds funds");
            }
        }
    }

    // -------------------------------------------------------------------------
    // Invariant 5 — ghost vs on-chain deposit/withdrawal totals agree.
    // -------------------------------------------------------------------------
    function invariant_ghostMatchesOnChain() public view {
        uint256 n = handler.channelCount();
        for (uint256 i = 0; i < n; i++) {
            bytes32 id = handler.channelIds(i);
            (, uint256[2] memory deps, uint256[2] memory wds) = celerLedger.getBalanceMap(id);

            assertEq(deps[0] + deps[1], handler.ghostDeposits(id), "deposit total mismatch");
            assertEq(wds[0] + wds[1], handler.ghostWithdrawals(id), "withdrawal total mismatch");
        }
    }

    // -------------------------------------------------------------------------
    // Sanity / observability — surfaces handler call-shape distribution per run.
    //  No asserts; reading `callsByName` is enough for Foundry to keep the
    //  invariant in the report and show non-zero counts per action.
    // -------------------------------------------------------------------------
    function invariant_callDistribution() public view {
        handler.callsByName("openNativeChannel");
        handler.callsByName("openErc20Channel");
        handler.callsByName("snapshotStates");
        handler.callsByName("intendSettle");
        handler.callsByName("confirmSettle");
    }
}
