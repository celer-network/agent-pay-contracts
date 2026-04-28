// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title PayResolver interface
 * @notice On-chain logic for resolving conditional payments. PayResolver is a
 *  *versioned* component: each payment specifies which resolver address it trusts
 *  (field 8 of `ConditionalPay`), and the resolver address is mixed into the
 *  pay id (`payId = keccak256(payHash, resolverAddress)`). This binds a payment's
 *  result to the exact resolver version the source designated.
 *
 *  Two resolution modes are supported:
 *    - {resolvePaymentByConditions} — evaluate every condition on-chain (hash-locks
 *      via preimages, deployed/virtual contracts via {IBooleanCond}/{INumericCond})
 *      and apply the payment's `transfer_func`.
 *    - {resolvePaymentByVouchedResult} — accept a result co-signed by `pay.src`
 *      and `pay.dest`, capped at `pay.transferFunc.maxTransfer.receiver.amt`.
 */
interface IPayResolver {
    /**
     * @notice Resolve a payment by evaluating its on-chain conditions.
     * @dev All conditions must already be finalized; the call reverts otherwise.
     *  Hash-lock conditions are validated against `_resolvePayRequest.hashPreimages`
     *  in the order they appear in `pay.conditions`. Virtual-contract conditions
     *  must already be materialized via the VirtContractResolver.
     * @param _resolvePayRequest ABI-encoded `PbChain.ResolvePayByConditionsRequest`.
     */
    function resolvePaymentByConditions(bytes calldata _resolvePayRequest) external;

    /**
     * @notice Resolve a payment by submitting an off-chain result co-signed by
     *  the payment's source and destination.
     * @dev The submitted amount must not exceed `pay.transferFunc.maxTransfer.receiver.amt`.
     * @param _vouchedPayResult ABI-encoded `PbEntity.VouchedCondPayResult`.
     */
    function resolvePaymentByVouchedResult(bytes calldata _vouchedPayResult) external;

    /// @notice Emitted whenever a payment is resolved on-chain.
    event ResolvePayment(bytes32 indexed payId, uint256 amount, uint256 resolveDeadline);
}
