// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PayResolver} from "../src/PayResolver.sol";
import {PayRegistry} from "../src/PayRegistry.sol";
import {VirtContractResolver} from "../src/VirtContractResolver.sol";
import {BooleanCondMock} from "../src/helper/BooleanCondMock.sol";
import {NumericCondMock} from "../src/helper/NumericCondMock.sol";
import {Fixtures} from "./utils/Fixtures.sol";
import {SignUtil} from "./utils/SignUtil.sol";

/**
 * @title PayResolver tests
 * @notice Unit tests for on-chain conditional-payment resolution. Covers
 *  BOOLEAN_AND / BOOLEAN_OR + NUMERIC_ADD / NUMERIC_MAX / NUMERIC_MIN logic
 *  types over hash-lock and deployed/virtual condition contracts, vouched-result
 *  resolution, deadline / timeout reverts, and amount-monotonicity rules.
 *
 * @dev Sections:
 *  1. Resolve by conditions — boolean logic
 *  2. Resolve by vouched result
 *  3. Deadline / timeout reverts
 *  4. Hash-lock preimage failure
 *  5. Numeric logic (ADD / MAX / MIN)
 *  6. No-contract-condition shortcut (immediate finalization at max)
 *  7. Update amount → max collapses onchain deadline
 *  8. VIRTUAL_CONTRACT condition path
 *
 * @dev `_conditions(_type)` shorthands used by the tests below:
 *   - type 0: [hashLock, deployedFalse, deployedFalse]
 *   - type 1: [hashLock, deployedFalse, deployedTrue]
 *   - type 2: [hashLock, deployedTrue, deployedFalse]
 *   - type 3: [hashLock, deployedTrue, deployedTrue]
 *   - type 4: [hashLock, deployedTrue, hashLock]
 *   - type 5: [hashLock, numeric10, numeric25]
 *   - type 6: [hashLock]
 */
