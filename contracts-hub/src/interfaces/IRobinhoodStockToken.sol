// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Read-only Robinhood Stock Token surface used by the SPY launch module.
interface IRobinhoodStockToken {
    function uid() external view returns (bytes32);
    function paused() external view returns (bool);
    function uiMultiplier() external view returns (uint256);
    function ACCESS_CONTROLLED_REGISTRY() external view returns (address);
}
