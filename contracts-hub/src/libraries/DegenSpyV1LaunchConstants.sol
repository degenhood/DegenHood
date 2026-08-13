// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title DegenSpyV1LaunchConstants
/// @notice Immutable raw-SPY economics and seven-position curve for SPY V4.1 launches.
library DegenSpyV1LaunchConstants {
    address internal constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address internal constant SPY_REGISTRY = 0xe10b6f6B275de231345c20D14Ab812db62151b00;
    bytes32 internal constant SPY_UID =
        0x000000000000000000000000000000001c6f27a62789417d8ed359ed3c2d3da1;

    uint256 internal constant RATE_DENOMINATOR = 1_000_000;
    uint256 internal constant LP_FEE_RATE = 10_000;
    uint256 internal constant PERMANENT_HOOK_RATE = 10_000;
    uint256 internal constant PERMANENT_TREASURY_RATE = 5000;
    uint256 internal constant PERMANENT_BUYBACK_RATE = 5000;
    uint256 internal constant MAXIMUM_TEMPORARY_HOOK_RATE = 790_000;
    uint256 internal constant LAUNCH_FEE_DURATION = 30 seconds;

    uint256 internal constant TRANCHE_COUNT = 7;
    int24 internal constant TICK_SPACING = 200;
    int24 internal constant INITIAL_TICK = -237_200;

    error InvalidTranche(uint256 tranche);

    function lowerTick(uint256 tranche) internal pure returns (int24) {
        if (tranche == 0) return -237_200;
        if (tranche == 1) return -226_200;
        if (tranche == 2) return -203_200;
        if (tranche == 3) return -180_200;
        if (tranche == 4) return -157_000;
        if (tranche == 5) return -134_000;
        if (tranche == 6) return 0;
        revert InvalidTranche(tranche);
    }

    function upperTick(uint256 tranche) internal pure returns (int24) {
        if (tranche == 0) return -226_200;
        if (tranche == 1) return -203_200;
        if (tranche == 2) return -180_200;
        if (tranche == 3) return -157_000;
        if (tranche == 4) return -134_000;
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
