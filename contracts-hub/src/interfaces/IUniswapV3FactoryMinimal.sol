// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Minimal immutable Uniswap v3 factory surface used by the DEGEN V3 template.
interface IUniswapV3FactoryMinimal {
    function owner() external view returns (address);
    function feeAmountTickSpacing(uint24 fee) external view returns (int24);
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}
