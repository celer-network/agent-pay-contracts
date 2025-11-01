// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title PayResolver interface
 */
interface IPayResolver {
    function resolvePaymentByConditions(bytes calldata _resolvePayRequest) external;

    function resolvePaymentByVouchedResult(bytes calldata _vouchedPayResult) external;

    event ResolvePayment(bytes32 indexed payId, uint256 amount, uint256 resolveDeadline);
}
