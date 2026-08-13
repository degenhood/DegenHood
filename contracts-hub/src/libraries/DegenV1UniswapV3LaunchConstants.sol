// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DegenLaunchConstants} from "./DegenLaunchConstants.sol";

/// @notice Uniswap v3 identity for the exact seven-position DEGEN V4 curve mirror.
library DegenV1UniswapV3LaunchConstants {
    uint256 internal constant RATE_DENOMINATOR = 1_000_000;
    uint256 internal constant TRANCHE_COUNT = 7;
    uint24 internal constant POOL_FEE = 10_000;
    int24 internal constant TICK_SPACING = 200;
    int24 internal constant INITIAL_TICK = -246_400;

    function lowerTick(uint256 tranche) internal pure returns (int24) {
        return DegenLaunchConstants.lowerTick(tranche);
    }

    function upperTick(uint256 tranche) internal pure returns (int24) {
        return DegenLaunchConstants.upperTick(tranche);
    }

    function supplySharePips(uint256 tranche) internal pure returns (uint256) {
        return DegenLaunchConstants.supplySharePips(tranche);
    }
}
