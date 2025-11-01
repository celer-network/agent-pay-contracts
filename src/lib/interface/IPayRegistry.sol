// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title PayRegistry interface
 */
interface IPayRegistry {
    function calculatePayId(bytes32 _payHash, address _setter) external pure returns(bytes32);

    function setPayAmount(bytes32 _payHash, uint256 _amt) external;

    function setPayDeadline(bytes32 _payHash, uint256 _deadline) external;

    function setPayInfo(bytes32 _payHash, uint256 _amt, uint256 _deadline) external;

    function setPayAmounts(bytes32[] calldata _payHashes, uint256[] calldata _amts) external;

    function setPayDeadlines(bytes32[] calldata _payHashes, uint256[] calldata _deadlines) external;

    function setPayInfos(bytes32[] calldata _payHashes, uint256[] calldata _amts, uint256[] calldata _deadlines) external;

    function getPayAmounts(
        bytes32[] calldata _payIds,
        uint256 _lastPayResolveDeadline
    ) external view returns(uint256[] memory);

    function getPayInfo(bytes32 _payId) external view returns(uint256, uint256);

    event PayInfoUpdate(bytes32 indexed payId, uint256 amount, uint256 resolveDeadline);
}
