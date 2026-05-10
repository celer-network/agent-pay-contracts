// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {AgentPayLedger} from "../../../src/AgentPayLedger.sol";
import {AgentPayWallet} from "../../../src/AgentPayWallet.sol";
import {NativeWrapMock} from "../../../src/helper/NativeWrapMock.sol";
import {ERC20ExampleToken} from "../../../src/helper/ERC20ExampleToken.sol";
import {LedgerStruct} from "../../../src/lib/ledgerlib/LedgerStruct.sol";
import {Fixtures} from "../../utils/Fixtures.sol";
import {SignUtil} from "../../utils/SignUtil.sol";

/**
 * @title ChannelHandler
 * @notice Invariant-test driver for `AgentPayLedger`. Each public function wraps one
 *  user-facing channel action (open / deposit / cooperative withdraw / cooperative
 *  settle / unilateral withdraw + veto + confirm / snapshotStates / intendSettle /
 *  confirmSettle). Foundry selects functions and fuzzes their args; the handler
 *  bounds them into valid ranges and tracks ghost state (cumulative deposits /
 *  withdrawals per channel, plus token type) used by the invariants in
 *  `ChannelInvariants.t.sol`.
 *
 *  Single fixed peer pair so signatures can be reproduced from known private keys.
 *  Both native and ERC-20 channels are exercised; per-channel token type is tracked
 *  in `channelToken[id]` so balance-querying ops route correctly. Pending pay
 *  lists are out of scope (always empty); cross-version migration is not driven.
 */
