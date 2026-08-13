// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Minimal Robinhood Stock Token registry surface required for launch-time checks.
interface IAccessControlsRegistryMinimal {
    function paused() external view returns (bool);
    function isBlocked(address account) external view returns (bool);
}
