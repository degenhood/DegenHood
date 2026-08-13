// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {DegenSpyV3Hook} from "../launchhub-spy-v3/DegenSpyV3Hook.sol";

/// @title Degen SPY launch hook
/// @notice Versionless production identity for the reviewed accrue-only SPY hook.
contract DegenSpyHook is DegenSpyV3Hook {
    constructor(
        IPoolManager manager,
        address module,
        address spy,
        address operatingTreasury,
        address buybackVault,
        address feeLocker
    ) DegenSpyV3Hook(manager, module, spy, operatingTreasury, buybackVault, feeLocker) {}
}