contract ChannelHandler is CommonBase, StdCheats, StdUtils {
    // -----------------------------------------------------------------------------
    // Wired contracts (deployed by the invariant test, passed in via constructor).
    // -----------------------------------------------------------------------------
    AgentPayLedger public immutable ledger;
    AgentPayWallet public immutable wallet;
    NativeWrapMock public immutable nativeWrap;
    ERC20ExampleToken public immutable erc20;

    // Fixed peer pair (sorted ascending; private keys allow re-signing every message).
    address public immutable peer0;
    address public immutable peer1;
    uint256 internal immutable peer0Pk;
    uint256 internal immutable peer1Pk;

    // -----------------------------------------------------------------------------
    // Tracked channels and ghost accounting.
    // -----------------------------------------------------------------------------
    bytes32[] public channelIds;
    mapping(bytes32 => bool) public exists;
    mapping(bytes32 => address) public channelToken; // address(0) for native, erc20 address otherwise
    mapping(bytes32 => uint256) public ghostDeposits; // sum across both peers
    mapping(bytes32 => uint256) public ghostWithdrawals; // sum across both peers

    // Cooperative-withdraw sequence numbers per channel (must be strictly
    // increasing across calls).
    mapping(bytes32 => uint256) public coopWithdrawSeq;

    // Bounds applied to fuzzed amounts. Kept small so a 100-step run can do many
    // ops without exhausting peer balances.
    uint256 internal constant MAX_OPEN_PER_PEER = 1 ether;
    uint256 internal constant MAX_DEPOSIT = 0.5 ether;
    uint256 internal constant MAX_WITHDRAW = 0.5 ether;
    uint256 internal constant DISPUTE_TIMEOUT = 20;
    // Per-call salt that varies the channel-id derivation so consecutive opens
    // by the same peer pair don't collide. The deadline itself is computed
    // relative to `block.timestamp` (which advances when `confirmWithdraw` /
    // `confirmSettle` warps forward), so we can't anchor it to a fixed cursor.
    uint256 internal openSalt;

    // Counters for the call-distribution observability invariant.
    mapping(bytes32 => uint256) public callsByName;

    constructor(
        AgentPayLedger _ledger,
        AgentPayWallet _wallet,
        NativeWrapMock _nativeWrap,
        ERC20ExampleToken _erc20,
        address _peer0,
        address _peer1,
        uint256 _peer0Pk,
        uint256 _peer1Pk
    ) {
        ledger = _ledger;
        wallet = _wallet;
        nativeWrap = _nativeWrap;
        erc20 = _erc20;
        peer0 = _peer0;
        peer1 = _peer1;
        peer0Pk = _peer0Pk;
        peer1Pk = _peer1Pk;
    }

    // -----------------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------------

    function channelCount() external view returns (uint256) {
        return channelIds.length;
    }

    function _pickChannel(uint256 _seed) internal view returns (bytes32) {
        if (channelIds.length == 0) return bytes32(0);
        return channelIds[_seed % channelIds.length];
    }

    /// @dev Top up peer native + wrapped-native balances if the next op would
    ///  underflow. `vm.deal` mints fresh ETH; `nativeWrap.deposit` wraps it.
    function _ensureNativeBalance(address _peer, uint256 _need) internal {
        if (_peer.balance < _need) vm.deal(_peer, _need + 1 ether);
        if (nativeWrap.balanceOf(_peer) < _need) {
            vm.deal(_peer, _peer.balance + _need);
            vm.prank(_peer);
            nativeWrap.deposit{value: _need}();
            vm.prank(_peer);
            nativeWrap.approve(address(ledger), type(uint256).max);
        }
    }

    /// @dev Top up peer ERC-20 balance + approval if the next op would underflow.
    ///  Foundry's `deal` cheatcode mints into an ERC-20's storage slot directly.
    function _ensureErc20Balance(address _peer, uint256 _need) internal {
        if (erc20.balanceOf(_peer) < _need) {
            deal(address(erc20), _peer, _need + 1 ether);
            vm.prank(_peer);
            erc20.approve(address(ledger), type(uint256).max);
        }
    }

    function _walletBalanceForChannel(bytes32 _id) internal view returns (uint256) {
        return wallet.balanceOf(_id, channelToken[_id]);
    }

    /// @dev Compute `confirmWithdraw`'s `withdrawLimit` for `_receiver` exactly
    ///  as the contract does, returning 0 when the formula would underflow.
    ///  Mirrors `LedgerOperation.confirmWithdraw`:
    ///    `deposit[rid] + transferOut[pid] - withdrawal[rid] - transferOut[rid] - pendingPayOut[rid]`.
    ///  The handler uses this to bound `intendWithdraw` and to skip
    ///  `confirmWithdraw` when intervening simplex updates have rendered the
    ///  pending intent's amount unredeemable.
    function _withdrawLimit(bytes32 _id, address _receiver) internal view returns (uint256) {
        (address[2] memory addrs, uint256[2] memory deps, uint256[2] memory wds) = ledger.getBalanceMap(_id);
        (, uint256[2] memory tos) = ledger.getTransferOutMap(_id);
        (, uint256[2] memory pos) = ledger.getPendingPayOutMap(_id);
        uint256 rid = (_receiver == addrs[0]) ? 0 : 1;
        uint256 pid = 1 - rid;
        uint256 plus = deps[rid] + tos[pid];
        uint256 minus = wds[rid] + tos[rid] + pos[rid];
        return plus > minus ? plus - minus : 0;
    }

    // -----------------------------------------------------------------------------
    // Action: openNativeChannel — peer0 funds via msg.value; peer1 via wrapped-native
    // -----------------------------------------------------------------------------
    function openNativeChannel(uint256 _amt0Seed, uint256 _amt1Seed) external {
        callsByName["openNativeChannel"]++;

        uint256 amt0 = _bound(_amt0Seed, 0, MAX_OPEN_PER_PEER);
        uint256 amt1 = _bound(_amt1Seed, 0, MAX_OPEN_PER_PEER);

        _ensureNativeBalance(peer0, amt0);
        _ensureNativeBalance(peer1, amt1);

        Fixtures.PaymentChannelInitializer memory init = Fixtures.PaymentChannelInitializer({
            tokenType: 1, // NATIVE
            tokenAddress: address(0),
            peers: [peer0, peer1],
            amounts: [amt0, amt1],
            openDeadline: block.timestamp + 1_000 + (openSalt++),
            disputeTimeout: DISPUTE_TIMEOUT,
            msgValueReceiver: 0,
            chainId: block.chainid,
            ledgerAddress: address(ledger)
        });
        bytes memory initializer = Fixtures.encPaymentChannelInitializer(init);
        bytes[] memory sigs = SignUtil.coSign(peer0Pk, peer1Pk, initializer);
        bytes memory request = Fixtures.encOpenChannelRequest(initializer, sigs);
        bytes32 id =
            keccak256(abi.encodePacked(block.chainid, address(wallet), address(ledger), keccak256(initializer)));

        vm.prank(peer0);
        ledger.openChannel{value: amt0}(request);

        channelIds.push(id);
        exists[id] = true;
        channelToken[id] = address(0);
        ghostDeposits[id] = amt0 + amt1;
    }

    // -----------------------------------------------------------------------------
    // Action: openErc20Channel — both peers fund via pre-approved ERC-20 transferFrom
    // -----------------------------------------------------------------------------
    function openErc20Channel(uint256 _amt0Seed, uint256 _amt1Seed) external {
        callsByName["openErc20Channel"]++;

        uint256 amt0 = _bound(_amt0Seed, 0, MAX_OPEN_PER_PEER);
        uint256 amt1 = _bound(_amt1Seed, 0, MAX_OPEN_PER_PEER);

        _ensureErc20Balance(peer0, amt0);
        _ensureErc20Balance(peer1, amt1);

        Fixtures.PaymentChannelInitializer memory init = Fixtures.PaymentChannelInitializer({
            tokenType: 2, // ERC20
            tokenAddress: address(erc20),
            peers: [peer0, peer1],
            amounts: [amt0, amt1],
            openDeadline: block.timestamp + 1_000 + (openSalt++),
            disputeTimeout: DISPUTE_TIMEOUT,
            // ERC-20 path requires msg.value == 0; the sentinel 0 is fine here too.
            msgValueReceiver: 0,
            chainId: block.chainid,
            ledgerAddress: address(ledger)
        });
        bytes memory initializer = Fixtures.encPaymentChannelInitializer(init);
        bytes[] memory sigs = SignUtil.coSign(peer0Pk, peer1Pk, initializer);
        bytes memory request = Fixtures.encOpenChannelRequest(initializer, sigs);
        bytes32 id =
            keccak256(abi.encodePacked(block.chainid, address(wallet), address(ledger), keccak256(initializer)));

        ledger.openChannel(request);

        channelIds.push(id);
        exists[id] = true;
        channelToken[id] = address(erc20);
        ghostDeposits[id] = amt0 + amt1;
    }

    // -----------------------------------------------------------------------------
    // Action: deposit — routes by channel token type
    // -----------------------------------------------------------------------------
    function deposit(uint256 _seed, uint256 _amtSeed, bool _toPeer0) external {
        if (channelIds.length == 0) return;
        callsByName["deposit"]++;
        bytes32 id = _pickChannel(_seed);
        if (uint256(ledger.getChannelStatus(id)) != uint256(LedgerStruct.ChannelStatus.Operable)) return;

        uint256 amount = _bound(_amtSeed, 1, MAX_DEPOSIT);
        address receiver = _toPeer0 ? peer0 : peer1;

        if (channelToken[id] == address(0)) {
            _ensureNativeBalance(receiver, amount);
            vm.prank(receiver);
            ledger.deposit{value: amount}(id, receiver, 0);
        } else {
            _ensureErc20Balance(receiver, amount);
            vm.prank(receiver);
            ledger.deposit(id, receiver, amount);
        }

        ghostDeposits[id] += amount;
    }

    // -----------------------------------------------------------------------------
    // Action: cooperativeWithdraw — single-tx co-signed in-channel withdraw
    // -----------------------------------------------------------------------------
    function cooperativeWithdraw(uint256 _seed, uint256 _amtSeed, bool _toPeer0) external {
        if (channelIds.length == 0) return;
        callsByName["cooperativeWithdraw"]++;
        bytes32 id = _pickChannel(_seed);
        if (uint256(ledger.getChannelStatus(id)) != uint256(LedgerStruct.ChannelStatus.Operable)) return;

        uint256 channelBal = _walletBalanceForChannel(id);
        if (channelBal == 0) return;

        uint256 amount = _bound(_amtSeed, 1, channelBal < MAX_WITHDRAW ? channelBal : MAX_WITHDRAW);
        address receiver = _toPeer0 ? peer0 : peer1;
        coopWithdrawSeq[id] += 1;

        Fixtures.CooperativeWithdrawInfo memory w = Fixtures.CooperativeWithdrawInfo({
            channelId: id,
            seqNum: coopWithdrawSeq[id],
            withdrawAccount: receiver,
            withdrawAmount: amount,
            withdrawDeadline: block.timestamp + 100,
            recipientChannelId: bytes32(0)
        });
        bytes memory body = Fixtures.encCooperativeWithdrawInfo(w);
        bytes[] memory sigs = SignUtil.coSign(peer0Pk, peer1Pk, body);
        bytes memory request = Fixtures.encCooperativeWithdrawRequest(body, sigs);

        ledger.cooperativeWithdraw(request);
        ghostWithdrawals[id] += amount;
    }

    // -----------------------------------------------------------------------------
    // Action: cooperativeSettle — co-signed close with arbitrary balance split
    // -----------------------------------------------------------------------------
    function cooperativeSettle(uint256 _seed, uint256 _splitSeed) external {
        if (channelIds.length == 0) return;
        callsByName["cooperativeSettle"]++;
        bytes32 id = _pickChannel(_seed);
        if (uint256(ledger.getChannelStatus(id)) != uint256(LedgerStruct.ChannelStatus.Operable)) return;

        uint256 channelBal = _walletBalanceForChannel(id);
        // cooperativeSettle requires sum(settleAmounts) == channelBal.
        uint256 a0 = _bound(_splitSeed, 0, channelBal);
        uint256 a1 = channelBal - a0;

        // seqNum just needs to be > both simplex seqNums; pick something safely large.
        uint256 settleSeq = type(uint64).max;

        Fixtures.CooperativeSettleInfo memory s = Fixtures.CooperativeSettleInfo({
            channelId: id,
            seqNum: settleSeq,
            settleAccounts: [peer0, peer1],
            settleAmounts: [a0, a1],
            settleDeadline: block.timestamp + 100
        });
        bytes memory body = Fixtures.encCooperativeSettleInfo(s);
        bytes[] memory sigs = SignUtil.coSign(peer0Pk, peer1Pk, body);
        bytes memory request = Fixtures.encCooperativeSettleRequest(body, sigs);

        ledger.cooperativeSettle(request);

        // cooperativeSettle drains the wallet but does NOT bump
        // `peerProfiles.withdrawal`. The contract reserves that counter for
        // `cooperativeWithdraw` / `confirmWithdraw` (in-channel withdrawals);
        // settle is a close-and-distribute, not a withdrawal in the accounting
        // sense. We don't touch `ghostWithdrawals` here — invariant 4 verifies
        // the wallet drains to zero on Closed.
    }

    // -----------------------------------------------------------------------------
    // Action: intendWithdraw — start unilateral challenge window
    // -----------------------------------------------------------------------------
    function intendWithdraw(uint256 _seed, uint256 _amtSeed, bool _byPeer0) external {
        if (channelIds.length == 0) return;
        callsByName["intendWithdraw"]++;
        bytes32 id = _pickChannel(_seed);
        if (uint256(ledger.getChannelStatus(id)) != uint256(LedgerStruct.ChannelStatus.Operable)) return;

        // Skip if there's already a pending intent (would revert).
        (address rcv,,,) = ledger.getWithdrawIntent(id);
        if (rcv != address(0)) return;

        // Bound by the receiver's actual `withdrawLimit` (as confirmWithdraw
        // computes it) so the eventual `confirmWithdraw` won't revert with
        // "Exceed withdraw limit" or underflow when intervening simplex
        // updates have shifted the position.
        address caller = _byPeer0 ? peer0 : peer1;
        uint256 limit = _withdrawLimit(id, caller);
        uint256 channelBal = _walletBalanceForChannel(id);
        uint256 cap = channelBal < limit ? channelBal : limit;
        if (cap > MAX_WITHDRAW) cap = MAX_WITHDRAW;
        if (cap == 0) return;
        uint256 amount = _bound(_amtSeed, 1, cap);

        vm.prank(caller);
        ledger.intendWithdraw(id, amount, bytes32(0));
    }

    // -----------------------------------------------------------------------------
    // Action: vetoWithdraw — counterparty cancels pending intent
    // -----------------------------------------------------------------------------
    function vetoWithdraw(uint256 _seed, bool _byPeer0) external {
        if (channelIds.length == 0) return;
        callsByName["vetoWithdraw"]++;
        bytes32 id = _pickChannel(_seed);
        if (uint256(ledger.getChannelStatus(id)) != uint256(LedgerStruct.ChannelStatus.Operable)) return;

        (address rcv,,,) = ledger.getWithdrawIntent(id);
        if (rcv == address(0)) return;

        address caller = _byPeer0 ? peer0 : peer1;
        vm.prank(caller);
        ledger.vetoWithdraw(id);
    }

    // -----------------------------------------------------------------------------
    // Action: confirmWithdraw — finalize after the dispute window
    // -----------------------------------------------------------------------------
    function confirmWithdraw(uint256 _seed) external {
        if (channelIds.length == 0) return;
        callsByName["confirmWithdraw"]++;
        bytes32 id = _pickChannel(_seed);
        if (uint256(ledger.getChannelStatus(id)) != uint256(LedgerStruct.ChannelStatus.Operable)) return;

        (address rcv, uint256 amt, uint256 reqTime,) = ledger.getWithdrawIntent(id);
        if (rcv == address(0)) return;

        // Skip if intervening ops have made the intent unredeemable. Two ways
        // this can happen:
        //   (a) intendSettle / snapshotStates moves transferOut, shifting the
        //       receiver's `withdrawLimit` formula below the pending amount;
        //   (b) cooperativeWithdraw drains the wallet to a different peer (the
        //       limit formula doesn't see this — it tracks per-peer accounting
        //       only), leaving wallet.balance < intent.amount.
        // Both pre-empt the contract's own revert under `fail_on_revert = true`.
        if (amt > _withdrawLimit(id, rcv)) return;
        if (amt > _walletBalanceForChannel(id)) return;

        // Warp forward; if reqTime + DISPUTE_TIMEOUT is already past, skip the warp.
        uint256 ready = reqTime + DISPUTE_TIMEOUT + 1;
        if (block.timestamp < ready) vm.warp(ready);

        ledger.confirmWithdraw(id);
        ghostWithdrawals[id] += amt;
    }

    // -----------------------------------------------------------------------------
    // Helpers for simplex-state (snapshotStates / intendSettle) actions.
    // -----------------------------------------------------------------------------

    /// @dev Build a co-signed `SignedSimplexState` for one peer-from direction.
    ///  Empty pay list (no pending pays); transferAmount is the cumulative
    ///  amount peerFrom has agreed to send the other peer.
    function _buildCoSignedSimplex(bytes32 _id, address _peerFrom, uint256 _seqNum, uint256 _transferAmount)
        internal
        view
        returns (bytes memory)
    {
        Fixtures.SimplexState memory s = Fixtures.SimplexState({
            channelId: _id,
            peerFrom: _peerFrom,
            seqNum: _seqNum,
            transferAmount: _transferAmount,
            pendingPayIds: bytes(""),
            payClearDeadline: 0,
            totalPendingAmount: 0
        });
        bytes memory simplex = Fixtures.encSimplexPaymentChannel(s);
        bytes[] memory sigs = SignUtil.coSign(peer0Pk, peer1Pk, simplex);
        return Fixtures.encSignedSimplexState(simplex, sigs);
    }

    /// @dev Look up the on-chain seqNum / transferOut for a given peer-from index.
    function _peerStateOf(bytes32 _id, address _peerFrom) internal view returns (uint256 seq, uint256 to) {
        (address[2] memory addrs, uint256[2] memory seqs) = ledger.getStateSeqNumMap(_id);
        (, uint256[2] memory tos) = ledger.getTransferOutMap(_id);
        uint256 idx = (_peerFrom == addrs[0]) ? 0 : 1;
        return (seqs[idx], tos[idx]);
    }

    // -----------------------------------------------------------------------------
    // Action: snapshotStates — checkpoint a simplex state without closing the channel
    // -----------------------------------------------------------------------------
    function snapshotStates(uint256 _seed, uint256 _seqSeed, uint256 _amtSeed, bool _byPeer0) external {
        if (channelIds.length == 0) return;
        callsByName["snapshotStates"]++;
        bytes32 id = _pickChannel(_seed);
        if (uint256(ledger.getChannelStatus(id)) != uint256(LedgerStruct.ChannelStatus.Operable)) return;

        address peerFrom = _byPeer0 ? peer0 : peer1;
        (uint256 currSeq, uint256 currTo) = _peerStateOf(id, peerFrom);

        // New seqNum must be strictly greater than on-chain.
        uint256 newSeq = currSeq + 1 + _bound(_seqSeed, 0, 100);

        // Bound the transferAmount delta by `peerFrom`'s current `withdrawLimit`.
        // Because increasing `peerFrom`'s `transferOut` reduces their own
        // limit by the same amount, capping delta at the current limit keeps
        // the post-update formula non-negative and prevents downstream
        // `confirmWithdraw` from underflowing.
        uint256 maxDelta = _withdrawLimit(id, peerFrom);
        uint256 newTo = currTo + _bound(_amtSeed, 0, maxDelta);

        bytes memory signed = _buildCoSignedSimplex(id, peerFrom, newSeq, newTo);
        bytes[] memory states = new bytes[](1);
        states[0] = signed;
        bytes memory wrapped = Fixtures.encSignedSimplexStateArray(states);

        ledger.snapshotStates(wrapped);
    }

    // -----------------------------------------------------------------------------
    // Action: intendSettle — start unilateral settlement window
    // -----------------------------------------------------------------------------
    function intendSettle(uint256 _seed, uint256 _seqSeed, uint256 _amtSeed, bool _byPeer0) external {
        if (channelIds.length == 0) return;
        callsByName["intendSettle"]++;
        bytes32 id = _pickChannel(_seed);
        uint256 status = uint256(ledger.getChannelStatus(id));
        if (
            status != uint256(LedgerStruct.ChannelStatus.Operable)
                && status != uint256(LedgerStruct.ChannelStatus.Settling)
        ) {
            return;
        }
        // intendSettle in Settling state requires block.timestamp < settleFinalizedTime;
        // skip the call after that window has closed (only confirmSettle is legal).
        if (status == uint256(LedgerStruct.ChannelStatus.Settling)) {
            uint256 sft = ledger.getSettleFinalizedTime(id);
            if (block.timestamp >= sft) return;
        }

        address peerFrom = _byPeer0 ? peer0 : peer1;
        (uint256 currSeq, uint256 currTo) = _peerStateOf(id, peerFrom);
        uint256 newSeq = currSeq + 1 + _bound(_seqSeed, 0, 100);

        // Same withdrawLimit-aware bound as `snapshotStates` — keeps any
        // pending `intendWithdraw` redeemable through the rebound branch.
        uint256 maxDelta = _withdrawLimit(id, peerFrom);
        uint256 newTo = currTo + _bound(_amtSeed, 0, maxDelta);

        bytes memory signed = _buildCoSignedSimplex(id, peerFrom, newSeq, newTo);
        bytes[] memory states = new bytes[](1);
        states[0] = signed;
        bytes memory wrapped = Fixtures.encSignedSimplexStateArray(states);

        // From Operable, only a peer may transition the channel into Settling
        // (the contract rejects "Nonpeer channel status error" otherwise).
        // From Settling, anyone may call intendSettle to update simplex state;
        // we still prank for consistency.
        vm.prank(_byPeer0 ? peer0 : peer1);
        ledger.intendSettle(wrapped);
    }

    // -----------------------------------------------------------------------------
    // Action: confirmSettle — finalize after the dispute window has elapsed
    // -----------------------------------------------------------------------------
    function confirmSettle(uint256 _seed) external {
        if (channelIds.length == 0) return;
        callsByName["confirmSettle"]++;
        bytes32 id = _pickChannel(_seed);
        if (uint256(ledger.getChannelStatus(id)) != uint256(LedgerStruct.ChannelStatus.Settling)) return;

        uint256 sft = ledger.getSettleFinalizedTime(id);
        if (block.timestamp < sft) vm.warp(sft + 1);

        ledger.confirmSettle(id);
        // The contract emits ConfirmSettle on success (Settling → Closed; wallet
        // drained) or ConfirmSettleFail on validation failure (Settling →
        // Operable rebound; wallet untouched). Either way, `peerProfiles.withdrawal`
        // is unchanged — same shape as cooperativeSettle, so we don't touch
        // `ghostWithdrawals`. Invariant 4 covers the Closed case (wallet == 0).
    }
}