contract PayResolverTest is Test {
    PayResolver internal payResolver;
    PayRegistry internal payRegistry;
    VirtContractResolver internal virtResolver;
    BooleanCondMock internal boolMock;
    NumericCondMock internal numMock;

    // src / dest of conditional payments. Use deterministic keypairs so vouched
    // results can be co-signed.
    address internal payerSrc;
    uint256 internal payerSrcPk;
    address internal payerDest;
    uint256 internal payerDestPk;

    bytes internal constant TRUE_PREIMAGE = hex"123456";
    bytes internal constant FALSE_PREIMAGE = hex"654321";
    uint256 internal constant RESOLVE_TIMEOUT = 10;
    uint256 internal constant RESOLVE_DEADLINE = 9_999_999;

    // Note: only logic types 0, 1, 3, 4, 5 are implemented (BOOLEAN_AND,
    // BOOLEAN_OR, NUMERIC_ADD, NUMERIC_MAX, NUMERIC_MIN). BOOLEAN_CIRCUIT is reserved.

    event ResolvePayment(bytes32 indexed payId, uint256 amount, uint256 resolveDeadline);

    function setUp() public {
        // Anchor block.timestamp far above zero so deadline math like
        // `block.timestamp - 1` cannot underflow.
        vm.warp(1_000_000);

        virtResolver = new VirtContractResolver();
        payRegistry = new PayRegistry();
        payResolver = new PayResolver(address(payRegistry), address(virtResolver));
        boolMock = new BooleanCondMock();
        numMock = new NumericCondMock();

        (payerSrc, payerSrcPk) = makeAddrAndKey("payerSrc");
        (payerDest, payerDestPk) = makeAddrAndKey("payerDest");
    }

    // -------------------------------------------------------------------------
    // Helper builders
    // -------------------------------------------------------------------------

    function _hashLockTrue() internal pure returns (bytes32) {
        return keccak256(TRUE_PREIMAGE);
    }

    function _conditions(uint8 _type) internal view returns (Fixtures.Condition[] memory cs) {
        if (_type == 0) {
            cs = new Fixtures.Condition[](3);
            cs[0] = Fixtures.condHashLock(_hashLockTrue());
            cs[1] = Fixtures.condDeployedBoolean(address(boolMock), false);
            cs[2] = Fixtures.condDeployedBoolean(address(boolMock), false);
        } else if (_type == 1) {
            cs = new Fixtures.Condition[](3);
            cs[0] = Fixtures.condHashLock(_hashLockTrue());
            cs[1] = Fixtures.condDeployedBoolean(address(boolMock), false);
            cs[2] = Fixtures.condDeployedBoolean(address(boolMock), true);
        } else if (_type == 2) {
            cs = new Fixtures.Condition[](3);
            cs[0] = Fixtures.condHashLock(_hashLockTrue());
            cs[1] = Fixtures.condDeployedBoolean(address(boolMock), true);
            cs[2] = Fixtures.condDeployedBoolean(address(boolMock), false);
        } else if (_type == 3) {
            cs = new Fixtures.Condition[](3);
            cs[0] = Fixtures.condHashLock(_hashLockTrue());
            cs[1] = Fixtures.condDeployedBoolean(address(boolMock), true);
            cs[2] = Fixtures.condDeployedBoolean(address(boolMock), true);
        } else if (_type == 4) {
            cs = new Fixtures.Condition[](3);
            cs[0] = Fixtures.condHashLock(_hashLockTrue());
            cs[1] = Fixtures.condDeployedBoolean(address(boolMock), true);
            cs[2] = Fixtures.condHashLock(_hashLockTrue());
        } else if (_type == 5) {
            cs = new Fixtures.Condition[](3);
            cs[0] = Fixtures.condHashLock(_hashLockTrue());
            cs[1] = Fixtures.condDeployedNumeric(address(numMock), 10);
            cs[2] = Fixtures.condDeployedNumeric(address(numMock), 25);
        } else if (_type == 6) {
            cs = new Fixtures.Condition[](1);
            cs[0] = Fixtures.condHashLock(_hashLockTrue());
        } else {
            revert("unknown condition type");
        }
    }

    function _buildPay(
        uint256 _payTimestamp,
        uint8 _condType,
        uint256 _logicType,
        uint256 _maxAmount,
        uint256 _resolveDeadline
    ) internal view returns (bytes memory) {
        Fixtures.ConditionalPay memory pay = Fixtures.ConditionalPay({
            payTimestamp: _payTimestamp,
            src: payerSrc,
            dest: payerDest,
            conditions: _conditions(_condType),
            logicType: _logicType,
            maxAmount: _maxAmount,
            resolveDeadline: _resolveDeadline,
            resolveTimeout: RESOLVE_TIMEOUT,
            payResolver: address(payResolver),
            chainId: block.chainid
        });
        return Fixtures.encConditionalPay(pay);
    }

    function _resolveByConditions(bytes memory _payBytes, bytes memory _preimage) internal {
        bytes[] memory preimages = new bytes[](1);
        preimages[0] = _preimage;
        bytes memory request = Fixtures.encResolvePayByConditionsRequest(_payBytes, preimages);
        payResolver.resolvePaymentByConditions(request);
    }

    function _resolveByConditionsTwo(bytes memory _payBytes, bytes memory _preimage0, bytes memory _preimage1)
        internal
    {
        bytes[] memory preimages = new bytes[](2);
        preimages[0] = _preimage0;
        preimages[1] = _preimage1;
        bytes memory request = Fixtures.encResolvePayByConditionsRequest(_payBytes, preimages);
        payResolver.resolvePaymentByConditions(request);
    }

    function _vouched(bytes memory _payBytes, uint256 _amount) internal view returns (bytes memory) {
        bytes memory result = Fixtures.encCondPayResult(_payBytes, _amount);
        bytes memory sigSrc = SignUtil.sign(payerSrcPk, result);
        bytes memory sigDest = SignUtil.sign(payerDestPk, result);
        return Fixtures.encVouchedCondPayResult(result, sigSrc, sigDest);
    }

    function _payId(bytes memory _payBytes) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(keccak256(_payBytes), address(payResolver)));
    }

    // -------------------------------------------------------------------------
    // Resolve by conditions — boolean logic
    // -------------------------------------------------------------------------

    function test_resolveByConditions_booleanAnd_allTrue_resolvesToMax() public {
        bytes memory payBytes = _buildPay(1, 3, 0, 10, RESOLVE_DEADLINE);
        bytes32 expectedPayId = _payId(payBytes);

        vm.expectEmit(true, false, false, true, address(payResolver));
        emit ResolvePayment(expectedPayId, 10, block.timestamp);

        _resolveByConditions(payBytes, TRUE_PREIMAGE);
    }

    function test_resolveByConditions_booleanAnd_someFalse_resolvesToZero() public {
        bytes memory payBytes = _buildPay(2, 1, 0, 20, RESOLVE_DEADLINE);
        bytes32 expectedPayId = _payId(payBytes);

        vm.expectEmit(true, false, false, true, address(payResolver));
        emit ResolvePayment(expectedPayId, 0, block.timestamp + RESOLVE_TIMEOUT);

        _resolveByConditions(payBytes, TRUE_PREIMAGE);
    }

    function test_resolveByConditions_booleanOr_someTrue_resolvesToMax() public {
        bytes memory payBytes = _buildPay(3, 2, 1, 30, RESOLVE_DEADLINE);
        bytes32 expectedPayId = _payId(payBytes);

        vm.expectEmit(true, false, false, true, address(payResolver));
        emit ResolvePayment(expectedPayId, 30, block.timestamp);

        _resolveByConditions(payBytes, TRUE_PREIMAGE);
    }

    function test_resolveByConditions_booleanOr_allFalse_resolvesToZero() public {
        bytes memory payBytes = _buildPay(4, 0, 1, 30, RESOLVE_DEADLINE);
        bytes32 expectedPayId = _payId(payBytes);

        vm.expectEmit(true, false, false, true, address(payResolver));
        emit ResolvePayment(expectedPayId, 0, block.timestamp + RESOLVE_TIMEOUT);

        _resolveByConditions(payBytes, TRUE_PREIMAGE);
    }

    // -------------------------------------------------------------------------
    // Resolve by vouched result
    // -------------------------------------------------------------------------

    function test_resolveByVouchedResult_succeeds_setsAmountAndChallengeWindow() public {
        bytes memory payBytes = _buildPay(0, 5, 3, 100, RESOLVE_DEADLINE);
        bytes32 expectedPayId = _payId(payBytes);

        vm.expectEmit(true, false, false, true, address(payResolver));
        emit ResolvePayment(expectedPayId, 20, block.timestamp + RESOLVE_TIMEOUT);

        payResolver.resolvePaymentByVouchedResult(_vouched(payBytes, 20));
    }

    function test_resolveByVouchedResult_higherAmount_replacesPriorResult() public {
        bytes memory payBytes = _buildPay(0, 5, 3, 100, RESOLVE_DEADLINE);
        bytes32 expectedPayId = _payId(payBytes);

        // First resolve at 20 (deadline = N + RESOLVE_TIMEOUT).
        payResolver.resolvePaymentByVouchedResult(_vouched(payBytes, 20));
        uint256 firstDeadline = block.timestamp + RESOLVE_TIMEOUT;

        // Second resolve at 25; deadline must be unchanged because amount < max.
        vm.expectEmit(true, false, false, true, address(payResolver));
        emit ResolvePayment(expectedPayId, 25, firstDeadline);

        payResolver.resolvePaymentByVouchedResult(_vouched(payBytes, 25));
    }

    function test_resolveByConditions_higherAmount_replacesPriorResult() public {
        bytes memory payBytes = _buildPay(0, 5, 3, 100, RESOLVE_DEADLINE);
        bytes32 expectedPayId = _payId(payBytes);

        payResolver.resolvePaymentByVouchedResult(_vouched(payBytes, 20));
        uint256 firstDeadline = block.timestamp + RESOLVE_TIMEOUT;

        // NUMERIC_ADD over [hashLock, num10, num25] = 35. Higher than 20 → updates,
        // deadline preserved (still partial vs max=100).
        vm.expectEmit(true, false, false, true, address(payResolver));
        emit ResolvePayment(expectedPayId, 35, firstDeadline);

        _resolveByConditions(payBytes, TRUE_PREIMAGE);
    }

    function test_resolveByVouchedResult_lowerAmount_reverts() public {
        bytes memory payBytes = _buildPay(0, 5, 3, 100, RESOLVE_DEADLINE);

        payResolver.resolvePaymentByVouchedResult(_vouched(payBytes, 20));
        // Now the on-chain amount is 20. A vouched result with lower amount must revert.
        // Resolve via conditions to bump to 35 first, then try a vouched 30:
        _resolveByConditions(payBytes, TRUE_PREIMAGE);

        vm.expectRevert(bytes("New amount is not larger"));
        payResolver.resolvePaymentByVouchedResult(_vouched(payBytes, 30));
    }

    function test_resolveByVouchedResult_exceedingMax_reverts() public {
        bytes memory payBytes = _buildPay(0, 5, 3, 100, RESOLVE_DEADLINE);

        vm.expectRevert(bytes("Exceed max transfer amount"));
        payResolver.resolvePaymentByVouchedResult(_vouched(payBytes, 200));
    }

    // -------------------------------------------------------------------------
    // Deadline / timeout reverts
    // -------------------------------------------------------------------------

    function test_resolveByConditions_pastResolveDeadline_reverts() public {
        // resolveDeadline already in the past.
        bytes memory payBytes = _buildPay(5, 1, 0, 10, block.timestamp - 1);

        vm.expectRevert(bytes("Passed pay resolve deadline in condPay msg"));
        _resolveByConditions(payBytes, TRUE_PREIMAGE);
    }

    function test_resolveByVouchedResult_pastResolveDeadline_reverts() public {
        bytes memory payBytes = _buildPay(6, 1, 0, 100, block.timestamp - 1);

        vm.expectRevert(bytes("Passed pay resolve deadline in condPay msg"));
        payResolver.resolvePaymentByVouchedResult(_vouched(payBytes, 20));
    }

    function test_resolveByVouchedResult_pastOnchainDeadline_reverts() public {
        bytes memory payBytes = _buildPay(7, 1, 0, 100, RESOLVE_DEADLINE);

        // First resolve sets onchain deadline to N + RESOLVE_TIMEOUT.
        payResolver.resolvePaymentByVouchedResult(_vouched(payBytes, 20));

        // Roll past the onchain resolve deadline.
        vm.warp(block.timestamp + RESOLVE_TIMEOUT + 1);

        vm.expectRevert(bytes("Passed onchain resolve pay deadline"));
        payResolver.resolvePaymentByVouchedResult(_vouched(payBytes, 30));
    }

    function test_resolveByConditions_pastOnchainDeadline_reverts() public {
        bytes memory payBytes = _buildPay(8, 1, 0, 200, RESOLVE_DEADLINE);

        payResolver.resolvePaymentByVouchedResult(_vouched(payBytes, 20));
        vm.warp(block.timestamp + RESOLVE_TIMEOUT + 1);

        vm.expectRevert(bytes("Passed onchain resolve pay deadline"));
        _resolveByConditions(payBytes, TRUE_PREIMAGE);
    }

    // -------------------------------------------------------------------------
    // Hash-lock failure
    // -------------------------------------------------------------------------

    function test_resolveByConditions_falseHashLock_reverts() public {
        // type 4: [hashLock, deployedTrue, hashLock]
        bytes memory payBytes = _buildPay(9, 4, 1, 200, RESOLVE_DEADLINE);

        vm.expectRevert(bytes("Wrong preimage"));
        _resolveByConditionsTwo(payBytes, TRUE_PREIMAGE, FALSE_PREIMAGE);
    }

    // -------------------------------------------------------------------------
    // Dependent-contract not-finalized failure
    // -------------------------------------------------------------------------

    /// @dev Build a ConditionalPay containing a single deployed-contract condition
    ///  pointing at `_addr`, with explicit `argsQueryFinalization` so the new
    ///  unified mocks can simulate `isFinalized = false`. Used by the
    ///  not-finalized revert tests below.
    function _buildPaySingleDeployed(
        uint256 _payTimestamp,
        address _addr,
        uint256 _logicType,
        bytes memory _argsFinalization,
        bytes memory _argsOutcome
    ) internal view returns (bytes memory) {
        Fixtures.Condition[] memory conds = new Fixtures.Condition[](1);
        conds[0].conditionType = 1; // DEPLOYED_CONTRACT
        conds[0].deployedAddress = _addr;
        conds[0].argsQueryFinalization = _argsFinalization;
        conds[0].argsQueryOutcome = _argsOutcome;

        Fixtures.ConditionalPay memory pay = Fixtures.ConditionalPay({
            payTimestamp: _payTimestamp,
            src: payerSrc,
            dest: payerDest,
            conditions: conds,
            logicType: _logicType,
            maxAmount: 50,
            resolveDeadline: RESOLVE_DEADLINE,
            resolveTimeout: RESOLVE_TIMEOUT,
            payResolver: address(payResolver),
            chainId: block.chainid
        });
        return Fixtures.encConditionalPay(pay);
    }

    /// @dev `isFinalized` query byte that the unified mocks decode as `false`.
    bytes internal constant NOT_FINALIZED_QUERY = hex"00";

    function test_resolveByConditions_booleanAnd_dependentNotFinalized_reverts() public {
        // BOOLEAN_AND with a single deployed-contract condition where
        // argsQueryFinalization decodes to `false`.
        bytes memory payBytes =
            _buildPaySingleDeployed(20, address(boolMock), 0, NOT_FINALIZED_QUERY, abi.encodePacked(bytes1(0x01)));

        bytes[] memory preimages = new bytes[](0);
        vm.expectRevert(bytes("Condition is not finalized"));
        payResolver.resolvePaymentByConditions(Fixtures.encResolvePayByConditionsRequest(payBytes, preimages));
    }

    function test_resolveByConditions_booleanOr_dependentNotFinalized_reverts() public {
        // BOOLEAN_OR with the same shape.
        bytes memory payBytes =
            _buildPaySingleDeployed(21, address(boolMock), 1, NOT_FINALIZED_QUERY, abi.encodePacked(bytes1(0x01)));

        bytes[] memory preimages = new bytes[](0);
        vm.expectRevert(bytes("Condition is not finalized"));
        payResolver.resolvePaymentByConditions(Fixtures.encResolvePayByConditionsRequest(payBytes, preimages));
    }

    function test_resolveByConditions_numericLogic_dependentNotFinalized_reverts() public {
        // NUMERIC_ADD with a numeric condition where argsQueryFinalization decodes to `false`.
        bytes memory payBytes =
            _buildPaySingleDeployed(22, address(numMock), 3, NOT_FINALIZED_QUERY, abi.encodePacked(uint8(10)));

        bytes[] memory preimages = new bytes[](0);
        vm.expectRevert(bytes("Condition is not finalized"));
        payResolver.resolvePaymentByConditions(Fixtures.encResolvePayByConditionsRequest(payBytes, preimages));
    }

    // -------------------------------------------------------------------------
    // Wrong chain id (replay protection)
    // -------------------------------------------------------------------------

    /// @dev Build a hash-lock-only ConditionalPay with an explicit `chainId`
    ///  override. Used by the wrong-chain-id revert tests below.
    function _buildPayWithChainId(uint256 _payTimestamp, uint256 _chainId) internal view returns (bytes memory) {
        Fixtures.Condition[] memory conds = new Fixtures.Condition[](1);
        conds[0] = Fixtures.condHashLock(_hashLockTrue());

        Fixtures.ConditionalPay memory pay = Fixtures.ConditionalPay({
            payTimestamp: _payTimestamp,
            src: payerSrc,
            dest: payerDest,
            conditions: conds,
            logicType: 0, // BOOLEAN_AND
            maxAmount: 50,
            resolveDeadline: RESOLVE_DEADLINE,
            resolveTimeout: RESOLVE_TIMEOUT,
            payResolver: address(payResolver),
            chainId: _chainId
        });
        return Fixtures.encConditionalPay(pay);
    }

    function test_resolveByConditions_wrongChainId_reverts() public {
        // Pay is bound to a chainid one greater than the current chain.
        bytes memory payBytes = _buildPayWithChainId(30, block.chainid + 1);

        bytes[] memory preimages = new bytes[](1);
        preimages[0] = TRUE_PREIMAGE;
        vm.expectRevert(bytes("Wrong chain id for pay"));
        payResolver.resolvePaymentByConditions(Fixtures.encResolvePayByConditionsRequest(payBytes, preimages));
    }

    function test_resolveByVouchedResult_wrongChainId_reverts() public {
        // Same wrong-chainid pay submitted via the vouched-result path.
        bytes memory payBytes = _buildPayWithChainId(31, block.chainid + 1);

        vm.expectRevert(bytes("Wrong chain id for pay"));
        payResolver.resolvePaymentByVouchedResult(_vouched(payBytes, 20));
    }

    // -------------------------------------------------------------------------
    // Numeric logic
    // -------------------------------------------------------------------------

    function test_resolveByConditions_numericAdd_sumsOutcomes() public {
        bytes memory payBytes = _buildPay(10, 5, 3, 50, RESOLVE_DEADLINE);
        bytes32 expectedPayId = _payId(payBytes);

        vm.expectEmit(true, false, false, true, address(payResolver));
        emit ResolvePayment(expectedPayId, 35, block.timestamp + RESOLVE_TIMEOUT);

        _resolveByConditions(payBytes, TRUE_PREIMAGE);
    }

    function test_resolveByConditions_numericMax_picksHighest() public {
        bytes memory payBytes = _buildPay(11, 5, 4, 50, RESOLVE_DEADLINE);
        bytes32 expectedPayId = _payId(payBytes);

        vm.expectEmit(true, false, false, true, address(payResolver));
        emit ResolvePayment(expectedPayId, 25, block.timestamp + RESOLVE_TIMEOUT);

        _resolveByConditions(payBytes, TRUE_PREIMAGE);
    }

    function test_resolveByConditions_numericMin_picksLowest() public {
        bytes memory payBytes = _buildPay(12, 5, 5, 50, RESOLVE_DEADLINE);
        bytes32 expectedPayId = _payId(payBytes);

        vm.expectEmit(true, false, false, true, address(payResolver));
        emit ResolvePayment(expectedPayId, 10, block.timestamp + RESOLVE_TIMEOUT);

        _resolveByConditions(payBytes, TRUE_PREIMAGE);
    }

    // -------------------------------------------------------------------------
    // No contract conditions → max amount + immediate finalization
    // -------------------------------------------------------------------------

    function test_resolveByConditions_hashLockOnly_resolvesToMax_anyLogic() public {
        // BOOLEAN_CIRCUIT (logicType=2) is reserved/unimplemented; skip it.
        uint256[5] memory logicTypes = [uint256(0), 1, 3, 4, 5];

        for (uint256 i = 0; i < logicTypes.length; i++) {
            bytes memory payBytes = _buildPay(100 + i, 6, logicTypes[i], 50, RESOLVE_DEADLINE);
            bytes32 expectedPayId = _payId(payBytes);

            vm.expectEmit(true, false, false, true, address(payResolver));
            emit ResolvePayment(expectedPayId, 50, block.timestamp);

            _resolveByConditions(payBytes, TRUE_PREIMAGE);
        }
    }

    // -------------------------------------------------------------------------
    // Updating amount = max sets onchain deadline to current timestamp
    // -------------------------------------------------------------------------

    function test_updatedAmountEqualsMax_setsOnchainDeadlineToCurrentTimestamp() public {
        bytes memory payBytes = _buildPay(0, 5, 3, 35, RESOLVE_DEADLINE); // max = 35
        bytes32 expectedPayId = _payId(payBytes);

        // First: vouched 20 → partial, deadline = timestamp + timeout.
        payResolver.resolvePaymentByVouchedResult(_vouched(payBytes, 20));

        // Second: resolve by conditions → 35 (= max). Deadline must collapse to
        // current timestamp.
        vm.warp(block.timestamp + 2);
        vm.expectEmit(true, false, false, true, address(payResolver));
        emit ResolvePayment(expectedPayId, 35, block.timestamp);

        _resolveByConditions(payBytes, TRUE_PREIMAGE);
    }

    // -------------------------------------------------------------------------
    // VIRTUAL_CONTRACT condition path
    // -------------------------------------------------------------------------

    function test_resolveByConditions_virtualContract_resolvesToMax() public {
        // Deploy a BooleanCondMock at a deterministic "virtual address" via
        // VirtContractResolver. The mock decodes its outcome from the query bytes.
        bytes memory mockBytecode = type(BooleanCondMock).creationCode;
        uint256 nonce = 12345;
        bytes32 virtAddr = keccak256(abi.encodePacked(mockBytecode, nonce));
        virtResolver.deploy(mockBytecode, nonce);

        // Build a ConditionalPay whose only condition is a VIRTUAL_CONTRACT
        // condition with outcome=true. With BOOLEAN_AND, this resolves to max.
        Fixtures.Condition[] memory conds = new Fixtures.Condition[](1);
        conds[0] = Fixtures.condVirtual(virtAddr, abi.encodePacked(bytes1(0x01)));

        Fixtures.ConditionalPay memory pay = Fixtures.ConditionalPay({
            payTimestamp: 1,
            src: payerSrc,
            dest: payerDest,
            conditions: conds,
            logicType: 0, // BOOLEAN_AND
            maxAmount: 50,
            resolveDeadline: RESOLVE_DEADLINE,
            resolveTimeout: RESOLVE_TIMEOUT,
            payResolver: address(payResolver),
            chainId: block.chainid
        });
        bytes memory payBytes = Fixtures.encConditionalPay(pay);
        bytes32 expectedPayId = keccak256(abi.encodePacked(keccak256(payBytes), address(payResolver)));

        bytes[] memory preimages = new bytes[](0);
        vm.expectEmit(true, false, false, true, address(payResolver));
        emit ResolvePayment(expectedPayId, 50, block.timestamp);

        payResolver.resolvePaymentByConditions(Fixtures.encResolvePayByConditionsRequest(payBytes, preimages));

        (uint256 amount, uint256 deadline) = payRegistry.getPayInfo(expectedPayId);
        assertEq(amount, 50);
        assertEq(deadline, block.timestamp);
    }
}
