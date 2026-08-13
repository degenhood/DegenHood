// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DegenHoodFeeLocker} from "../src/DegenHoodFeeLocker.sol";
import {DegenHoodV4Hook} from "../src/DegenHoodV4Hook.sol";
import {IDegenHoodV4Hook} from "../src/interfaces/IDegenHoodV4Hook.sol";
import {DegenFeeMath} from "../src/libraries/DegenFeeMath.sol";
import {DegenV4SwapHarness} from "./helpers/DegenV4SwapHarness.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Vm} from "forge-std/Vm.sol";

contract DegenV4SwapHarnessTest is DegenV4SwapHarness {
    uint24 private constant LP_FEE = 7000;
    int256 private constant EXACT_INPUT = -1e12;
    int256 private constant EXACT_OUTPUT = 1e12;

    function setUp() public {
        _setUpPlainV4Pool(LP_FEE);
    }

    function testHarnessExactInputWethBuyUsesRealPoolManager() public {
        SwapObservation memory observed = _quoteAndExecute(false, EXACT_INPUT, "");

        _assertBuy(observed);
        assertGt(observed.feeGrowth1After, observed.feeGrowth1Before);
        assertEq(observed.feeGrowth0After, observed.feeGrowth0Before);
    }

    function testHarnessExactOutputTokenBuyUsesRealPoolManager() public {
        SwapObservation memory observed = _quoteAndExecute(false, EXACT_OUTPUT, "");

        _assertBuy(observed);
        assertEq(observed.amount0Delta, int128(EXACT_OUTPUT));
        assertGt(observed.feeGrowth1After, observed.feeGrowth1Before);
    }

    function testHarnessExactInputTokenSellUsesRealPoolManager() public {
        SwapObservation memory observed = _quoteAndExecute(true, EXACT_INPUT, "");

        _assertSell(observed);
        assertGt(observed.feeGrowth0After, observed.feeGrowth0Before);
        assertEq(observed.feeGrowth1After, observed.feeGrowth1Before);
    }

    function testHarnessExactOutputWethSellUsesRealPoolManager() public {
        SwapObservation memory observed = _quoteAndExecute(true, EXACT_OUTPUT, "");

        _assertSell(observed);
        assertEq(observed.amount1Delta, int128(EXACT_OUTPUT));
        assertGt(observed.feeGrowth0After, observed.feeGrowth0Before);
    }

    function _assertBuy(SwapObservation memory observed) private pure {
        assertGt(observed.amount0Delta, 0);
        assertLt(observed.amount1Delta, 0);
        _assertCommon(observed);
    }

    function _assertSell(SwapObservation memory observed) private pure {
        assertLt(observed.amount0Delta, 0);
        assertGt(observed.amount1Delta, 0);
        _assertCommon(observed);
    }

    function _assertCommon(SwapObservation memory observed) private pure {
        assertEq(observed.traderCurrency0Change, observed.amount0Delta);
        assertEq(observed.traderCurrency1Change, observed.amount1Delta);
        assertEq(observed.quotedAmount0, observed.amount0Delta);
        assertEq(observed.quotedAmount1, observed.amount1Delta);
        assertEq(observed.lpFeeBefore, LP_FEE);
        assertEq(observed.lpFeeAfter, LP_FEE);
        assertEq(observed.routerManagerDelta0After, 0);
        assertEq(observed.routerManagerDelta1After, 0);
        assertEq(observed.hookCurrency0Change, 0);
        assertEq(observed.hookCurrency1Change, 0);
    }
}

