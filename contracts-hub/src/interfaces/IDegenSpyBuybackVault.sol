// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IUniswapV3FactoryMinimal} from "./IUniswapV3FactoryMinimal.sol";
import {IUniswapV3SwapCallbackMinimal} from "./IUniswapV3SwapPoolMinimal.sol";

interface IDegenSpyBuybackVault is IUniswapV3SwapCallbackMinimal {
    error AlreadyFilledThisBlock(uint256 blockNumber);
    error InvalidAddress();
    error InvalidPool();
    error InvalidSwapDelta(int256 amount0Delta, int256 amount1Delta);
    error PriceLimitUnavailable(uint160 sqrtPriceX96);
    error SettlementMismatch(uint256 expected, uint256 actual);
    error UnauthorizedCallback();

    event BuybackExecuted(
        address indexed caller,
        uint256 rawSpySpent,
        uint256 degenRemoved,
        uint256 rawSpyRemaining,
        uint160 sqrtPriceLimitX96
    );

    function v3Factory() external view returns (IUniswapV3FactoryMinimal);
    function degen() external view returns (address);
    function spy() external view returns (address);
    function pool() external view returns (address);
    function poolFee() external pure returns (uint24);
    function tickSpacing() external pure returns (int24);
    function burnSink() external pure returns (address);
    function lastFillBlock() external view returns (uint256);
    function totalRawSpySpent() external view returns (uint256);
    function totalDegenRemoved() external view returns (uint256);
    function previewPriceLimit()
        external
        view
        returns (uint160 sqrtPriceX96, uint160 sqrtPriceLimitX96);
    function priceLimitFor(uint160 sqrtPriceX96) external pure returns (uint160 sqrtPriceLimitX96);
    function executeBuyback() external returns (uint256 rawSpySpent, uint256 degenRemoved);
}
