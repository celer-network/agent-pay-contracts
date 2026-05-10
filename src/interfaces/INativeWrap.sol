// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title INativeWrap
 * @notice Minimal interface for the canonical wrapped-native token on the
 *  target chain (e.g., WETH on Ethereum). AgentPay uses this only internally
 *  as a funding-flow primitive — `LedgerOperation` pulls a peer's pre-approved
 *  wrapped-native via `transferFrom`, then unwraps via `withdraw` to forward
 *  the resulting native (e.g., ETH) to `AgentPayWallet`. Users never see
 *  wrapped-native through AgentPay's native-channel API.
 */
interface INativeWrap is IERC20 {
    /// @notice Wrap `msg.value` of native into the same amount of wrapped-native credited to the caller.
    function deposit() external payable;

    /// @notice Burn `_value` wrapped-native from the caller's balance and send native back via `.call{value:}`.
    function withdraw(uint256 _value) external;
}