contract DegenHoodV4HookRegistrationTest is DegenV4SwapHarness {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint24 private constant LP_FEE = 7000;
    int24 private constant TICK_SPACING = 200;
    int24 private constant INITIAL_TICK = -230_400;

    DegenHoodV4Hook private hook;
    address private token;
    address private weth;
    address private beneficiary = makeAddr("registrationBeneficiary");

    function setUp() public {
        _setUpV4Infrastructure();
        token = Currency.unwrap(currency0);
        weth = Currency.unwrap(currency1);
        hook = _deployHook(address(this), weth);
    }

    function test_register_onlyFactoryMayRegisterPool() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(IDegenHoodV4Hook.OnlyFactory.selector);
        hook.registerPool(token, beneficiary);
    }

    function test_register_rejectsInvalidTokensAndWrongOrder() public {
        vm.expectRevert(IDegenHoodV4Hook.InvalidToken.selector);
        hook.registerPool(address(0), beneficiary);

        vm.expectRevert(IDegenHoodV4Hook.InvalidToken.selector);
        hook.registerPool(weth, beneficiary);

        vm.expectRevert(IDegenHoodV4Hook.InvalidTokenOrder.selector);
        hook.registerPool(address(uint160(weth) + 1), beneficiary);

        vm.expectRevert(IDegenHoodV4Hook.InvalidBeneficiary.selector);
        hook.registerPool(token, address(0));

        vm.expectRevert(IDegenHoodV4Hook.InvalidBeneficiaryController.selector);
        hook.registerPool(token, beneficiary, address(0));
    }

    function test_register_recordsOnlyTheCanonicalWethPoolKey() public {
        PoolKey memory registeredKey = hook.registerPool(token, beneficiary);
        PoolId registeredPoolId = registeredKey.toId();
        IDegenHoodV4Hook.PoolConfig memory config = hook.getPoolConfig(registeredPoolId);

        assertEq(Currency.unwrap(registeredKey.currency0), token);
        assertEq(Currency.unwrap(registeredKey.currency1), weth);
        assertEq(registeredKey.fee, LPFeeLibrary.DYNAMIC_FEE_FLAG);
        assertEq(registeredKey.tickSpacing, TICK_SPACING);
        assertEq(address(registeredKey.hooks), address(hook));
        assertEq(config.token, token);
        assertEq(config.beneficiary, beneficiary);
        assertEq(config.beneficiaryController, address(this));
        assertTrue(config.registered);
        assertFalse(config.initialized);
        assertEq(config.initializedAt, 0);
        assertEq(PoolId.unwrap(hook.poolIdForToken(token)), PoolId.unwrap(registeredPoolId));
    }

    function test_register_duplicateRegistrationReverts() public {
        hook.registerPool(token, beneficiary);

        vm.expectRevert(IDegenHoodV4Hook.PoolAlreadyRegistered.selector);
        hook.registerPool(token, beneficiary);
    }

    function test_register_explicitControllerRemovesFactoryRecipientOverride() public {
        address controller = makeAddr("beneficiaryController");
        address replacement = makeAddr("replacementBeneficiary");
        PoolKey memory registeredKey = hook.registerPool(token, beneficiary, controller);

        assertEq(hook.getPoolConfig(registeredKey.toId()).beneficiaryController, controller);
        vm.expectRevert(IDegenHoodV4Hook.OnlyBeneficiaryController.selector);
        hook.updateBeneficiary(token, replacement);

        vm.prank(controller);
        hook.updateBeneficiary(token, replacement);
        assertEq(hook.getPoolConfig(registeredKey.toId()).beneficiary, replacement);
    }

    function test_initialize_rejectsUnregisteredOrSubstitutedPoolKey() public {
        PoolKey memory registeredKey = hook.registerPool(token, beneficiary);
        PoolKey memory substitutedKey = PoolKey({
            currency0: registeredKey.currency0,
            currency1: registeredKey.currency1,
            fee: registeredKey.fee,
            tickSpacing: 400,
            hooks: registeredKey.hooks
        });

        _expectWrappedBeforeInitialize(IDegenHoodV4Hook.PoolNotRegistered.selector);
        manager.initialize(substitutedKey, TickMath.getSqrtPriceAtTick(INITIAL_TICK));

        assertTrue(hook.getPoolConfig(registeredKey.toId()).registered);
        _expectWrappedBeforeInitialize(IDegenHoodV4Hook.OnlyFactory.selector);
        vm.prank(address(0xBEEF));
        manager.initialize(registeredKey, TickMath.getSqrtPriceAtTick(INITIAL_TICK));
    }

    function test_initialize_rejectsSubstitutedInitialPrice() public {
        PoolKey memory registeredKey = hook.registerPool(token, beneficiary);

        _expectWrappedBeforeInitialize(IDegenHoodV4Hook.InvalidInitialPrice.selector);
        manager.initialize(registeredKey, SQRT_PRICE_1_1);
    }

    function test_initialize_setsTimestampExactlyOnceAndFixedLpFee() public {
        vm.warp(1_234_567);
        PoolKey memory registeredKey = hook.registerPool(token, beneficiary);
        PoolId registeredPoolId = registeredKey.toId();
        manager.initialize(registeredKey, TickMath.getSqrtPriceAtTick(INITIAL_TICK));

        IDegenHoodV4Hook.PoolConfig memory config = hook.getPoolConfig(registeredPoolId);
        (uint160 sqrtPriceX96, int24 tick,, uint24 lpFee) = manager.getSlot0(registeredPoolId);
        assertTrue(config.initialized);
        assertEq(config.initializedAt, block.timestamp);
        assertEq(sqrtPriceX96, TickMath.getSqrtPriceAtTick(INITIAL_TICK));
        assertEq(tick, INITIAL_TICK);
        assertEq(lpFee, LP_FEE);

        vm.warp(block.timestamp + 10);
        vm.expectRevert();
        manager.initialize(registeredKey, TickMath.getSqrtPriceAtTick(INITIAL_TICK));
        assertEq(hook.getPoolConfig(registeredPoolId).initializedAt, 1_234_567);
    }

    function test_lpFee_isRestoredToPointSevenPercentBeforeEverySwap() public {
        key = hook.registerPool(token, beneficiary);
        poolId = key.toId();
        manager.initialize(key, TickMath.getSqrtPriceAtTick(INITIAL_TICK));
        _addLiquidity(INITIAL_TICK, -120_000, 1e18);

        vm.prank(address(hook));
        manager.updateDynamicLPFee(key, 50_000);
        assertEq(_currentLpFee(), 50_000);

        swap(key, false, -1e12, "");
        assertEq(_currentLpFee(), LP_FEE);
    }

    function test_register_hookPermissionsExactlyMatchCallbacksAndAddressBits() public view {
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertTrue(permissions.beforeInitialize);
        assertTrue(permissions.afterInitialize);
        assertFalse(permissions.beforeAddLiquidity);
        assertFalse(permissions.afterAddLiquidity);
        assertFalse(permissions.beforeRemoveLiquidity);
        assertFalse(permissions.afterRemoveLiquidity);
        assertTrue(permissions.beforeSwap);
        assertTrue(permissions.afterSwap);
        assertFalse(permissions.beforeDonate);
        assertFalse(permissions.afterDonate);
        assertTrue(permissions.beforeSwapReturnDelta);
        assertTrue(permissions.afterSwapReturnDelta);
        assertFalse(permissions.afterAddLiquidityReturnDelta);
        assertFalse(permissions.afterRemoveLiquidityReturnDelta);

        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, _hookFlags());
    }

    function _deployHook(address factory, address wrappedEther)
        private
        returns (DegenHoodV4Hook deployed)
    {
        DegenHoodFeeLocker locker = new DegenHoodFeeLocker(address(this), wrappedEther);
        address treasury = address(0xD00D);
        bytes memory constructorArgs =
            abi.encode(manager, factory, wrappedEther, treasury, address(locker));
        (address expected, bytes32 salt) = HookMiner.find(
            address(this), _hookFlags(), type(DegenHoodV4Hook).creationCode, constructorArgs
        );
        deployed = new DegenHoodV4Hook{salt: salt}(
            manager, factory, wrappedEther, treasury, address(locker)
        );
        assertEq(address(deployed), expected);
    }

    function _hookFlags() private pure returns (uint160) {
        return uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
    }

    function _expectWrappedBeforeInitialize(bytes4 reason) private {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(reason),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }
}

