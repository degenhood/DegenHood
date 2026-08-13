// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DegenSpyV3LpLocker} from "../launchhub-spy-v3/DegenSpyV3LpLocker.sol";

/// @title Degen SPY permanent LP locker
/// @notice Versionless production identity for the reviewed ten-position SPY locker.
contract DegenSpyLpLocker is DegenSpyV3LpLocker {
    constructor(
        address module,
        address hook,
        address spy,
        address tokenReserve,
        address feeLocker,
        address positionManager
    ) DegenSpyV3LpLocker(module, hook, spy, tokenReserve, feeLocker, positionManager) {}
}
