// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IUniswapV3PoolMinimal} from "./IUniswapV3PoolMinimal.sol";

interface IUniswapV3SwapCallbackMinimal {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data)
        external;
}

/// @notice Minimal direct-swap surface used by the routerless DEGEN/SPY buyback vault.
interface IUniswapV3SwapPoolMinimal is IUniswapV3PoolMinimal {
    function liquidity() external view returns (uint128);

    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}
