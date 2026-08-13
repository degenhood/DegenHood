// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title DegenV2LaunchConstants
/// @notice Immutable WETH V4 V2 economics and six-position launch curve.
library DegenV2LaunchConstants {
    uint256 internal constant RATE_DENOMINATOR = 1_000_000;
    uint256 internal constant LP_FEE_RATE = 10_000;
    uint256 internal constant PERMANENT_HOOK_RATE = 10_000;
    uint256 internal constant PERMANENT_TREASURY_RATE = 5000;
    uint256 internal constant PERMANENT_BUYBACK_RATE = 5000;
    uint256 internal constant MAXIMUM_TEMPORARY_HOOK_RATE = 790_000;
    uint256 internal constant LAUNCH_FEE_DURATION = 30 seconds;

    uint256 internal constant TRANCHE_COUNT = 6;
    int24 internal constant TICK_SPACING = 200;
    int24 internal constant INITIAL_TICK = -230_200;

    error InvalidTranche(uint256 tranche);

    function lowerTick(uint256 tranche) internal pure returns (int24) {
        if (tranche == 0) return -230_200;
        if (tranche == 1) return -219_200;
        if (tranche == 2) return -204_200;
        if (tranche == 3) return -189_200;
        if (tranche == 4) return -174_200;
        if (tranche == 5) return -163_800;
        revert InvalidTranche(tranche);
    }

    function upperTick(uint256 tranche) internal pure returns (int24) {
        if (tranche == 0) return -219_200;
        if (tranche == 1) return -204_200;
        if (tranche == 2) return -189_200;
        if (tranche == 3) return -174_200;
        if (tranche == 4) return -163_800;
        if (tranche == 5) return 887_200;
        revert InvalidTranche(tranche);
    }

    function supplySharePips(uint256 tranche) internal pure returns (uint256) {
        if (tranche == 0) return 60_000;
        if (tranche == 1) return 340_000;
        if (tranche == 2) return 220_000;
        if (tranche == 3) return 170_000;
        if (tranche == 4) return 100_000;
        if (tranche == 5) return 110_000;
        revert InvalidTranche(tranche);
    }
}