contract DegenHoodV4HookPermanentFeeTest is DegenV4SwapHarness {
    using PoolIdLibrary for PoolKey;

    uint256 private constant PERMANENT_RATE = 5000;
    uint24 private constant LP_FEE = 7000;
    int24 private constant INITIAL_TICK = -230_400;
    int256 private constant EXACT_INPUT_BUY_WETH = -1e12;
    int256 private constant EXACT_OUTPUT_BUY_TOKEN = 1e16;
    int256 private constant EXACT_INPUT_SELL_TOKEN = -1e16;
    int256 private constant EXACT_OUTPUT_SELL_WETH = 1e6;

    DegenHoodV4Hook private hook;
    address private token;
    address private weth;
    address private beneficiary = makeAddr("permanentBeneficiary");

    struct FeeEvent {
        uint256 grossWethBasis;
        uint256 totalRate;
        uint256 totalFee;
        uint256 permanentFee;
        uint256 temporaryFee;
        uint256 beneficiaryCredit;
        uint256 protocolCredit;
        uint256 roundingDust;
        uint256 cumulativeAmount;
    }

    function setUp() public {
        _setUpV4Infrastructure();
        token = Currency.unwrap(currency0);
        weth = Currency.unwrap(currency1);
        hook = _deployHook();

        vm.warp(1000);
        key = hook.registerPool(token, beneficiary);
        poolId = key.toId();
        manager.initialize(key, TickMath.getSqrtPriceAtTick(INITIAL_TICK));
        _addLiquidity(INITIAL_TICK, -120_000, 1e18);
        vm.warp(block.timestamp + 30);
    }

    function test_permanentFee_exactInputBuyChargesPointFivePercentInWeth() public {
        uint256 grossWeth = uint256(-EXACT_INPUT_BUY_WETH);
        uint256 expectedFee = DegenFeeMath.feeFromGross(grossWeth, PERMANENT_RATE);
        vm.expectEmit(true, false, false, true, address(hook));
        emit IDegenHoodV4Hook.WethHookFeeAccrued(
            poolId,
            beneficiary,
            grossWeth,
            PERMANENT_RATE,
            expectedFee,
            expectedFee,
            0,
            0,
            expectedFee,
            0,
            expectedFee
        );

        SwapObservation memory observed = _quoteAndExecute(false, EXACT_INPUT_BUY_WETH, "");

        assertEq(observed.amount1Delta, EXACT_INPUT_BUY_WETH);
        assertGt(observed.amount0Delta, 0);
        _assertFeeCommon(observed, expectedFee);
        assertGt(observed.feeGrowth1After, observed.feeGrowth1Before);
        assertEq(observed.feeGrowth0After, observed.feeGrowth0Before);
    }

    function test_permanentFee_exactOutputBuyGrossesUpWethWithCeilingRounding() public {
        vm.recordLogs();
        SwapObservation memory observed = _quoteAndExecute(false, EXACT_OUTPUT_BUY_TOKEN, "");
        uint256 fee = _hookClaimIncrease(observed);
        uint256 grossWeth = uint256(-int256(observed.amount1Delta));
        uint256 poolWeth = grossWeth - fee;
        FeeEvent memory accrued = _recordedFeeEvent();

        assertEq(observed.amount0Delta, EXACT_OUTPUT_BUY_TOKEN);
        assertEq(DegenFeeMath.grossFromNet(poolWeth, PERMANENT_RATE), grossWeth);
        assertEq(fee, grossWeth - poolWeth);
        _assertFeeEvent(accrued, grossWeth, fee);
        _assertFeeCommon(observed, fee);
        assertGt(observed.feeGrowth1After, observed.feeGrowth1Before);
    }

    function test_permanentFee_exactInputSellDeductsPointFivePercentFromWethOutput() public {
        _primeForSell();
        vm.recordLogs();
        SwapObservation memory observed = _quoteAndExecute(true, EXACT_INPUT_SELL_TOKEN, "");
        uint256 fee = _hookClaimIncrease(observed);
        uint256 netWeth = uint256(int256(observed.amount1Delta));
        uint256 grossWeth = netWeth + fee;
        FeeEvent memory accrued = _recordedFeeEvent();

        assertEq(observed.amount0Delta, EXACT_INPUT_SELL_TOKEN);
        assertEq(DegenFeeMath.feeFromGross(grossWeth, PERMANENT_RATE), fee);
        _assertFeeEvent(accrued, grossWeth, fee);
        _assertFeeCommon(observed, fee);
        assertGt(observed.feeGrowth0After, observed.feeGrowth0Before);
        assertEq(observed.feeGrowth1After, observed.feeGrowth1Before);
    }

    function test_permanentFee_exactOutputSellGrossesUpPoolWethOutput() public {
        _primeForSell();
        vm.recordLogs();
        SwapObservation memory observed = _quoteAndExecute(true, EXACT_OUTPUT_SELL_WETH, "");
        uint256 fee = _hookClaimIncrease(observed);
        uint256 netWeth = uint256(EXACT_OUTPUT_SELL_WETH);
        uint256 grossWeth = netWeth + fee;
        FeeEvent memory accrued = _recordedFeeEvent();

        assertEq(observed.amount1Delta, EXACT_OUTPUT_SELL_WETH);
        assertEq(DegenFeeMath.grossFromNet(netWeth, PERMANENT_RATE), grossWeth);
        _assertFeeEvent(accrued, grossWeth, fee);
        _assertFeeCommon(observed, fee);
        assertGt(observed.feeGrowth0After, observed.feeGrowth0Before);
    }

    function testFuzz_permanentFee_allFourModes(uint8 rawMode, uint96 rawAmount) public {
        uint8 mode = rawMode % 4;
        SwapObservation memory observed;
        uint256 fee;

        if (mode == 0) {
            uint256 grossWeth = bound(uint256(rawAmount), 1e6, 1e15);
            observed = _quoteAndExecute(false, -int256(grossWeth), "");
            fee = DegenFeeMath.feeFromGross(grossWeth, PERMANENT_RATE);
            assertEq(observed.amount1Delta, -int256(grossWeth));
        } else if (mode == 1) {
            uint256 tokenOut = bound(uint256(rawAmount), 1e12, 1e19);
            observed = _quoteAndExecute(false, int256(tokenOut), "");
            fee = _hookClaimIncrease(observed);
            uint256 grossWeth = uint256(-int256(observed.amount1Delta));
            assertEq(DegenFeeMath.grossFromNet(grossWeth - fee, PERMANENT_RATE), grossWeth);
        } else if (mode == 2) {
            _primeForSell();
            uint256 tokenIn = bound(uint256(rawAmount), 1e15, 1e19);
            observed = _quoteAndExecute(true, -int256(tokenIn), "");
            fee = _hookClaimIncrease(observed);
            uint256 grossWeth = uint256(int256(observed.amount1Delta)) + fee;
            assertEq(DegenFeeMath.feeFromGross(grossWeth, PERMANENT_RATE), fee);
        } else {
            _primeForSell();
            uint256 netWeth = bound(uint256(rawAmount), 1e3, 1e8);
            observed = _quoteAndExecute(true, int256(netWeth), "");
            fee = _hookClaimIncrease(observed);
            assertEq(DegenFeeMath.grossFromNet(netWeth, PERMANENT_RATE), netWeth + fee);
        }

        _assertFeeCommon(observed, fee);
        assertEq(hook.totalWethFeesAccrued(poolId), observed.hookClaim1After);
    }

    function _assertFeeCommon(SwapObservation memory observed, uint256 expectedFee) private pure {
        assertGt(expectedFee, 0);
        assertEq(_hookClaimIncrease(observed), expectedFee);
        assertEq(observed.hookClaim0After, observed.hookClaim0Before);
        assertEq(observed.hookCurrency0Change, 0);
        assertEq(observed.hookCurrency1Change, 0);
        assertEq(observed.traderCurrency0Change, observed.amount0Delta);
        assertEq(observed.traderCurrency1Change, observed.amount1Delta);
        assertEq(observed.quotedAmount0, observed.amount0Delta);
        assertEq(observed.quotedAmount1, observed.amount1Delta);
        assertEq(observed.lpFeeBefore, LP_FEE);
        assertEq(observed.lpFeeAfter, LP_FEE);
        assertEq(observed.routerManagerDelta0After, 0);
        assertEq(observed.routerManagerDelta1After, 0);
    }

    function _assertFeeEvent(FeeEvent memory accrued, uint256 grossWeth, uint256 fee) private view {
        assertEq(accrued.grossWethBasis, grossWeth);
        assertEq(accrued.totalRate, PERMANENT_RATE);
        assertEq(accrued.totalFee, fee);
        assertEq(accrued.permanentFee, DegenFeeMath.feeFromGross(grossWeth, PERMANENT_RATE));
        assertEq(accrued.temporaryFee, 0);
        assertEq(accrued.beneficiaryCredit, 0);
        assertEq(accrued.protocolCredit, fee);
        assertEq(accrued.roundingDust, fee - accrued.permanentFee);
        assertEq(accrued.cumulativeAmount, hook.totalWethFeesAccrued(poolId));
        assertEq(
            accrued.totalFee, accrued.permanentFee + accrued.temporaryFee + accrued.roundingDust
        );
    }

    function _recordedFeeEvent() private returns (FeeEvent memory accrued) {
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 signature = keccak256(
            "WethHookFeeAccrued(bytes32,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)"
        );
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].emitter != address(hook) || entries[i].topics[0] != signature) continue;
            assertEq(entries[i].topics[1], PoolId.unwrap(poolId));
            assertEq(address(uint160(uint256(entries[i].topics[2]))), beneficiary);
            (
                accrued.grossWethBasis,
                accrued.totalRate,
                accrued.totalFee,
                accrued.permanentFee,
                accrued.temporaryFee,
                accrued.beneficiaryCredit,
                accrued.protocolCredit,
                accrued.roundingDust,
                accrued.cumulativeAmount
            ) =
                abi.decode(
                    entries[i].data,
                    (
                        uint256,
                        uint256,
                        uint256,
                        uint256,
                        uint256,
                        uint256,
                        uint256,
                        uint256,
                        uint256
                    )
                );
            return accrued;
        }
        revert("WethHookFeeAccrued not found");
    }

    function _hookClaimIncrease(SwapObservation memory observed) private pure returns (uint256) {
        return observed.hookClaim1After - observed.hookClaim1Before;
    }

    function _primeForSell() private {
        swap(key, false, -1e12, "");
    }

    function _deployHook() private returns (DegenHoodV4Hook deployed) {
        DegenHoodFeeLocker locker = new DegenHoodFeeLocker(address(this), weth);
        address treasury = address(0xD00D);
        bytes memory constructorArgs =
            abi.encode(manager, address(this), weth, treasury, address(locker));
        (address expected, bytes32 salt) = HookMiner.find(
            address(this), _hookFlags(), type(DegenHoodV4Hook).creationCode, constructorArgs
        );
        deployed = new DegenHoodV4Hook{salt: salt}(
            manager, address(this), weth, treasury, address(locker)
        );
        assertEq(address(deployed), expected);
    }

    function _hookFlags() private pure returns (uint160) {
        return uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
    }
}

