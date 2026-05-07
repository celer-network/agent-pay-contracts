// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IPayRegistry.sol";

/**
 * @title PayRegistry
 * @notice Append-only global record of resolved conditional-payment results. Pay ids
 *  are namespaced by setter address (`payId = keccak256(payHash, msg.sender)`), so
 *  only the {PayResolver} version explicitly designated by a payment's source can
 *  produce a matching entry for that payment.
 * @dev See {IPayRegistry} for canonical NatSpec on each function.
 */
contract PayRegistry is IPayRegistry {
    /// @dev Per-pay registry entry. Stored under the namespaced `payId`.
    struct PayInfo {
        uint256 amount;
        uint256 resolveDeadline;
    }

    /// @notice `payId → (amount, resolveDeadline)`. Public auto-getter.
    mapping(bytes32 => PayInfo) public payInfoMap;

    /// @inheritdoc IPayRegistry
    function calculatePayId(bytes32 _payHash, address _setter) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(_payHash, _setter));
    }

    /// @inheritdoc IPayRegistry
    function setPayAmount(bytes32 _payHash, uint256 _amt) external {
        bytes32 payId = calculatePayId(_payHash, msg.sender);
        PayInfo storage payInfo = payInfoMap[payId];
        payInfo.amount = _amt;

        emit PayInfoUpdate(payId, _amt, payInfo.resolveDeadline);
    }

    /// @inheritdoc IPayRegistry
    function setPayDeadline(bytes32 _payHash, uint256 _deadline) external {
        bytes32 payId = calculatePayId(_payHash, msg.sender);
        PayInfo storage payInfo = payInfoMap[payId];
        payInfo.resolveDeadline = _deadline;

        emit PayInfoUpdate(payId, payInfo.amount, _deadline);
    }

    /// @inheritdoc IPayRegistry
    function setPayInfo(bytes32 _payHash, uint256 _amt, uint256 _deadline) external {
        bytes32 payId = calculatePayId(_payHash, msg.sender);
        PayInfo storage payInfo = payInfoMap[payId];
        payInfo.amount = _amt;
        payInfo.resolveDeadline = _deadline;

        emit PayInfoUpdate(payId, _amt, _deadline);
    }

    /// @inheritdoc IPayRegistry
    function setPayAmounts(bytes32[] calldata _payHashes, uint256[] calldata _amts) external {
        require(_payHashes.length == _amts.length, "Lengths do not match");

        bytes32 payId;
        address msgSender = msg.sender;
        for (uint256 i = 0; i < _payHashes.length; i++) {
            payId = calculatePayId(_payHashes[i], msgSender);
            PayInfo storage payInfo = payInfoMap[payId];
            payInfo.amount = _amts[i];

            emit PayInfoUpdate(payId, _amts[i], payInfo.resolveDeadline);
        }
    }

    /// @inheritdoc IPayRegistry
    function setPayDeadlines(bytes32[] calldata _payHashes, uint256[] calldata _deadlines) external {
        require(_payHashes.length == _deadlines.length, "Lengths do not match");

        bytes32 payId;
        address msgSender = msg.sender;
        for (uint256 i = 0; i < _payHashes.length; i++) {
            payId = calculatePayId(_payHashes[i], msgSender);
            PayInfo storage payInfo = payInfoMap[payId];
            payInfo.resolveDeadline = _deadlines[i];

            emit PayInfoUpdate(payId, payInfo.amount, _deadlines[i]);
        }
    }

    /// @inheritdoc IPayRegistry
    function setPayInfos(bytes32[] calldata _payHashes, uint256[] calldata _amts, uint256[] calldata _deadlines)
        external
    {
        require(_payHashes.length == _amts.length && _payHashes.length == _deadlines.length, "Lengths do not match");

        bytes32 payId;
        address msgSender = msg.sender;
        for (uint256 i = 0; i < _payHashes.length; i++) {
            payId = calculatePayId(_payHashes[i], msgSender);
            PayInfo storage payInfo = payInfoMap[payId];
            payInfo.amount = _amts[i];
            payInfo.resolveDeadline = _deadlines[i];

            emit PayInfoUpdate(payId, _amts[i], _deadlines[i]);
        }
    }

    /// @inheritdoc IPayRegistry
    function getPayAmounts(bytes32[] calldata _payIds, uint256 _maxResolveDeadline)
        external
        view
        returns (uint256[] memory)
    {
        uint256[] memory amounts = new uint256[](_payIds.length);
        for (uint256 i = 0; i < _payIds.length; i++) {
            if (payInfoMap[_payIds[i]].resolveDeadline == 0) {
                // unresolved pays are gated by the caller-supplied upper-bound deadline
                require(block.timestamp > _maxResolveDeadline, "Payment is not finalized");
            } else {
                // resolved pays are gated by their per-pay resolve deadline
                require(block.timestamp > payInfoMap[_payIds[i]].resolveDeadline, "Payment is not finalized");
            }
            amounts[i] = payInfoMap[_payIds[i]].amount;
        }
        return amounts;
    }

    /// @inheritdoc IPayRegistry
    function getPayInfo(bytes32 _payId) external view returns (uint256, uint256) {
        PayInfo storage payInfo = payInfoMap[_payId];
        return (payInfo.amount, payInfo.resolveDeadline);
    }
}
