// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {IDegenSpyBuybackVault} from "../interfaces/IDegenSpyBuybackVault.sol";
import {IUniswapV3FactoryMinimal} from "../interfaces/IUniswapV3FactoryMinimal.sol";
import {IUniswapV3SwapPoolMinimal} from "../interfaces/IUniswapV3SwapPoolMinimal.sol";

/// @title Routerless raw-SPY $DEGEN buyback and removal-from-circulation vault
/// @notice Permissionlessly converts raw SPY through one pinned Uniswap v3 1% DEGEN/SPY pool.
/// @dev The one-percent boundary limits one call's self-impact; it is not an oracle or MEV shield.
contract DegenSpyBuybackVault is IDegenSpyBuybackVault, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address private constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    uint256 private constant ROBINHOOD_CHAIN_ID = 4663;
    address private constant LIVE_V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address private constant LIVE_DEGEN = 0x04d5D8a61DA0b6548B136412843aDBA55EbeaDE6;
    address private constant LIVE_SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    uint24 private constant POOL_FEE = 10_000;
    int24 private constant TICK_SPACING = 200;
    uint256 private constant Q128 = 1 << 128;
    uint256 private constant MAX_SAFE_INPUT = uint256(type(int256).max);

    // floor(sqrt(101 / 100) * 2^128). Rounding down makes the boundary conservative.
    uint256 private constant SQRT_ONE_PERCENT_X128 =
        341_979_546_361_605_312_568_969_099_661_698_692_653;

    IUniswapV3FactoryMinimal public immutable override v3Factory;
    address public immutable override degen;
    address public immutable override spy;

    uint256 public override lastFillBlock;
    uint256 public override totalRawSpySpent;
    uint256 public override totalDegenRemoved;

    address private _activePool;
    uint256 private _maximumSpy;
    uint256 private _paidSpy;
    bool private _swapping;

    constructor(IUniswapV3FactoryMinimal factory_, address degen_, address spy_) {
        address factoryAddress = address(factory_);
        if (
            factoryAddress == address(0) || factoryAddress.code.length == 0 || degen_ == address(0)
                || degen_.code.length == 0 || spy_ == address(0) || spy_.code.length == 0
                || degen_ >= spy_
        ) {
            revert InvalidAddress();
        }
        if (factory_.feeAmountTickSpacing(POOL_FEE) != TICK_SPACING) revert InvalidPool();
        if (
            block.chainid == ROBINHOOD_CHAIN_ID
                && (factoryAddress != LIVE_V3_FACTORY || degen_ != LIVE_DEGEN || spy_ != LIVE_SPY)
        ) {
            revert InvalidPool();
        }

        v3Factory = factory_;
        degen = degen_;
        spy = spy_;
    }

    function pool() public view override returns (address) {
        return v3Factory.getPool(degen, spy, POOL_FEE);
    }

    function poolFee() external pure override returns (uint24) {
        return POOL_FEE;
    }

    function tickSpacing() external pure override returns (int24) {
        return TICK_SPACING;
    }

    function burnSink() external pure override returns (address) {
        return BURN_ADDRESS;
    }

    function previewPriceLimit()
        public
        view
        override
        returns (uint160 sqrtPriceX96, uint160 sqrtPriceLimitX96)
    {
        address poolAddress = _validatedPool();
        if (poolAddress == address(0)) return (0, 0);
        (sqrtPriceX96,,,,,,) = IUniswapV3SwapPoolMinimal(poolAddress).slot0();
        if (sqrtPriceX96 == 0) return (0, 0);
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
        returns (uint256 rawSpySpent, uint256 degenRemoved)
    {
        uint256 startingSpy = IERC20(spy).balanceOf(address(this));
        if (startingSpy == 0) return (0, 0);
        if (lastFillBlock == block.number) revert AlreadyFilledThisBlock(block.number);

        address poolAddress = _validatedPool();
        if (poolAddress == address(0)) return (0, 0);
        IUniswapV3SwapPoolMinimal candidate = IUniswapV3SwapPoolMinimal(poolAddress);
        (uint160 sqrtPriceX96,,,,,, bool unlocked) = candidate.slot0();
        if (sqrtPriceX96 == 0 || !unlocked || candidate.liquidity() == 0) return (0, 0);

        uint160 sqrtPriceLimitX96 = priceLimitFor(sqrtPriceX96);
        uint256 offered = Math.min(startingSpy, MAX_SAFE_INPUT);
        uint256 burnBefore = IERC20(degen).balanceOf(BURN_ADDRESS);

        _activePool = poolAddress;
        _maximumSpy = offered;
        _paidSpy = 0;
        _swapping = true;
        (int256 amount0Delta, int256 amount1Delta) =
            candidate.swap(BURN_ADDRESS, false, int256(offered), sqrtPriceLimitX96, bytes(""));
        _swapping = false;

        if (amount0Delta > 0 || amount1Delta < 0 || (amount1Delta == 0 && amount0Delta != 0)) {
            revert InvalidSwapDelta(amount0Delta, amount1Delta);
        }
        rawSpySpent = uint256(amount1Delta);
        degenRemoved = uint256(-amount0Delta);
        if (rawSpySpent != _paidSpy || rawSpySpent > offered) {
            revert SettlementMismatch(_paidSpy, rawSpySpent);
        }

        uint256 endingSpy = IERC20(spy).balanceOf(address(this));
        if (endingSpy > startingSpy || startingSpy - endingSpy != rawSpySpent) {
            revert SettlementMismatch(rawSpySpent, startingSpy - Math.min(endingSpy, startingSpy));
        }
        uint256 burnAfter = IERC20(degen).balanceOf(BURN_ADDRESS);
        if (burnAfter < burnBefore || burnAfter - burnBefore != degenRemoved) {
            revert SettlementMismatch(degenRemoved, burnAfter - Math.min(burnAfter, burnBefore));
        }

        _activePool = address(0);
        _maximumSpy = 0;
        _paidSpy = 0;
        if (rawSpySpent == 0) return (0, 0);

        totalRawSpySpent += rawSpySpent;
        totalDegenRemoved += degenRemoved;
        lastFillBlock = block.number;
        emit BuybackExecuted(msg.sender, rawSpySpent, degenRemoved, endingSpy, sqrtPriceLimitX96);
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata)
        external
        override
    {
        if (!_swapping || msg.sender != _activePool) revert UnauthorizedCallback();
        if (amount0Delta > 0 || amount1Delta <= 0) {
            revert InvalidSwapDelta(amount0Delta, amount1Delta);
        }

        uint256 owed = uint256(amount1Delta);
        uint256 cumulative = _paidSpy + owed;
        if (cumulative > _maximumSpy) revert SettlementMismatch(_maximumSpy, cumulative);
        _paidSpy = cumulative;
        IERC20(spy).safeTransfer(msg.sender, owed);
    }

    function _validatedPool() private view returns (address poolAddress) {
        poolAddress = pool();
        if (poolAddress == address(0)) return address(0);
        if (poolAddress.code.length == 0) revert InvalidPool();

        IUniswapV3SwapPoolMinimal candidate = IUniswapV3SwapPoolMinimal(poolAddress);
        if (
            candidate.factory() != address(v3Factory) || candidate.token0() != degen
                || candidate.token1() != spy || candidate.fee() != POOL_FEE
                || candidate.tickSpacing() != TICK_SPACING
        ) {
            revert InvalidPool();
        }
    }
}
