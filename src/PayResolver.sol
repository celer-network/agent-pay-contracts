// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./lib/data/PbChain.sol";
import "./lib/data/PbEntity.sol";
import "./interfaces/IPayRegistry.sol";
import "./interfaces/IPayResolver.sol";
import "./interfaces/IBooleanCond.sol";
import "./interfaces/INumericCond.sol";
import "./interfaces/IVirtContractResolver.sol";
import "./lib/AgentPayErrors.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title PayResolver
 * @notice On-chain logic for resolving conditional payments. Versioned: each payment
 *  pins the resolver address it trusts (field 8 of `ConditionalPay`), and the resolver
 *  address is mixed into the pay id (`payId = keccak256(payHash, resolverAddress)`)
 *  so a result is bound to the exact resolver version the payment source designated.
 * @dev See {IPayResolver} for canonical NatSpec on the external API. Resolution rules:
 *  HASH_LOCK conditions are present only to gate multi-hop secret reveal — they do not
 *  affect the transfer amount, and are always required to be true. A payment with no
 *  condition or only true hash-locks resolves to the max transfer amount.
 */
contract PayResolver is IPayResolver {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    /// @notice Registry where resolved amounts are recorded.
    IPayRegistry public payRegistry;

    /// @notice Resolver used to materialize virtual condition contracts on demand.
    IVirtContractResolver public virtResolver;

    /**
     * @notice Construct the resolver and pin its dependencies.
     * @param _registryAddr Address of the deployed {IPayRegistry}.
     * @param _virtResolverAddr Address of the deployed {IVirtContractResolver}.
     */
    constructor(address _registryAddr, address _virtResolverAddr) {
        payRegistry = IPayRegistry(_registryAddr);
        virtResolver = IVirtContractResolver(_virtResolverAddr);
    }

    /// @inheritdoc IPayResolver
    function resolvePaymentByConditions(bytes calldata _resolvePayRequest) external {
        PbChain.ResolvePayByConditionsRequest memory resolvePayRequest =
            PbChain.decResolvePayByConditionsRequest(_resolvePayRequest);
        PbEntity.ConditionalPay memory pay = PbEntity.decConditionalPay(resolvePayRequest.condPay);

        // onchain resolve this payment and get result
        uint256 amount;
        PbEntity.TransferFunctionType funcType = pay.transferFunc.logicType;
        if (funcType == PbEntity.TransferFunctionType.BOOLEAN_AND) {
            amount = _calculateBooleanAndPayment(pay, resolvePayRequest.hashPreimages);
        } else if (funcType == PbEntity.TransferFunctionType.BOOLEAN_OR) {
            amount = _calculateBooleanOrPayment(pay, resolvePayRequest.hashPreimages);
        } else if (_isNumericLogic(funcType)) {
            amount = _calculateNumericLogicPayment(pay, resolvePayRequest.hashPreimages, funcType);
        } else {
            // TODO: support more transfer function types
            assert(false);
        }

        bytes32 payHash = keccak256(resolvePayRequest.condPay);
        _resolvePayment(pay, payHash, amount);
    }

    /// @inheritdoc IPayResolver
    function resolvePaymentByVouchedResult(bytes calldata _vouchedPayResult) external {
        PbEntity.VouchedCondPayResult memory vouchedPayResult = PbEntity.decVouchedCondPayResult(_vouchedPayResult);
        PbEntity.CondPayResult memory payResult = PbEntity.decCondPayResult(vouchedPayResult.condPayResult);
        PbEntity.ConditionalPay memory pay = PbEntity.decConditionalPay(payResult.condPay);

        require(
            payResult.amount <= pay.transferFunc.maxTransfer.receiver.amt,
            AgentPayErrors.MaxTransferExceeded(payResult.amount, pay.transferFunc.maxTransfer.receiver.amt)
        );
        // check signatures
        bytes32 hash = keccak256(vouchedPayResult.condPayResult).toEthSignedMessageHash();
        address recoveredSrc = hash.recover(vouchedPayResult.sigOfSrc);
        address recoveredDest = hash.recover(vouchedPayResult.sigOfDest);
        require(
            recoveredSrc == address(pay.src) && recoveredDest == address(pay.dest), AgentPayErrors.InvalidCoSignatures()
        );

        bytes32 payHash = keccak256(payResult.condPay);
        _resolvePayment(pay, payHash, payResult.amount);
    }

    /**
     * @notice Internal function of resolving a payment with given amount
     * @param _pay conditional pay
     * @param _payHash hash of serialized condPay
     * @param _amount payment amount to resolve
     */
    function _resolvePayment(PbEntity.ConditionalPay memory _pay, bytes32 _payHash, uint256 _amount) internal {
        // bind the signed pay to its intended (chain, resolver) target
        require(_pay.chainId == block.chainid, AgentPayErrors.ChainIdMismatch(block.chainid, _pay.chainId));
        require(_pay.payResolver == address(this), AgentPayErrors.ResolverAddressMismatch());
        uint256 nowTs = block.timestamp;
        require(nowTs <= _pay.resolveDeadline, AgentPayErrors.DeadlinePassed());

        bytes32 payId = _calculatePayId(_payHash, address(this));
        (uint256 currentAmt, uint256 currentDeadline) = payRegistry.getPayInfo(payId);

        // If a prior on-chain resolution exists (`currentDeadline > 0`), updates
        // are only accepted while the registry's stored deadline has not yet
        // passed. First-time resolution (`currentDeadline == 0`) always passes.
        require(currentDeadline == 0 || nowTs <= currentDeadline, AgentPayErrors.ResolveUpdateWindowClosed());

        if (currentDeadline > 0) {
            // currentDeadline > 0 implies that this pay has been updated
            // payment amount must be monotone increasing
            require(_amount > currentAmt, AgentPayErrors.AmountNotGreater());

            if (_amount == _pay.transferFunc.maxTransfer.receiver.amt) {
                // set resolve deadline = current timestamp if amount = max
                payRegistry.setPayInfo(_payHash, _amount, nowTs);
                emit ResolvePayment(payId, _amount, nowTs);
            } else {
                // should not update the onchain resolve deadline if not max amount
                payRegistry.setPayAmount(_payHash, _amount);
                emit ResolvePayment(payId, _amount, currentDeadline);
            }
        } else {
            uint256 newDeadline;
            if (_amount == _pay.transferFunc.maxTransfer.receiver.amt) {
                newDeadline = nowTs;
            } else {
                newDeadline = Math.min(nowTs + _pay.resolveTimeout, _pay.resolveDeadline);
                // 0 is reserved for unresolved status of a payment
                require(newDeadline > 0, AgentPayErrors.ZeroDeadline());
            }

            payRegistry.setPayInfo(_payHash, _amount, newDeadline);
            emit ResolvePayment(payId, _amount, newDeadline);
        }
    }

    /**
     * @notice Calculate the result amount of BooleanAnd payment
     * @param _pay conditional pay
     * @param _preimages preimages for hash lock conditions
     * @return pay amount
     */
    function _calculateBooleanAndPayment(PbEntity.ConditionalPay memory _pay, bytes[] memory _preimages)
        internal
        view
        returns (uint256)
    {
        uint256 j = 0;
        bool hasFalseContractCond = false;
        for (uint256 i = 0; i < _pay.conditions.length; i++) {
            PbEntity.Condition memory cond = _pay.conditions[i];
            if (cond.conditionType == PbEntity.ConditionType.HASH_LOCK) {
                require(keccak256(_preimages[j]) == cond.hashLock, AgentPayErrors.PreimageMismatch());
                j++;
            } else if (
                cond.conditionType == PbEntity.ConditionType.DEPLOYED_CONTRACT
                    || cond.conditionType == PbEntity.ConditionType.VIRTUAL_CONTRACT
            ) {
                address addr = _getCondAddress(cond);
                IBooleanCond dependent = IBooleanCond(addr);
                require(dependent.isFinalized(cond.argsQueryFinalization), AgentPayErrors.ConditionNotFinalized());

                if (!dependent.getOutcome(cond.argsQueryOutcome)) {
                    hasFalseContractCond = true;
                }
            } else {
                assert(false);
            }
        }

        if (hasFalseContractCond) {
            return 0;
        } else {
            return _pay.transferFunc.maxTransfer.receiver.amt;
        }
    }

    /**
     * @notice Calculate the result amount of BooleanOr payment
     * @param _pay conditional pay
     * @param _preimages preimages for hash lock conditions
     * @return pay amount
     */
    function _calculateBooleanOrPayment(PbEntity.ConditionalPay memory _pay, bytes[] memory _preimages)
        internal
        view
        returns (uint256)
    {
        uint256 j = 0;
        // whether there are any contract based conditions, i.e. DEPLOYED_CONTRACT or VIRTUAL_CONTRACT
        bool hasContractCond = false;
        bool hasTrueContractCond = false;
        for (uint256 i = 0; i < _pay.conditions.length; i++) {
            PbEntity.Condition memory cond = _pay.conditions[i];
            if (cond.conditionType == PbEntity.ConditionType.HASH_LOCK) {
                require(keccak256(_preimages[j]) == cond.hashLock, AgentPayErrors.PreimageMismatch());
                j++;
            } else if (
                cond.conditionType == PbEntity.ConditionType.DEPLOYED_CONTRACT
                    || cond.conditionType == PbEntity.ConditionType.VIRTUAL_CONTRACT
            ) {
                address addr = _getCondAddress(cond);
                IBooleanCond dependent = IBooleanCond(addr);
                require(dependent.isFinalized(cond.argsQueryFinalization), AgentPayErrors.ConditionNotFinalized());

                hasContractCond = true;
                if (dependent.getOutcome(cond.argsQueryOutcome)) {
                    hasTrueContractCond = true;
                }
            } else {
                assert(false);
            }
        }

        if (!hasContractCond || hasTrueContractCond) {
            return _pay.transferFunc.maxTransfer.receiver.amt;
        } else {
            return 0;
        }
    }

    /**
     * @notice Calculate the result amount of numeric logic payment,
     *   including NUMERIC_ADD, NUMERIC_MAX and NUMERIC_MIN
     * @param _pay conditional pay
     * @param _preimages preimages for hash lock conditions
     * @param _funcType transfer function type
     * @return pay amount
     */
    function _calculateNumericLogicPayment(
        PbEntity.ConditionalPay memory _pay,
        bytes[] memory _preimages,
        PbEntity.TransferFunctionType _funcType
    ) internal view returns (uint256) {
        uint256 amount = 0;
        uint256 j = 0;
        bool hasContractCond = false;
        for (uint256 i = 0; i < _pay.conditions.length; i++) {
            PbEntity.Condition memory cond = _pay.conditions[i];
            if (cond.conditionType == PbEntity.ConditionType.HASH_LOCK) {
                require(keccak256(_preimages[j]) == cond.hashLock, AgentPayErrors.PreimageMismatch());
                j++;
            } else if (
                cond.conditionType == PbEntity.ConditionType.DEPLOYED_CONTRACT
                    || cond.conditionType == PbEntity.ConditionType.VIRTUAL_CONTRACT
            ) {
                address addr = _getCondAddress(cond);
                INumericCond dependent = INumericCond(addr);
                require(dependent.isFinalized(cond.argsQueryFinalization), AgentPayErrors.ConditionNotFinalized());

                if (_funcType == PbEntity.TransferFunctionType.NUMERIC_ADD) {
                    amount = amount + dependent.getOutcome(cond.argsQueryOutcome);
                } else if (_funcType == PbEntity.TransferFunctionType.NUMERIC_MAX) {
                    amount = Math.max(amount, dependent.getOutcome(cond.argsQueryOutcome));
                } else if (_funcType == PbEntity.TransferFunctionType.NUMERIC_MIN) {
                    if (hasContractCond) {
                        amount = Math.min(amount, dependent.getOutcome(cond.argsQueryOutcome));
                    } else {
                        amount = dependent.getOutcome(cond.argsQueryOutcome);
                    }
                } else {
                    assert(false);
                }

                hasContractCond = true;
            } else {
                assert(false);
            }
        }

        if (hasContractCond) {
            require(
                amount <= _pay.transferFunc.maxTransfer.receiver.amt,
                AgentPayErrors.MaxTransferExceeded(amount, _pay.transferFunc.maxTransfer.receiver.amt)
            );
            return amount;
        } else {
            return _pay.transferFunc.maxTransfer.receiver.amt;
        }
    }

    /**
     * @notice Get the contract address of the condition
     * @param _cond condition
     * @return contract address of the condition
     */
    function _getCondAddress(PbEntity.Condition memory _cond) internal view returns (address) {
        // We need to take into account that contract may not be deployed.
        // However, this is automatically handled for us
        // because calling a non-existent function will cause an revert.
        if (_cond.conditionType == PbEntity.ConditionType.DEPLOYED_CONTRACT) {
            return _cond.deployedContractAddress;
        } else if (_cond.conditionType == PbEntity.ConditionType.VIRTUAL_CONTRACT) {
            return virtResolver.resolve(_cond.virtualContractAddress);
        } else {
            revert AgentPayErrors.InvalidConditionType();
        }
    }

    /**
     * @notice Check if a function type is numeric logic
     * @param _funcType transfer function type
     * @return true if it is a numeric logic, otherwise false
     */
    function _isNumericLogic(PbEntity.TransferFunctionType _funcType) internal pure returns (bool) {
        return _funcType == PbEntity.TransferFunctionType.NUMERIC_ADD
            || _funcType == PbEntity.TransferFunctionType.NUMERIC_MAX
            || _funcType == PbEntity.TransferFunctionType.NUMERIC_MIN;
    }

    /**
     * @notice Calculate pay id
     * @param _payHash hash of serialized condPay
     * @param _setter payment info setter, i.e. pay resolver
     * @return calculated pay id
     */
    function _calculatePayId(bytes32 _payHash, address _setter) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_payHash, _setter));
    }
}
