// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {DegenV3Hook} from "../launchhub-v3/DegenV3Hook.sol";

/// @title Degen WETH launch hook
/// @notice Versionless production identity for the reviewed accrue-only WETH hook.
contract DegenWethHook is DegenV3Hook {
    constructor(
        IPoolManager manager,
        address module,
        address weth,
        address operatingTreasury,
        address buybackVault,
        address feeLocker
    ) DegenV3Hook(manager, module, weth, operatingTreasury, buybackVault, feeLocker) {}
}
