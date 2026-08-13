// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {DegenV4Fixture} from "./DegenV4Fixture.sol";

/// @notice Captures quote, settlement, PoolManager, hook, and LP-fee observations for real swaps.
abstract contract DegenV4SwapHarness is DegenV4Fixture {
    using BalanceDeltaLibrary for BalanceDelta;
    using TransientStateLibrary for IPoolManager;

    struct SwapObservation {
        int128 quotedAmount0;
        int128 quotedAmount1;
        int128 amount0Delta;
        int128 amount1Delta;
        int256 traderCurrency0Change;
        int256 traderCurrency1Change;
        int256 hookCurrency0Change;
        int256 hookCurrency1Change;
        uint256 hookClaim0Before;
        uint256 hookClaim1Before;
        uint256 hookClaim0After;
        uint256 hookClaim1After;
        int256 routerManagerDelta0After;
        int256 routerManagerDelta1After;
        uint256 feeGrowth0Before;
        uint256 feeGrowth1Before;
        uint256 feeGrowth0After;
        uint256 feeGrowth1After;
        uint24 lpFeeBefore;
        uint24 lpFeeAfter;
    }

    function _quoteAndExecute(bool zeroForOne, int256 amountSpecified, bytes memory hookData)
        internal
        returns (SwapObservation memory observed)
    {
        uint256 snapshotId = vm.snapshotState();
        BalanceDelta quoted = swap(key, zeroForOne, amountSpecified, hookData);
        assertTrue(vm.revertToStateAndDelete(snapshotId), "quote snapshot restore failed");

        observed.quotedAmount0 = quoted.amount0();
        observed.quotedAmount1 = quoted.amount1();
        observed.lpFeeBefore = _currentLpFee();
        (observed.feeGrowth0Before, observed.feeGrowth1Before) = _feeGrowthGlobals();

        address hook = address(key.hooks);
        uint256 trader0Before = _balanceOf(currency0, address(this));
        uint256 trader1Before = _balanceOf(currency1, address(this));
        uint256 hook0Before = _balanceOf(currency0, hook);
        uint256 hook1Before = _balanceOf(currency1, hook);
        observed.hookClaim0Before = manager.balanceOf(hook, currency0.toId());
        observed.hookClaim1Before = manager.balanceOf(hook, currency1.toId());

        BalanceDelta settled = swap(key, zeroForOne, amountSpecified, hookData);

        observed.amount0Delta = settled.amount0();
        observed.amount1Delta = settled.amount1();
        observed.traderCurrency0Change =
            _signedDifference(trader0Before, _balanceOf(currency0, address(this)));
        observed.traderCurrency1Change =
            _signedDifference(trader1Before, _balanceOf(currency1, address(this)));
        observed.hookCurrency0Change = _signedDifference(hook0Before, _balanceOf(currency0, hook));
        observed.hookCurrency1Change = _signedDifference(hook1Before, _balanceOf(currency1, hook));
        observed.hookClaim0After = manager.balanceOf(hook, currency0.toId());
        observed.hookClaim1After = manager.balanceOf(hook, currency1.toId());
        observed.routerManagerDelta0After = manager.currencyDelta(address(swapRouter), currency0);
        observed.routerManagerDelta1After = manager.currencyDelta(address(swapRouter), currency1);
        (observed.feeGrowth0After, observed.feeGrowth1After) = _feeGrowthGlobals();
        observed.lpFeeAfter = _currentLpFee();
    }

    function _balanceOf(Currency currency, address account) private view returns (uint256) {
        return IERC20(Currency.unwrap(currency)).balanceOf(account);
    }

    function _signedDifference(uint256 beforeBalance, uint256 afterBalance)
        private
        pure
        returns (int256)
    {
        if (afterBalance >= beforeBalance) return int256(afterBalance - beforeBalance);
        return -int256(beforeBalance - afterBalance);
    }
}
