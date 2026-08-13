// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IDegenBuybackVault {
    error AlreadyFilledThisBlock(uint256 blockNumber);
    error InvalidAddress();
    error InvalidPool();
    error InvalidSwapDelta(int128 degenDelta, int128 wethDelta);
    error PriceLimitUnavailable(uint160 sqrtPriceX96);
    error SettlementMismatch(uint256 expected, uint256 actual);
    error UnauthorizedUnlock();
    error UnexpectedExecution(uint256 expectedWeth, uint160 expectedLimit);

    event BuybackExecuted(
        address indexed caller,
        uint256 wethSpent,
        uint256 degenRemoved,
        uint256 wethRemaining,
        uint160 sqrtPriceLimitX96
    );

    function poolManager() external view returns (IPoolManager);
    function degen() external view returns (address);
    function weth() external view returns (address);
    function poolId() external view returns (PoolId);
    function burnSink() external pure returns (address);
    function lastFillBlock() external view returns (uint256);
    function totalWethSpent() external view returns (uint256);
    function totalDegenRemoved() external view returns (uint256);
    function poolKey() external view returns (PoolKey memory);
    function previewPriceLimit()
        external
        view
        returns (uint160 sqrtPriceX96, uint160 sqrtPriceLimitX96);
    function priceLimitFor(uint160 sqrtPriceX96) external pure returns (uint160 sqrtPriceLimitX96);
    function executeBuyback() external returns (uint256 wethSpent, uint256 degenRemoved);
}
