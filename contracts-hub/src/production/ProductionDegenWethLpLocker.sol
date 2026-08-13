// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DegenV3LpLocker} from "../launchhub-v3/DegenV3LpLocker.sol";

/// @title Degen WETH permanent LP locker
/// @notice Versionless production identity for the reviewed ten-position WETH locker.
contract DegenWethLpLocker is DegenV3LpLocker {
    constructor(
        address module,
        address hook,
        address weth,
        address tokenReserve,
        address feeLocker,
        address positionManager
    ) DegenV3LpLocker(module, hook, weth, tokenReserve, feeLocker, positionManager) {}
}