contract DegenHoodV4HookLaunchFeeTest is DegenV4SwapHarness {
    using PoolIdLibrary for PoolKey;

    uint256 private constant INITIAL_TOTAL_RATE = 800_000;
    int24 private constant INITIAL_TICK = -230_400;

    DegenHoodV4Hook private hook;
    address private token;
    address private weth;
    address private beneficiary = makeAddr("launchBeneficiary");

    function setUp() public {
        _setUpV4Infrastructure();
        token = Currency.unwrap(currency0);
        weth = Currency.unwrap(currency1);
        hook = _deployHook();

        vm.warp(10_000);
        key = hook.registerPool(token, beneficiary);
        poolId = key.toId();
        manager.initialize(key, TickMath.getSqrtPriceAtTick(INITIAL_TICK));
        _addLiquidity(INITIAL_TICK, -120_000, 1e18);
    }

    function test_launchFee_exactInputBuyStartsAtEightyPercent() public {
        uint256 grossWeth = 1e12;
        uint256 expectedFee = DegenFeeMath.feeFromGross(grossWeth, INITIAL_TOTAL_RATE);
        DegenFeeMath.FeeSplit memory split =
            DegenFeeMath.splitHookFee(grossWeth, INITIAL_TOTAL_RATE);
        vm.expectEmit(true, false, false, true, address(hook));
        emit IDegenHoodV4Hook.WethHookFeeAccrued(
            poolId,
            beneficiary,
            grossWeth,
            INITIAL_TOTAL_RATE,
            split.totalHookFee,
            split.permanentFee,
            split.temporaryFee,
            split.beneficiaryTemporary,
            split.protocolCredit,
            split.roundingDust,
            split.totalHookFee
        );

        SwapObservation memory observed = _quoteAndExecute(false, -int256(grossWeth), "");

        assertEq(observed.hookClaim1After - observed.hookClaim1Before, expectedFee);
        assertEq(observed.amount1Delta, -int256(grossWeth));
    }

    function test_launchFee_exactInputBuyMatchesEveryBoundary() public {
        uint256 grossWeth = 1e12;
        uint256 baseline = vm.snapshotState();
        uint256[12] memory points = _elapsedPoints();

        for (uint256 i; i < points.length; ++i) {
            assertTrue(vm.revertToState(baseline));
            vm.warp(10_000 + points[i]);
            SwapObservation memory observed = _quoteAndExecute(false, -int256(grossWeth), "");
            uint256 rate = DegenFeeMath.totalHookRate(10_000, block.timestamp);
            assertEq(_feeIncrease(observed), DegenFeeMath.feeFromGross(grossWeth, rate));
            assertEq(observed.amount1Delta, -int256(grossWeth));
        }
    }

    function test_launchFee_exactOutputBuyMatchesEveryBoundary() public {
        uint256 tokenOut = 1e16;
        uint256 baseline = vm.snapshotState();
        uint256[12] memory points = _elapsedPoints();

        for (uint256 i; i < points.length; ++i) {
            assertTrue(vm.revertToState(baseline));
            vm.warp(10_000 + points[i]);
            SwapObservation memory observed = _quoteAndExecute(false, int256(tokenOut), "");
            uint256 fee = _feeIncrease(observed);
            uint256 grossWeth = uint256(-int256(observed.amount1Delta));
            uint256 rate = DegenFeeMath.totalHookRate(10_000, block.timestamp);
            assertEq(DegenFeeMath.grossFromNet(grossWeth - fee, rate), grossWeth);
            assertEq(observed.amount0Delta, int256(tokenOut));
        }
    }

    function test_launchFee_exactInputSellMatchesEveryBoundary() public {
        uint256 tokenIn = 1e16;
        uint256 baseline = vm.snapshotState();
        uint256[12] memory points = _elapsedPoints();

        for (uint256 i; i < points.length; ++i) {
            assertTrue(vm.revertToState(baseline));
            vm.warp(10_000 + points[i]);
            _primeForSell();
            SwapObservation memory observed = _quoteAndExecute(true, -int256(tokenIn), "");
            uint256 fee = _feeIncrease(observed);
            uint256 grossWeth = uint256(int256(observed.amount1Delta)) + fee;
            uint256 rate = DegenFeeMath.totalHookRate(10_000, block.timestamp);
            assertEq(DegenFeeMath.feeFromGross(grossWeth, rate), fee);
            assertEq(observed.amount0Delta, -int256(tokenIn));
        }
    }

    function test_launchFee_exactOutputSellMatchesEveryBoundary() public {
        uint256 netWeth = 1e6;
        uint256 baseline = vm.snapshotState();
        uint256[12] memory points = _elapsedPoints();

        for (uint256 i; i < points.length; ++i) {
            assertTrue(vm.revertToState(baseline));
            vm.warp(10_000 + points[i]);
            _primeForSell();
            SwapObservation memory observed = _quoteAndExecute(true, int256(netWeth), "");
            uint256 fee = _feeIncrease(observed);
            uint256 rate = DegenFeeMath.totalHookRate(10_000, block.timestamp);
            assertEq(DegenFeeMath.grossFromNet(netWeth, rate), netWeth + fee);
            assertEq(observed.amount1Delta, int256(netWeth));
        }
    }

    function testFuzz_launchFee_allModesPreserveSplitAndBacking(
        uint8 rawMode,
        uint32 rawElapsed,
        uint96 rawAmount
    ) public {
        uint8 mode = rawMode % 4;
        uint256 elapsed = bound(uint256(rawElapsed), 0, 1_000_000);
        vm.warp(10_000 + elapsed);

        if (mode >= 2) _primeForSell();
        uint256 protocolBefore = hook.pendingProtocolWeth(poolId);
        uint256 beneficiaryBefore = hook.pendingBeneficiaryWeth(poolId, beneficiary);
        uint256 pendingBefore = hook.pendingTotalWeth(poolId);

        SwapObservation memory observed;
        DegenFeeMath.FeeSplit memory split;
        uint256 totalRate = DegenFeeMath.totalHookRate(10_000, block.timestamp);
        if (mode == 0) {
            uint256 grossWeth = bound(uint256(rawAmount), 1e6, 1e15);
            observed = _quoteAndExecute(false, -int256(grossWeth), "");
            split = DegenFeeMath.splitHookFee(grossWeth, totalRate);
        } else if (mode == 1) {
            uint256 tokenOut = bound(uint256(rawAmount), 1e12, 1e19);
            observed = _quoteAndExecute(false, int256(tokenOut), "");
            uint256 grossWeth = uint256(-int256(observed.amount1Delta));
            uint256 realizedFee = _feeIncrease(observed);
            split = DegenFeeMath.splitRealizedHookFee(grossWeth, totalRate, realizedFee);
        } else if (mode == 2) {
            uint256 tokenIn = bound(uint256(rawAmount), 1e15, 1e19);
            observed = _quoteAndExecute(true, -int256(tokenIn), "");
            uint256 grossWeth = uint256(int256(observed.amount1Delta)) + _feeIncrease(observed);
            split = DegenFeeMath.splitHookFee(grossWeth, totalRate);
        } else {
            uint256 netWeth = bound(uint256(rawAmount), 1e3, 1e8);
            observed = _quoteAndExecute(true, int256(netWeth), "");
            uint256 grossWeth = netWeth + _feeIncrease(observed);
            split = DegenFeeMath.splitRealizedHookFee(grossWeth, totalRate, grossWeth - netWeth);
        }

        assertEq(_feeIncrease(observed), split.totalHookFee);
        assertEq(hook.pendingProtocolWeth(poolId) - protocolBefore, split.protocolCredit);
        assertEq(
            hook.pendingBeneficiaryWeth(poolId, beneficiary) - beneficiaryBefore,
            split.beneficiaryTemporary
        );
        assertEq(hook.pendingTotalWeth(poolId) - pendingBefore, split.totalHookFee);
        assertEq(manager.balanceOf(address(hook), currency1.toId()), hook.pendingTotalWeth(poolId));
    }

    function test_launchFee_timestampCannotPrecedeInitialization() public {
        vm.warp(9999);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(DegenFeeMath.InvalidTimestamp.selector, 9999, 10_000),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap(key, false, -1e12, "");
    }

    function test_launchFee_timestampNeverRestartsAndHasNoAdminScheduleSurface() public {
        swap(key, false, -1e12, "");
        vm.warp(10_031);
        swap(key, false, -1e12, "");

        assertEq(hook.getPoolConfig(poolId).initializedAt, 10_000);
        (bool setRate,) = address(hook).call(abi.encodeWithSignature("setLaunchFee(uint256)", 1));
        (bool restart,) = address(hook)
            .call(abi.encodeWithSignature("restartLaunchFee(bytes32)", PoolId.unwrap(poolId)));
        (bool setDuration,) =
            address(hook).call(abi.encodeWithSignature("setLaunchDuration(uint256)", 1));
        assertFalse(setRate);
        assertFalse(restart);
        assertFalse(setDuration);
        assertEq(hook.getPoolConfig(poolId).initializedAt, 10_000);
    }

    function _feeIncrease(SwapObservation memory observed) private pure returns (uint256) {
        return observed.hookClaim1After - observed.hookClaim1Before;
    }

    function _primeForSell() private {
        swap(key, false, -1e12, "");
    }

    function _elapsedPoints() private pure returns (uint256[12] memory points) {
        points = [uint256(0), 1, 3, 5, 10, 15, 20, 25, 29, 30, 31, type(uint32).max];
    }

    function _deployHook() private returns (DegenHoodV4Hook deployed) {
        DegenHoodFeeLocker locker = new DegenHoodFeeLocker(address(this), weth);
        address treasury = address(0xD00D);
        bytes memory constructorArgs =
            abi.encode(manager, address(this), weth, treasury, address(locker));
        (address expected, bytes32 salt) = HookMiner.find(
            address(this), _hookFlags(), type(DegenHoodV4Hook).creationCode, constructorArgs
        );
        deployed = new DegenHoodV4Hook{salt: salt}(
            manager, address(this), weth, treasury, address(locker)
        );
        assertEq(address(deployed), expected);
    }

    function _hookFlags() private pure returns (uint160) {
        return uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
    }
}
