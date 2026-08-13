// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title DegenLaunchConstants
/// @notice Immutable v4.0 launch economics shared by settlement and quote paths.
library DegenLaunchConstants {
    uint256 internal constant RATE_DENOMINATOR = 1_000_000;
    uint256 internal constant PERMANENT_HOOK_RATE = 5000;
    uint256 internal constant MAXIMUM_TEMPORARY_HOOK_RATE = 795_000;
    uint256 internal constant LAUNCH_FEE_DURATION = 30 seconds;
    uint256 internal constant LP_FEE_RATE = 7000;
}
