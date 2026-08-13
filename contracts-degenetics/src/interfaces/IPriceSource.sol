// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Oracle-free price read: the immutable DEGEN/WETH v4 pool IS the source.
interface IPriceSource {
    /// @return sqrtPriceX96 current sqrt price of the DEGEN/WETH pool
    function sqrtPriceX96() external view returns (uint160);
}

/// @notice Minimal view surface of Uniswap v4 (StateView periphery or PoolManager extsload wrapper).
interface IV4StateView {
    function getSlot0(bytes32 poolId)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
}
