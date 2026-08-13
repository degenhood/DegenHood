// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";
import {LiquidityMath} from "@uniswap/v4-core/src/libraries/LiquidityMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IDegenBuybackVault} from "../interfaces/IDegenBuybackVault.sol";

/// @title Immutable $DEGEN buyback and removal-from-circulation vault
/// @notice Permissionlessly converts all safely offerable WETH into the pinned live $DEGEN pool.
/// @dev The price boundary limits one call's self-impact; it is deliberately not an oracle.
contract DegenBuybackVault is IDegenBuybackVault, IUnlockCallback, ReentrancyGuard {
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    address private constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    uint256 private constant ROBINHOOD_CHAIN_ID = 4663;
    address private constant LIVE_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address private constant LIVE_DEGEN = 0x04d5D8a61DA0b6548B136412843aDBA55EbeaDE6;
    address private constant LIVE_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address private constant LIVE_HOOK = 0x61C96E7E3E04317A841E8E24630F9d78f98630cC;
    bytes32 private constant LIVE_POOL_ID =
        0x6ed2072a6360ee46bfac4645d195f1427b642fc40806b0b7fd8ad3cd9d07b028;
    uint24 private constant LIVE_HOOK_FEE = 5000;
    uint256 private constant Q128 = 1 << 128;

    // floor(sqrt(101 / 100) * 2^128). Rounding down makes the boundary conservative.
    uint256 private constant SQRT_ONE_PERCENT_X128 =
        341_979_546_361_605_312_568_969_099_661_698_692_653;
    uint256 private constant MAX_SAFE_INPUT = uint256(uint128(type(int128).max));

    IPoolManager public immutable override poolManager;
    address public immutable override degen;
    address public immutable override weth;
    PoolId public immutable override poolId;
    uint24 private immutable _hookFee;

    uint256 public override lastFillBlock;
    uint256 public override totalWethSpent;
    uint256 public override totalDegenRemoved;

    PoolKey private _poolKey;
    bool private _unlocking;
    uint256 private _expectedWeth;
    uint160 private _expectedLimit;

    constructor(IPoolManager poolManager_, PoolKey memory poolKey_) {
        address managerAddress = address(poolManager_);
        address degen_ = Currency.unwrap(poolKey_.currency0);
        address weth_ = Currency.unwrap(poolKey_.currency1);
        address hook = address(poolKey_.hooks);
        if (
            managerAddress == address(0) || managerAddress.code.length == 0 || degen_ == address(0)
                || weth_ == address(0) || degen_ >= weth_ || degen_.code.length == 0
                || weth_.code.length == 0 || (hook != address(0) && hook.code.length == 0)
        ) {
            revert InvalidAddress();
        }

        PoolId poolId_ = poolKey_.toId();
        (uint160 sqrtPriceX96,,,) = poolManager_.getSlot0(poolId_);
        if (sqrtPriceX96 == 0) revert InvalidPool();
        if (
            block.chainid == ROBINHOOD_CHAIN_ID
                && (managerAddress != LIVE_POOL_MANAGER
                    || degen_ != LIVE_DEGEN
                    || weth_ != LIVE_WETH
                    || hook != LIVE_HOOK
                    || PoolId.unwrap(poolId_) != LIVE_POOL_ID)
        ) {
            revert InvalidPool();
        }
        poolManager = poolManager_;
        degen = degen_;
        weth = weth_;
        poolId = poolId_;
        _hookFee = hook == LIVE_HOOK ? LIVE_HOOK_FEE : 0;
        _poolKey = poolKey_;
    }

    function burnSink() external pure override returns (address) {
        return BURN_ADDRESS;
    }

    function poolKey() external view override returns (PoolKey memory) {
        return _poolKey;
    }

    function previewPriceLimit()
        public
        view
        override
        returns (uint160 sqrtPriceX96, uint160 sqrtPriceLimitX96)
    {
        (sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        sqrtPriceLimitX96 = priceLimitFor(sqrtPriceX96);
    }

    function priceLimitFor(uint160 sqrtPriceX96)
        public
        pure
        override
        returns (uint160 sqrtPriceLimitX96)
    {
        uint256 scaled = Math.mulDiv(uint256(sqrtPriceX96), SQRT_ONE_PERCENT_X128, Q128);
        uint256 maximum = uint256(TickMath.MAX_SQRT_PRICE) - 1;
        if (scaled > maximum) scaled = maximum;
        if (scaled <= sqrtPriceX96) revert PriceLimitUnavailable(sqrtPriceX96);
        sqrtPriceLimitX96 = uint160(scaled);
    }

    function executeBuyback()
        external
        override
        nonReentrant
        returns (uint256 wethSpent, uint256 degenRemoved)
    {
        uint256 balance = IERC20(weth).balanceOf(address(this));
        if (balance == 0) return (0, 0);
        if (lastFillBlock == block.number) revert AlreadyFilledThisBlock(block.number);

        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) =
            poolManager.getSlot0(poolId);
        uint160 sqrtPriceLimitX96 = priceLimitFor(sqrtPriceX96);
        uint128 liquidity = poolManager.getLiquidity(poolId);
        if (liquidity == 0) return (0, 0);

        uint256 poolNetToLimit = _poolNetToLimit(sqrtPriceX96, tick, sqrtPriceLimitX96, liquidity);
        uint24 swapFee = _oneForZeroSwapFee(protocolFee, lpFee);
        uint256 grossToLimit = _grossFromPoolNetDown(poolNetToLimit, _hookFee, swapFee);
        uint256 offered = Math.min(balance, MAX_SAFE_INPUT);
        if (grossToLimit <= offered) {
            if (grossToLimit <= 1) return (0, 0);
            offered = grossToLimit - 1;
        }
        if (offered == 0) return (0, 0);

        _unlocking = true;
        _expectedWeth = offered;
        _expectedLimit = sqrtPriceLimitX96;
        bytes memory result = poolManager.unlock(abi.encode(offered, sqrtPriceLimitX96));
        _unlocking = false;
        _expectedWeth = 0;
        _expectedLimit = 0;

        (wethSpent, degenRemoved) = abi.decode(result, (uint256, uint256));
        if (wethSpent != offered) revert SettlementMismatch(offered, wethSpent);
        if (wethSpent == 0) return (0, 0);

        if (degenRemoved != 0) IERC20(degen).safeTransfer(BURN_ADDRESS, degenRemoved);
        totalWethSpent += wethSpent;
        totalDegenRemoved += degenRemoved;
        lastFillBlock = block.number;

        emit BuybackExecuted(
            msg.sender,
            wethSpent,
            degenRemoved,
            IERC20(weth).balanceOf(address(this)),
            sqrtPriceLimitX96
        );
    }

    function _grossFromPoolNetDown(uint256 poolNet, uint24 hookFee, uint24 swapFee)
        private
        pure
        returns (uint256 gross)
    {
        uint256 denominator = (1_000_000 - uint256(hookFee)) * (1_000_000 - uint256(swapFee));
        gross = Math.mulDiv(poolNet, 1_000_000 * 1_000_000, denominator);
        while (gross != 0 && _poolNetFromGross(gross, hookFee, swapFee) > poolNet) {
            gross--;
        }
        while (
            gross != type(uint256).max && _poolNetFromGross(gross + 1, hookFee, swapFee) <= poolNet
        ) {
            gross++;
        }
    }

    function _poolNetToLimit(
        uint160 sqrtPriceX96,
        int24 tick,
        uint160 sqrtPriceLimitX96,
        uint128 liquidity
    ) private view returns (uint256 poolNet) {
        int24 tickSpacing = _poolKey.tickSpacing;
        while (sqrtPriceX96 < sqrtPriceLimitX96) {
            (int24 nextTick, bool initialized) =
                _nextInitializedTickWithinOneWord(tick, tickSpacing);
            if (nextTick >= TickMath.MAX_TICK) nextTick = TickMath.MAX_TICK;

            uint160 sqrtPriceNextX96 = TickMath.getSqrtPriceAtTick(nextTick);
            uint160 target =
                sqrtPriceNextX96 < sqrtPriceLimitX96 ? sqrtPriceNextX96 : sqrtPriceLimitX96;
            if (liquidity != 0) {
                poolNet += SqrtPriceMath.getAmount1Delta(sqrtPriceX96, target, liquidity, false);
            }
            sqrtPriceX96 = target;
            if (sqrtPriceX96 != sqrtPriceNextX96) break;

            if (initialized) {
                (, int128 liquidityNet) = poolManager.getTickLiquidity(poolId, nextTick);
                liquidity = LiquidityMath.addDelta(liquidity, liquidityNet);
            }
            tick = nextTick;
        }
    }

    function _nextInitializedTickWithinOneWord(int24 tick, int24 tickSpacing)
        private
        view
        returns (int24 next, bool initialized)
    {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--;
        compressed++;

        int16 wordPos = int16(compressed >> 8);
        uint8 bitPos = uint8(uint24(compressed) & 0xff);
        uint256 mask = ~((1 << bitPos) - 1);
        uint256 masked = poolManager.getTickBitmap(poolId, wordPos) & mask;
        initialized = masked != 0;
        uint8 offset =
            initialized ? BitMath.leastSignificantBit(masked) - bitPos : type(uint8).max - bitPos;
        next = (compressed + int24(uint24(offset))) * tickSpacing;
    }

    function _poolNetFromGross(uint256 gross, uint24 hookFee, uint24 swapFee)
        private
        pure
        returns (uint256)
    {
        uint256 hookAmount = Math.mulDiv(gross, hookFee, 1_000_000);
        return Math.mulDiv(gross - hookAmount, 1_000_000 - swapFee, 1_000_000);
    }

    function _oneForZeroSwapFee(uint24 protocolFee, uint24 lpFee)
        private
        pure
        returns (uint24 swapFee)
    {
        uint16 oneForZeroProtocolFee = uint16(protocolFee >> 12);
        if (oneForZeroProtocolFee == 0) return lpFee;
        swapFee = uint24(
            uint256(oneForZeroProtocolFee) + lpFee - uint256(oneForZeroProtocolFee) * lpFee
                / 1_000_000
        );
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager) || !_unlocking) revert UnauthorizedUnlock();
        (uint256 offered, uint160 sqrtPriceLimitX96) = abi.decode(data, (uint256, uint160));
        if (offered != _expectedWeth || sqrtPriceLimitX96 != _expectedLimit) {
            revert UnexpectedExecution(_expectedWeth, _expectedLimit);
        }

        BalanceDelta delta = poolManager.swap(
            _poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(offered),
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            bytes("")
        );
        int128 degenDelta = delta.amount0();
        int128 wethDelta = delta.amount1();
        if (degenDelta < 0 || wethDelta > 0 || (wethDelta == 0 && degenDelta != 0)) {
            revert InvalidSwapDelta(degenDelta, wethDelta);
        }

        uint256 wethSpent = uint256(-int256(wethDelta));
        uint256 degenRemoved = uint256(int256(degenDelta));
        if (wethSpent > offered) revert SettlementMismatch(offered, wethSpent);
        if (wethSpent == 0) return abi.encode(uint256(0), uint256(0));

        Currency wethCurrency = _poolKey.currency1;
        poolManager.sync(wethCurrency);
        IERC20(weth).safeTransfer(address(poolManager), wethSpent);
        uint256 settled = poolManager.settle();
        if (settled != wethSpent) revert SettlementMismatch(wethSpent, settled);
        poolManager.take(_poolKey.currency0, address(this), degenRemoved);

        return abi.encode(wethSpent, degenRemoved);
    }
}
