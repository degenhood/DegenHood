// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {IUniswapV3FactoryMinimal} from "../../src/interfaces/IUniswapV3FactoryMinimal.sol";
import {
    IUniswapV3SwapCallbackMinimal,
    IUniswapV3SwapPoolMinimal
} from "../../src/interfaces/IUniswapV3SwapPoolMinimal.sol";

contract DegenSpyVaultToken is ERC20 {
    address public blockedRecipient;

    error BlockedRecipient(address recipient);

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }

    function setBlockedRecipient(address recipient) external {
        blockedRecipient = recipient;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to == blockedRecipient) revert BlockedRecipient(to);
        super._update(from, to, amount);
    }
}

contract UniswapV3SwapPoolMock is IUniswapV3SwapPoolMinimal {
    using SafeERC20 for IERC20;

    address public immutable override factory;
    address public immutable override token0;
    address public immutable override token1;
    uint24 public immutable override fee;
    int24 public immutable override tickSpacing;

    uint160 private _sqrtPriceX96;
    int24 private _tick;
    uint128 public override liquidity;
    int24 public upperTick;
    bool private _unlocked = true;

    error InvalidSwap();
    error InsufficientSettlement(uint256 expected, uint256 actual);
    error OnlyFactory();

    constructor(
        address factory_,
        address token0_,
        address token1_,
        uint24 fee_,
        int24 tickSpacing_,
        uint160 sqrtPriceX96_,
        uint128 liquidity_,
        int24 upperTick_
    ) {
        factory = factory_;
        token0 = token0_;
        token1 = token1_;
        fee = fee_;
        tickSpacing = tickSpacing_;
        _sqrtPriceX96 = sqrtPriceX96_;
        if (sqrtPriceX96_ != 0) _tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96_);
        liquidity = liquidity_;
        upperTick = upperTick_;
    }

    function setLiquidity(uint128 liquidity_) external {
        if (msg.sender != factory) revert OnlyFactory();
        liquidity = liquidity_;
    }

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        )
    {
        return (_sqrtPriceX96, _tick, 0, 1, 1, 0, _unlocked);
    }

    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1) {
        if (
            !_unlocked || recipient == address(0) || zeroForOne || amountSpecified <= 0
                || liquidity == 0 || _sqrtPriceX96 == 0 || sqrtPriceLimitX96 <= _sqrtPriceX96
        ) revert InvalidSwap();

        uint160 rangeEnd = TickMath.getSqrtPriceAtTick(upperTick);
        uint160 target = sqrtPriceLimitX96 < rangeEnd ? sqrtPriceLimitX96 : rangeEnd;
        (uint160 next, uint256 amountIn, uint256 amountOut, uint256 feeAmount) =
            SwapMath.computeSwapStep(_sqrtPriceX96, target, liquidity, -amountSpecified, fee);
        uint256 owed = amountIn + feeAmount;
        if (owed == 0) revert InvalidSwap();

        _unlocked = false;
        _sqrtPriceX96 = next;
        _tick = TickMath.getTickAtSqrtPrice(next);
        if (amountOut != 0) IERC20(token0).safeTransfer(recipient, amountOut);
        uint256 beforeBalance = IERC20(token1).balanceOf(address(this));
        IUniswapV3SwapCallbackMinimal(msg.sender)
            .uniswapV3SwapCallback(-int256(amountOut), int256(owed), data);
        uint256 received = IERC20(token1).balanceOf(address(this)) - beforeBalance;
        if (received != owed) revert InsufficientSettlement(owed, received);
        _unlocked = true;

        return (-int256(amountOut), int256(owed));
    }
}

    contract UniswapV3SwapFactoryMock is IUniswapV3FactoryMinimal {
        address public immutable override owner = address(this);
        mapping(uint24 fee => int24 spacing) public override feeAmountTickSpacing;
        mapping(bytes32 key => address poolAddress) private _pools;

        constructor() {
            feeAmountTickSpacing[3000] = 60;
            feeAmountTickSpacing[10_000] = 200;
        }

        function getPool(address tokenA, address tokenB, uint24 fee)
            external
            view
            override
            returns (address)
        {
            (address token0, address token1) = _sort(tokenA, tokenB);
            return _pools[keccak256(abi.encode(token0, token1, fee))];
        }

        function createPool(
            address tokenA,
            address tokenB,
            uint24 fee,
            uint160 sqrtPriceX96,
            uint128 liquidity,
            int24 upperTick
        ) external returns (address poolAddress) {
            (address token0, address token1) = _sort(tokenA, tokenB);
            int24 spacing = feeAmountTickSpacing[fee];
            poolAddress = address(
                new UniswapV3SwapPoolMock(
                    address(this), token0, token1, fee, spacing, sqrtPriceX96, liquidity, upperTick
                )
            );
            _pools[keccak256(abi.encode(token0, token1, fee))] = poolAddress;
        }

        function setPool(address tokenA, address tokenB, uint24 fee, address poolAddress) external {
            (address token0, address token1) = _sort(tokenA, tokenB);
            _pools[keccak256(abi.encode(token0, token1, fee))] = poolAddress;
        }

        function setTickSpacing(uint24 fee, int24 spacing) external {
            feeAmountTickSpacing[fee] = spacing;
        }

        function setLiquidity(address poolAddress, uint128 liquidity) external {
            UniswapV3SwapPoolMock(poolAddress).setLiquidity(liquidity);
        }

        function _sort(address tokenA, address tokenB)
            private
            pure
            returns (address token0, address token1)
        {
            return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        }
    }
