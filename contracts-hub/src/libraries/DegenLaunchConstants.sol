// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title DegenLaunchConstants
/// @notice Immutable DEGEN_V1 launch economics and seven-tranche curve.
library DegenLaunchConstants {
    uint256 internal constant RATE_DENOMINATOR = 1_000_000;

    uint256 internal constant LP_FEE_RATE = 10_000;
    uint256 internal constant PERMANENT_HOOK_RATE = 10_000;
    uint256 internal constant PERMANENT_TREASURY_RATE = 5000;
    uint256 internal constant PERMANENT_BUYBACK_RATE = 5000;
    uint256 internal constant MAXIMUM_TEMPORARY_HOOK_RATE = 790_000;
    uint256 internal constant LAUNCH_FEE_DURATION = 30 seconds;

    uint256 internal constant TRANCHE_COUNT = 7;

    error InvalidTranche(uint256 tranche);

    function lowerTick(uint256 tranche) internal pure returns (int24) {
        if (tranche == 0) return -246_400;
        if (tranche == 1) return -235_400;
        if (tranche == 2) return -212_400;
        if (tranche == 3) return -189_400;
        if (tranche == 4) return -166_200;
        if (tranche == 5) return -143_200;
        if (tranche == 6) return 0;
        revert InvalidTranche(tranche);
    }

    function upperTick(uint256 tranche) internal pure returns (int24) {
        if (tranche == 0) return -235_400;
        if (tranche == 1) return -212_400;
        if (tranche == 2) return -189_400;
        if (tranche == 3) return -166_200;
        if (tranche == 4) return -143_200;
        if (tranche == 5) return 0;
        if (tranche == 6) return 887_200;
        revert InvalidTranche(tranche);
    }

    function supplySharePips(uint256 tranche) internal pure returns (uint256) {
        if (tranche == 0) return 60_000;
        if (tranche == 1) return 440_000;
        if (tranche == 2) return 170_000;
        if (tranche == 3) return 80_000;
        if (tranche == 4) return 60_000;
        if (tranche == 5) return 40_000;
        if (tranche == 6) return 150_000;
        revert InvalidTranche(tranche);
    }
}
