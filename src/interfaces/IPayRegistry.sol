// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title PayRegistry interface
 * @notice Append-only global record of resolved conditional-payment results. Each
 *  payment is keyed by `payId = keccak256(payHash, setterAddress)`, where `setterAddress`
 *  is `msg.sender` of the write — typically a {PayResolver} version. This setter
 *  namespacing means writes are tamper-resistant: only the resolver explicitly
 *  designated by the payment source (field 8 of `ConditionalPay`) can produce a
 *  matching `payId` for that payment.
 */
interface IPayRegistry {
    /**
     * @notice Compute the canonical pay id from a pay hash and setter address.
     * @param _payHash `keccak256(serializedConditionalPay)`.
     * @param _setter Address authorized to set this payment's info (typically a PayResolver).
     * @return The pay id used as the registry key.
     */
    function calculatePayId(bytes32 _payHash, address _setter) external pure returns (bytes32);

    /**
     * @notice Set the resolved amount for a payment under `msg.sender`'s namespace.
     * @param _payHash `keccak256(serializedConditionalPay)`.
     * @param _amt Resolved payment amount.
     */
    function setPayAmount(bytes32 _payHash, uint256 _amt) external;

    /**
     * @notice Set the resolve deadline for a payment under `msg.sender`'s namespace.
     * @param _payHash `keccak256(serializedConditionalPay)`.
     * @param _deadline Unix timestamp (seconds) after which the result is finalized.
     */
    function setPayDeadline(bytes32 _payHash, uint256 _deadline) external;

    /**
     * @notice Set both the amount and the deadline for a payment in one call.
     * @param _payHash `keccak256(serializedConditionalPay)`.
     * @param _amt Resolved payment amount.
     * @param _deadline Unix timestamp (seconds) after which the result is finalized.
     */
    function setPayInfo(bytes32 _payHash, uint256 _amt, uint256 _deadline) external;

    /**
     * @notice Batched variant of {setPayAmount}.
     * @param _payHashes List of pay hashes.
     * @param _amts Resolved amounts (must match `_payHashes` in length).
     */
    function setPayAmounts(bytes32[] calldata _payHashes, uint256[] calldata _amts) external;

    /**
     * @notice Batched variant of {setPayDeadline}.
     * @param _payHashes List of pay hashes.
     * @param _deadlines Resolve deadlines (must match `_payHashes` in length).
     */
    function setPayDeadlines(bytes32[] calldata _payHashes, uint256[] calldata _deadlines) external;

    /**
     * @notice Batched variant of {setPayInfo}.
     * @param _payHashes List of pay hashes.
     * @param _amts Resolved amounts.
     * @param _deadlines Resolve deadlines.
     */
    function setPayInfos(bytes32[] calldata _payHashes, uint256[] calldata _amts, uint256[] calldata _deadlines)
        external;

    /**
     * @notice Bulk-read amounts for use during channel settlement.
     * @dev Each pay is either resolved (gated by its own `resolveDeadline`) or
     *  never resolved (gated by `_maxResolveDeadline`). Unresolved pays read
     *  back as 0 once `block.timestamp > _maxResolveDeadline`.
     * @param _payIds List of pay ids.
     * @param _maxResolveDeadline Upper bound on per-pay resolve deadlines for
     *  the batch — callers pass any value ≥ max(pay.resolveDeadline). Channels
     *  typically pass `pay_clear_deadline` (= max resolve deadline + clear
     *  margin); the margin is a channel-clearance concern, transparent here.
     * @return Amounts indexed identically to `_payIds`.
     */
    function getPayAmounts(bytes32[] calldata _payIds, uint256 _maxResolveDeadline)
        external
        view
        returns (uint256[] memory);

    /**
     * @notice Read the (amount, deadline) tuple for a single payment.
     * @param _payId Pay id.
     * @return amount Resolved payment amount.
     * @return resolveDeadline Unix timestamp (seconds) after which the result is finalized.
     */
    function getPayInfo(bytes32 _payId) external view returns (uint256 amount, uint256 resolveDeadline);

    /// @notice Emitted whenever a pay's amount or deadline is written.
    event PayInfoUpdate(bytes32 indexed payId, uint256 amount, uint256 resolveDeadline);
}
