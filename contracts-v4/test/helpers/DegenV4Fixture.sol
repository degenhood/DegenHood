// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

/// @notice Real PoolManager/router fixture that preserves the onchain compiler boundary.
/// @dev PoolManager creation code is compiled separately at its pinned exact 0.8.26 pragma and
///      loaded as an artifact; this fixture and DegenHood production code compile at 0.8.28.
abstract contract DegenV4Fixture is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 internal constant SQRT_PRICE_1_1 = 1 << 96;
    uint160 internal constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 internal constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    Currency internal currency0;
    Currency internal currency1;
    IPoolManager internal manager;
    PoolModifyLiquidityTest internal modifyLiquidityRouter;
    PoolSwapTest internal swapRouter;
    IAllowanceTransfer internal permit2;
    IPositionManager internal positionManager;
    PoolKey internal key;
    PoolId internal poolId;

    function _setUpV4Infrastructure() internal {
        _deployManagerAndRouters();
        MockERC20 tokenA = new MockERC20("TOKEN A", "A", 18);
        MockERC20 tokenB = new MockERC20("TOKEN B", "B", 18);
        _configureCurrencies(tokenA, tokenB);
    }

    function _setUpV4InfrastructureWithTokens(MockERC20 tokenA, MockERC20 tokenB) internal {
        _deployManagerAndRouters();
        _configureCurrencies(tokenA, tokenB);
    }

    function _setUpV4PositionManager() internal {
        bytes memory permit2Code = vm.getCode("out/Permit2.sol/Permit2.json");
        address permit2Address;
        assembly ("memory-safe") {
            permit2Address := create(0, add(permit2Code, 0x20), mload(permit2Code))
        }
        require(permit2Address != address(0), "Permit2 artifact deployment failed");
        permit2 = IAllowanceTransfer(permit2Address);

        bytes memory positionManagerCode = abi.encodePacked(
            vm.getCode("out/PositionManager.sol/PositionManager.json"),
            abi.encode(manager, permit2, uint256(100_000), address(0), Currency.unwrap(currency1))
        );
        address positionManagerAddress;
        assembly ("memory-safe") {
            positionManagerAddress := create(
                0,
                add(positionManagerCode, 0x20),
                mload(positionManagerCode)
            )
        }
        require(positionManagerAddress != address(0), "PositionManager artifact deployment failed");
        positionManager = IPositionManager(positionManagerAddress);
    }

    function _deployManagerAndRouters() private {
        bytes memory initCode = abi.encodePacked(
            vm.getCode("out/PoolManager.sol/PoolManager.json"), abi.encode(address(this))
        );
        address managerAddress;
        assembly ("memory-safe") {
            managerAddress := create(0, add(initCode, 0x20), mload(initCode))
        }
        require(managerAddress != address(0), "PoolManager artifact deployment failed");

        manager = IPoolManager(managerAddress);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        swapRouter = new PoolSwapTest(manager);
    }

    function _configureCurrencies(MockERC20 tokenA, MockERC20 tokenB) private {
        tokenA.mint(address(this), type(uint128).max);
        tokenB.mint(address(this), type(uint128).max);

        if (address(tokenA) < address(tokenB)) {
            (currency0, currency1) =
            (Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)));
        } else {
            (currency0, currency1) =
            (Currency.wrap(address(tokenB)), Currency.wrap(address(tokenA)));
        }

        tokenA.approve(address(modifyLiquidityRouter), type(uint256).max);
        tokenA.approve(address(swapRouter), type(uint256).max);
        tokenB.approve(address(modifyLiquidityRouter), type(uint256).max);
        tokenB.approve(address(swapRouter), type(uint256).max);
    }

    function _setUpPlainV4Pool(uint24 lpFee) internal {
        _setUpV4Infrastructure();
        _initializePool(IHooks(address(0)), lpFee, 60, SQRT_PRICE_1_1);
        _addLiquidity(-120, 120, 1e18);
    }

    function _initializePool(IHooks hooks, uint24 lpFee, int24 tickSpacing, uint160 sqrtPriceX96)
        internal
    {
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: lpFee,
            tickSpacing: tickSpacing,
            hooks: hooks
        });
        poolId = key.toId();
        manager.initialize(key, sqrtPriceX96);
    }

    function _addLiquidity(int24 tickLower, int24 tickUpper, int128 liquidityDelta) internal {
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidityDelta, salt: 0
            }),
            ""
        );
    }

    function swap(
        PoolKey memory poolKey,
        bool zeroForOne,
        int256 amountSpecified,
        bytes memory hookData
    ) internal returns (BalanceDelta) {
        return swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    function _currentLpFee() internal view returns (uint24 lpFee) {
        (,,, lpFee) = manager.getSlot0(poolId);
    }

    function _feeGrowthGlobals() internal view returns (uint256 feeGrowth0, uint256 feeGrowth1) {
        return manager.getFeeGrowthGlobals(poolId);
    }
}
