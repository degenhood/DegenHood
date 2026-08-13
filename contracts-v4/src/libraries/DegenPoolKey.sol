// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

library DegenPoolKey {
    int24 internal constant TICK_SPACING = 200;

    function canonical(address token, address weth, address hook)
        internal
        pure
        returns (PoolKey memory key)
    {
        key = PoolKey({
            currency0: Currency.wrap(token),
            currency1: Currency.wrap(weth),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hook)
        });
    }

    function matches(PoolKey memory actual, address token, address weth, address hook)
        internal
        pure
        returns (bool)
    {
        PoolKey memory expected = canonical(token, weth, hook);
        return Currency.unwrap(actual.currency0) == Currency.unwrap(expected.currency0)
            && Currency.unwrap(actual.currency1) == Currency.unwrap(expected.currency1)
            && actual.fee == expected.fee && actual.tickSpacing == expected.tickSpacing
            && address(actual.hooks) == address(expected.hooks);
    }
}
