// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Proto} from "./Proto.sol";
import {Fixtures} from "./Fixtures.sol";
import {PbEntity} from "../../src/lib/data/PbEntity.sol";
import {PbChain} from "../../src/lib/data/PbChain.sol";

/**
 * @title Proto encoder round-trip tests
 * @notice Validates that {Fixtures} encoders produce wire-format output that the
 *  existing `PbEntity` / `PbChain` decoders accept and round-trip without loss.
 *  These tests are the gold-standard correctness check for the test infrastructure.
 */
contract ProtoTest is Test {
    function test_encAccountAmtPair_roundTrips() public pure {
        address account = address(0x1234567890123456789012345678901234567890);
        uint256 amt = 0x1122334455;

        bytes memory encoded = Fixtures.encAccountAmtPair(account, amt);
        PbEntity.AccountAmtPair memory decoded = PbEntity.decAccountAmtPair(encoded);

        assertEq(decoded.account, account, "account");
        assertEq(decoded.amt, amt, "amt");
    }

    function test_encAccountAmtPair_zeroAmt_roundTrips() public pure {
        address account = address(0xdead);
        bytes memory encoded = Fixtures.encAccountAmtPair(account, 0);
        PbEntity.AccountAmtPair memory decoded = PbEntity.decAccountAmtPair(encoded);

        assertEq(decoded.account, account);
        assertEq(decoded.amt, 0);
    }

    function test_encTokenInfo_eth_roundTrips() public pure {
        bytes memory encoded = Fixtures.encTokenInfo(1, address(0));
        PbEntity.TokenInfo memory decoded = PbEntity.decTokenInfo(encoded);

        assertEq(uint256(decoded.tokenType), 1);
        assertEq(decoded.tokenAddress, address(0));
    }

    function test_encTokenInfo_erc20_roundTrips() public pure {
        address token = address(0x9999999999999999999999999999999999999999);
        bytes memory encoded = Fixtures.encTokenInfo(2, token);
        PbEntity.TokenInfo memory decoded = PbEntity.decTokenInfo(encoded);

        assertEq(uint256(decoded.tokenType), 2);
        assertEq(decoded.tokenAddress, token);
    }

    function test_encConditionalPay_roundTrips() public pure {
        address src = address(0x1111111111111111111111111111111111111111);
        address dest = address(0x2222222222222222222222222222222222222222);
        address payResolver = address(0x3333333333333333333333333333333333333333);

        Fixtures.Condition[] memory conds = new Fixtures.Condition[](1);
        conds[0] = Fixtures.condHashLock(keccak256("preimage"));

        Fixtures.ConditionalPay memory pay = Fixtures.ConditionalPay({
            payTimestamp: 12345,
            src: src,
            dest: dest,
            conditions: conds,
            logicType: 0, // BOOLEAN_AND
            maxAmount: 1000,
            resolveDeadline: 999999,
            resolveTimeout: 5,
            payResolver: payResolver
        });

        bytes memory encoded = Fixtures.encConditionalPay(pay);
        PbEntity.ConditionalPay memory decoded = PbEntity.decConditionalPay(encoded);

        assertEq(decoded.payTimestamp, 12345);
        assertEq(decoded.src, src);
        assertEq(decoded.dest, dest);
        assertEq(decoded.conditions.length, 1);
        assertEq(uint256(decoded.conditions[0].conditionType), 0); // HASH_LOCK
        assertEq(decoded.conditions[0].hashLock, keccak256("preimage"));
        assertEq(uint256(decoded.transferFunc.logicType), 0);
        assertEq(decoded.transferFunc.maxTransfer.receiver.amt, 1000);
        assertEq(decoded.resolveDeadline, 999999);
        assertEq(decoded.resolveTimeout, 5);
        assertEq(decoded.payResolver, payResolver);
    }

    function test_encConditionalPay_multipleConditions_roundTrips() public pure {
        Fixtures.Condition[] memory conds = new Fixtures.Condition[](3);
        conds[0] = Fixtures.condHashLock(bytes32(uint256(0xabc)));
        conds[1] = Fixtures.condDeployedBoolean(address(0x4444), true);
        conds[2] = Fixtures.condDeployedNumeric(address(0x5555), 42);

        Fixtures.ConditionalPay memory pay = Fixtures.ConditionalPay({
            payTimestamp: 1,
            src: address(0xa),
            dest: address(0xb),
            conditions: conds,
            logicType: 1, // BOOLEAN_OR
            maxAmount: 999,
            resolveDeadline: 100,
            resolveTimeout: 5,
            payResolver: address(0xc)
        });

        bytes memory encoded = Fixtures.encConditionalPay(pay);
        PbEntity.ConditionalPay memory decoded = PbEntity.decConditionalPay(encoded);

        assertEq(decoded.conditions.length, 3);
        assertEq(uint256(decoded.conditions[0].conditionType), 0);
        assertEq(decoded.conditions[0].hashLock, bytes32(uint256(0xabc)));
        assertEq(uint256(decoded.conditions[1].conditionType), 1);
        assertEq(decoded.conditions[1].deployedContractAddress, address(0x4444));
        assertEq(decoded.conditions[1].argsQueryOutcome.length, 1);
        assertEq(uint8(decoded.conditions[1].argsQueryOutcome[0]), 1);
        assertEq(uint256(decoded.conditions[2].conditionType), 1);
        assertEq(decoded.conditions[2].deployedContractAddress, address(0x5555));
        assertEq(uint8(decoded.conditions[2].argsQueryOutcome[0]), 42);
    }

    function test_encPayIdList_roundTrips() public pure {
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = bytes32(uint256(1));
        ids[1] = bytes32(uint256(2));

        bytes memory encoded = Fixtures.encPayIdList(ids, bytes32(uint256(0xdeadbeef)));
        PbEntity.PayIdList memory decoded = PbEntity.decPayIdList(encoded);

        assertEq(decoded.payIds.length, 2);
        assertEq(decoded.payIds[0], bytes32(uint256(1)));
        assertEq(decoded.payIds[1], bytes32(uint256(2)));
        assertEq(decoded.nextListHash, bytes32(uint256(0xdeadbeef)));
    }

    function test_encSimplexPaymentChannel_roundTrips() public pure {
        Fixtures.SimplexState memory s = Fixtures.SimplexState({
            channelId: bytes32(uint256(0x1234)),
            peerFrom: address(0xaaaa),
            seqNum: 7,
            transferAmount: 500,
            pendingPayIds: bytes(""),
            lastPayResolveDeadline: 100,
            totalPendingAmount: 0
        });

        bytes memory encoded = Fixtures.encSimplexPaymentChannel(s);
        PbEntity.SimplexPaymentChannel memory decoded = PbEntity.decSimplexPaymentChannel(encoded);

        assertEq(decoded.channelId, bytes32(uint256(0x1234)));
        assertEq(decoded.peerFrom, address(0xaaaa));
        assertEq(decoded.seqNum, 7);
        assertEq(decoded.transferToPeer.receiver.amt, 500);
        assertEq(decoded.lastPayResolveDeadline, 100);
        assertEq(decoded.totalPendingAmount, 0);
    }

    function test_encPaymentChannelInitializer_eth_roundTrips() public pure {
        Fixtures.PaymentChannelInitializer memory init = Fixtures.PaymentChannelInitializer({
            tokenType: 1,
            tokenAddress: address(0),
            peers: [address(0x1), address(0x2)],
            amounts: [uint256(100), uint256(200)],
            openDeadline: 999999,
            disputeTimeout: 10,
            msgValueReceiver: 0
        });

        bytes memory encoded = Fixtures.encPaymentChannelInitializer(init);
        PbEntity.PaymentChannelInitializer memory decoded = PbEntity.decPaymentChannelInitializer(encoded);

        assertEq(uint256(decoded.initDistribution.token.tokenType), 1);
        assertEq(decoded.initDistribution.distribution.length, 2);
        assertEq(decoded.initDistribution.distribution[0].account, address(0x1));
        assertEq(decoded.initDistribution.distribution[0].amt, 100);
        assertEq(decoded.initDistribution.distribution[1].account, address(0x2));
        assertEq(decoded.initDistribution.distribution[1].amt, 200);
        assertEq(decoded.openDeadline, 999999);
        assertEq(decoded.disputeTimeout, 10);
        assertEq(decoded.msgValueReceiver, 0);
    }

    function test_encOpenChannelRequest_roundTrips() public pure {
        bytes memory body = hex"deadbeef";
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = hex"aaaa";
        sigs[1] = hex"bbbb";

        bytes memory encoded = Fixtures.encOpenChannelRequest(body, sigs);
        PbChain.OpenChannelRequest memory decoded = PbChain.decOpenChannelRequest(encoded);

        assertEq(decoded.channelInitializer, body);
        assertEq(decoded.sigs.length, 2);
        assertEq(decoded.sigs[0], hex"aaaa");
        assertEq(decoded.sigs[1], hex"bbbb");
    }

    function test_encCooperativeWithdrawInfo_roundTrips() public pure {
        Fixtures.CooperativeWithdrawInfo memory w = Fixtures.CooperativeWithdrawInfo({
            channelId: bytes32(uint256(0xc0ffee)),
            seqNum: 1,
            withdrawAccount: address(0xfeed),
            withdrawAmount: 50,
            withdrawDeadline: 9999999,
            recipientChannelId: bytes32(0)
        });

        bytes memory encoded = Fixtures.encCooperativeWithdrawInfo(w);
        PbEntity.CooperativeWithdrawInfo memory decoded = PbEntity.decCooperativeWithdrawInfo(encoded);

        assertEq(decoded.channelId, bytes32(uint256(0xc0ffee)));
        assertEq(decoded.seqNum, 1);
        assertEq(decoded.withdraw.account, address(0xfeed));
        assertEq(decoded.withdraw.amt, 50);
        assertEq(decoded.withdrawDeadline, 9999999);
        assertEq(decoded.recipientChannelId, bytes32(0));
    }

    function test_encVouchedCondPayResult_roundTrips() public pure {
        bytes memory result = hex"0102030405";
        bytes memory sigSrc = hex"a1a2";
        bytes memory sigDest = hex"b1b2";

        bytes memory encoded = Fixtures.encVouchedCondPayResult(result, sigSrc, sigDest);
        PbEntity.VouchedCondPayResult memory decoded = PbEntity.decVouchedCondPayResult(encoded);

        assertEq(decoded.condPayResult, result);
        assertEq(decoded.sigOfSrc, sigSrc);
        assertEq(decoded.sigOfDest, sigDest);
    }

    function test_encResolvePayByConditionsRequest_roundTrips() public pure {
        bytes memory condPay = hex"112233";
        bytes[] memory preimages = new bytes[](2);
        preimages[0] = hex"a0";
        preimages[1] = hex"b0";

        bytes memory encoded = Fixtures.encResolvePayByConditionsRequest(condPay, preimages);
        PbChain.ResolvePayByConditionsRequest memory decoded = PbChain.decResolvePayByConditionsRequest(encoded);

        assertEq(decoded.condPay, condPay);
        assertEq(decoded.hashPreimages.length, 2);
        assertEq(decoded.hashPreimages[0], hex"a0");
        assertEq(decoded.hashPreimages[1], hex"b0");
    }

    function test_uint256ToBytes_handlesZero() public pure {
        bytes memory b = Proto.uint256ToBytes(0);
        assertEq(b.length, 1);
        assertEq(uint8(b[0]), 0);
    }

    function test_uint256ToBytes_strippLeadingZeros() public pure {
        bytes memory b = Proto.uint256ToBytes(0x123);
        assertEq(b.length, 2);
        assertEq(uint8(b[0]), 0x01);
        assertEq(uint8(b[1]), 0x23);
    }

    function test_uint256ToBytes_max() public pure {
        bytes memory b = Proto.uint256ToBytes(type(uint256).max);
        assertEq(b.length, 32);
        for (uint256 i = 0; i < 32; i++) {
            assertEq(uint8(b[i]), 0xff);
        }
    }
}
