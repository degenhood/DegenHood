// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

/// @title DegenV3LaunchConstants
/// @notice Immutable WETH V3 economics and ten-position launch curve.
library DegenV3LaunchConstants {
    uint256 internal constant RATE_DENOMINATOR = 1_000_000;
    uint256 internal constant LP_FEE_RATE = 10_000;
    uint256 internal constant PERMANENT_HOOK_RATE = 10_000;
    uint256 internal constant PERMANENT_TREASURY_RATE = 5000;
    uint256 internal constant PERMANENT_BUYBACK_RATE = 5000;
    uint256 internal constant MAXIMUM_TEMPORARY_HOOK_RATE = 790_000;
    // A 30-second wall-clock decay gives social-post buyers time to arrive while pricing speed.
    uint256 internal constant LAUNCH_FEE_DURATION = 30 seconds;

    uint256 internal constant TRANCHE_COUNT = 10;
    int24 internal constant TICK_SPACING = 200;
    int24 internal constant INITIAL_TICK = -239_400;
    int24 internal constant MAX_TICK = 887_200;

    error InvalidTranche(uint256 tranche);

    function lowerTick(uint256 tranche) internal pure returns (int24) {
        if (tranche == 0) return -239_400;
        if (tranche == 1) return -233_400;
        if (tranche == 2) return -225_400;
        if (tranche == 3) return -217_400;
        if (tranche == 4) return -212_400;
        if (tranche == 5) return -199_400;
        if (tranche == 6) return -174_200;
        if (tranche == 7) return -153_600;
        if (tranche == 8) return -133_000;
        if (tranche == 9) return -112_200;
        revert InvalidTranche(tranche);
    }

    function upperTick(uint256 tranche) internal pure returns (int24) {
        if (tranche == 0) return -233_400;
        if (tranche == 1) return -225_400;
        if (tranche == 2) return -217_400;
        if (tranche == 3) return -212_400;
        if (tranche == 4) return -199_400;
        if (tranche == 5) return -174_200;
        if (tranche == 6) return -153_600;
        if (tranche == 7) return -133_000;
        if (tranche == 8) return -112_200;
        if (tranche == 9) return MAX_TICK;
        revert InvalidTranche(tranche);
    }

    function supplySharePips(uint256 tranche) internal pure returns (uint256) {
        if (tranche == 0) return 17_200;
        if (tranche == 1) return 314_500;
        if (tranche == 2) return 45_800;
        if (tranche == 3) return 276_400;
        if (tranche == 4) return 95_300;
        if (tranche == 5) return 20_900;
        if (tranche == 6) return 10_000;
        if (tranche == 7) return 10_000;
        if (tranche == 8) return 10_000;
        if (tranche == 9) return 199_900;
        revert InvalidTranche(tranche);
    }

    function trancheSupply(uint256 totalSupply, uint256 tranche) internal pure returns (uint256) {
        return totalSupply * supplySharePips(tranche) / RATE_DENOMINATOR;
    }

    function liquidity(uint256 totalSupply, uint256 tranche) internal pure returns (uint128) {
        return LiquidityAmounts.getLiquidityForAmount0(
            TickMath.getSqrtPriceAtTick(lowerTick(tranche)),
            TickMath.getSqrtPriceAtTick(upperTick(tranche)),
            trancheSupply(totalSupply, tranche)
        );
    }
}
