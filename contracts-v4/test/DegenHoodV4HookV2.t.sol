// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DegenHoodFeeLocker} from "../src/DegenHoodFeeLocker.sol";
import {DegenHoodV4HookV2} from "../src/DegenHoodV4HookV2.sol";
import {DegenFeeMath} from "../src/libraries/DegenFeeMath.sol";
import {DegenV4SwapHarness} from "./helpers/DegenV4SwapHarness.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

contract DegenHoodV4HookV2Test is DegenV4SwapHarness {
    using PoolIdLibrary for PoolKey;

    int24 private constant INITIAL_TICK = -230_400;

    DegenHoodFeeLocker private feeLocker;
    DegenHoodV4HookV2 private hook;
    address private beneficiary = makeAddr("v2Beneficiary");
    address private treasury = makeAddr("v2Treasury");

    function setUp() public {
        _setUpV4Infrastructure();
        address weth = Currency.unwrap(currency1);
        feeLocker = new DegenHoodFeeLocker(address(this), weth);
        bytes memory constructorArgs =
            abi.encode(manager, address(this), weth, treasury, address(feeLocker));
        (address expected, bytes32 salt) = HookMiner.find(
            address(this), _hookFlags(), type(DegenHoodV4HookV2).creationCode, constructorArgs
        );
        hook = new DegenHoodV4HookV2{salt: salt}(
            manager, address(this), weth, treasury, address(feeLocker)
        );
        assertEq(address(hook), expected);
        feeLocker.setDepositor(address(hook), true);

        vm.warp(10_000);
        key = hook.registerPool(Currency.unwrap(currency0), beneficiary);
        poolId = key.toId();
        manager.initialize(key, TickMath.getSqrtPriceAtTick(INITIAL_TICK));
        _addLiquidity(INITIAL_TICK, -120_000, 1e18);
        // A second position crosses the initial tick so sell-mode tests do not need a
        // fee-bearing buy to seed WETH liquidity first.
        _addLiquidity(INITIAL_TICK - 200, -120_000, 1e18);
    }

    function test_v2ExposesGlobalProtocolAndPerPoolBeneficiaryAccounting() public view {
        assertEq(hook.pendingProtocolWeth(), 0);
        assertEq(hook.totalProtocolWethAccrued(poolId), 0);
        assertEq(hook.totalProtocolWethSwept(), 0);
        assertEq(hook.pendingBeneficiaryTotalWeth(poolId), 0);
    }

    function test_v2LaunchWindowAccrualSeparatesProtocolAndBeneficiaryWeth() public {
        uint256 grossWeth = 1e12;
        uint256 rate = DegenFeeMath.totalHookRate(10_000, 10_000);
        DegenFeeMath.FeeSplit memory split = DegenFeeMath.splitHookFee(grossWeth, rate);

        SwapObservation memory observed = _quoteAndExecute(false, -int256(grossWeth), "");

        assertEq(observed.hookClaim0After - observed.hookClaim0Before, 0);
        assertEq(observed.hookClaim1After - observed.hookClaim1Before, split.totalHookFee);
        assertEq(hook.pendingProtocolWeth(), split.protocolCredit);
        assertEq(hook.totalProtocolWethAccrued(poolId), split.protocolCredit);
        assertEq(hook.pendingBeneficiaryWeth(poolId, beneficiary), split.beneficiaryTemporary);
        assertEq(hook.pendingBeneficiaryTotalWeth(poolId), split.beneficiaryTemporary);
    }

    function test_v2PermanentAccrualChargesOnlyWethInAllFourModes() public {
        uint256 baseline = vm.snapshotState();
        vm.warp(10_030);
        _assertPermanentMode(0, -int256(1e12));

        assertTrue(vm.revertToState(baseline));
        vm.warp(10_030);
        _assertPermanentMode(1, int256(1e16));

        assertTrue(vm.revertToState(baseline));
        vm.warp(10_030);
        _assertPermanentMode(2, -int256(1e16));

        assertTrue(vm.revertToStateAndDelete(baseline));
        vm.warp(10_030);
        _assertPermanentMode(3, int256(1e6));
    }

    function test_nextSwapSweepsOnlyPreviousProtocolWethAndAccruesCurrentFee() public {
        vm.warp(10_030);
        _quoteAndExecute(false, -int256(1e12), "");

        uint256 previousProtocol = hook.pendingProtocolWeth();
        uint256 beneficiaryPending = hook.pendingBeneficiaryTotalWeth(poolId);
        uint256 treasuryBefore = IERC20(Currency.unwrap(currency1)).balanceOf(treasury);
        uint256 hookTokenClaimBefore = manager.balanceOf(address(hook), currency0.toId());
        uint256 accruedBefore = hook.totalProtocolWethAccrued(poolId);

        SwapObservation memory observed = _quoteAndExecute(false, -int256(2e12), "");
        uint256 currentProtocol = hook.totalProtocolWethAccrued(poolId) - accruedBefore;

        assertGt(previousProtocol, 0);
        assertGt(currentProtocol, 0);
        assertEq(
            IERC20(Currency.unwrap(currency1)).balanceOf(treasury) - treasuryBefore,
            previousProtocol
        );
        assertEq(hook.totalProtocolWethSwept(), previousProtocol);
        assertEq(hook.pendingProtocolWeth(), currentProtocol);
        assertEq(
            manager.balanceOf(address(hook), currency1.toId()), currentProtocol + beneficiaryPending
        );
        assertEq(manager.balanceOf(address(hook), currency0.toId()), hookTokenClaimBefore);
        assertEq(observed.hookClaim0After, observed.hookClaim0Before);
        assertEq(hook.pendingBeneficiaryTotalWeth(poolId), beneficiaryPending);
    }

    function test_anyPoolSweepsGlobalProtocolWethWithoutCrossingBeneficiaryBuckets() public {
        PoolKey memory keyA = key;
        PoolId poolA = poolId;
        address beneficiaryB = makeAddr("v2BeneficiaryB");
        (PoolKey memory keyB, PoolId poolB) = _createSecondPool(beneficiaryB);

        key = keyA;
        poolId = poolA;
        _quoteAndExecute(false, -int256(1e12), "");
        uint256 protocolA1 = hook.pendingProtocolWeth();
        uint256 beneficiaryA1 = hook.pendingBeneficiaryTotalWeth(poolA);
        uint256 treasuryBefore = IERC20(Currency.unwrap(currency1)).balanceOf(treasury);

        key = keyB;
        poolId = poolB;
        _quoteAndExecute(false, -int256(2e12), "");
        uint256 protocolB = hook.pendingProtocolWeth();
        uint256 beneficiaryB1 = hook.pendingBeneficiaryTotalWeth(poolB);

        assertGt(protocolA1, 0);
        assertGt(protocolB, 0);
        assertGt(beneficiaryA1, 0);
        assertGt(beneficiaryB1, 0);
        assertEq(
            IERC20(Currency.unwrap(currency1)).balanceOf(treasury) - treasuryBefore, protocolA1
        );
        assertEq(hook.pendingBeneficiaryTotalWeth(poolA), beneficiaryA1);
        assertEq(hook.pendingBeneficiaryWeth(poolA, beneficiary), beneficiaryA1);
        assertEq(hook.pendingBeneficiaryWeth(poolA, beneficiaryB), 0);
        assertEq(hook.pendingBeneficiaryWeth(poolB, beneficiary), 0);
        assertEq(hook.pendingBeneficiaryWeth(poolB, beneficiaryB), beneficiaryB1);

        (uint256 poolBFeeGrowth0, uint256 poolBFeeGrowth1) = _feeGrowthGlobals();
        uint256 accruedA1 = hook.totalProtocolWethAccrued(poolA);
        key = keyA;
        poolId = poolA;
        _quoteAndExecute(false, -int256(3e12), "");
        uint256 protocolA2 = hook.totalProtocolWethAccrued(poolA) - accruedA1;

        assertEq(
            IERC20(Currency.unwrap(currency1)).balanceOf(treasury) - treasuryBefore,
            protocolA1 + protocolB
        );
        assertEq(hook.pendingProtocolWeth(), protocolA2);
        assertEq(hook.totalProtocolWethSwept(), protocolA1 + protocolB);
        assertEq(hook.pendingBeneficiaryTotalWeth(poolB), beneficiaryB1);

        key = keyB;
        poolId = poolB;
        (uint256 poolBFeeGrowth0After, uint256 poolBFeeGrowth1After) = _feeGrowthGlobals();
        assertEq(poolBFeeGrowth0After, poolBFeeGrowth0);
        assertEq(poolBFeeGrowth1After, poolBFeeGrowth1);

        uint256 beneficiaryA2 = hook.pendingBeneficiaryTotalWeth(poolA);
        assertEq(
            manager.balanceOf(address(hook), currency1.toId()),
            protocolA2 + beneficiaryA2 + beneficiaryB1
        );
        assertEq(manager.balanceOf(address(hook), currency0.toId()), 0);
        assertEq(manager.balanceOf(address(hook), keyB.currency0.toId()), 0);

        DegenHoodV4HookV2.PoolConfig memory configA = hook.getPoolConfig(poolA);
        DegenHoodV4HookV2.PoolConfig memory configB = hook.getPoolConfig(poolB);
        assertEq(configA.beneficiary, beneficiary);
        assertEq(configB.beneficiary, beneficiaryB);
        assertTrue(configA.token != configB.token);
    }

    function test_manualProtocolFlushIsPermissionlessExactAndIdempotent() public {
        vm.warp(10_030);
        _quoteAndExecute(false, -int256(1e12), "");
        uint256 protocolPending = hook.pendingProtocolWeth();
        uint256 claimBefore = manager.balanceOf(address(hook), currency1.toId());
        uint256 treasuryBefore = IERC20(Currency.unwrap(currency1)).balanceOf(treasury);

        address keeper = makeAddr("protocolKeeper");
        vm.prank(keeper);
        uint256 paid = hook.flushProtocolFees();

        assertEq(paid, protocolPending);
        assertEq(hook.pendingProtocolWeth(), 0);
        assertEq(hook.totalProtocolWethSwept(), protocolPending);
        assertEq(
            IERC20(Currency.unwrap(currency1)).balanceOf(treasury) - treasuryBefore, protocolPending
        );
        assertEq(manager.balanceOf(address(hook), currency1.toId()), claimBefore - protocolPending);

        vm.prank(keeper);
        assertEq(hook.flushProtocolFees(), 0);
        assertEq(hook.totalProtocolWethSwept(), protocolPending);
    }

    function test_beneficiaryFlushNeverSweepsProtocolOrRedirectsCreatorCredit() public {
        _quoteAndExecute(false, -int256(1e12), "");
        uint256 protocolPending = hook.pendingProtocolWeth();
        uint256 beneficiaryPending = hook.pendingBeneficiaryWeth(poolId, beneficiary);
        uint256 treasuryBefore = IERC20(Currency.unwrap(currency1)).balanceOf(treasury);

        address stranger = makeAddr("flushStranger");
        vm.prank(stranger);
        (uint256 redirectedProtocol, uint256 redirectedCreator) =
            hook.flushPoolFees(poolId, stranger);
        assertEq(redirectedProtocol, 0);
        assertEq(redirectedCreator, 0);
        assertEq(hook.pendingBeneficiaryWeth(poolId, beneficiary), beneficiaryPending);

        vm.prank(stranger);
        (uint256 protocolPaid, uint256 beneficiaryStored) = hook.flushPoolFees(poolId, beneficiary);

        assertEq(protocolPaid, 0);
        assertEq(beneficiaryStored, beneficiaryPending);
        assertEq(hook.pendingProtocolWeth(), protocolPending);
        assertEq(hook.pendingBeneficiaryWeth(poolId, beneficiary), 0);
        assertEq(hook.pendingBeneficiaryTotalWeth(poolId), 0);
        assertEq(feeLocker.feesToClaim(beneficiary), beneficiaryPending);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(treasury), treasuryBefore);
        assertEq(manager.balanceOf(address(hook), currency1.toId()), protocolPending);
    }

    function test_beneficiaryUpdatePreservesOldCreditAndRoutesOnlyFutureCredit() public {
        _quoteAndExecute(false, -int256(1e12), "");
        uint256 oldCredit = hook.pendingBeneficiaryWeth(poolId, beneficiary);
        address nextBeneficiary = makeAddr("nextV2Beneficiary");

        hook.updateBeneficiary(Currency.unwrap(currency0), nextBeneficiary);
        _quoteAndExecute(false, -int256(2e12), "");
        uint256 newCredit = hook.pendingBeneficiaryWeth(poolId, nextBeneficiary);

        assertGt(oldCredit, 0);
        assertGt(newCredit, 0);
        assertEq(hook.pendingBeneficiaryWeth(poolId, beneficiary), oldCredit);
        assertEq(hook.pendingBeneficiaryTotalWeth(poolId), oldCredit + newCredit);

        hook.flushPoolFees(poolId, beneficiary);
        hook.flushPoolFees(poolId, nextBeneficiary);
        assertEq(feeLocker.feesToClaim(beneficiary), oldCredit);
        assertEq(feeLocker.feesToClaim(nextBeneficiary), newCredit);
        assertEq(hook.pendingBeneficiaryTotalWeth(poolId), 0);
    }

    function _assertPermanentMode(uint8 mode, int256 amountSpecified) private {
        bool zeroForOne = mode >= 2;
        uint256 protocolBefore = hook.pendingProtocolWeth();
        uint256 accruedBefore = hook.totalProtocolWethAccrued(poolId);
        uint256 beneficiaryBefore = hook.pendingBeneficiaryTotalWeth(poolId);

        SwapObservation memory observed = _quoteAndExecute(zeroForOne, amountSpecified, "");
        uint256 fee = hook.totalProtocolWethAccrued(poolId) - accruedBefore;

        assertGt(fee, 0);
        assertEq(observed.hookClaim0After, observed.hookClaim0Before);
        assertEq(observed.hookClaim1After - observed.hookClaim1Before, fee);
        assertEq(hook.pendingProtocolWeth() - protocolBefore, fee);
        assertEq(hook.pendingBeneficiaryTotalWeth(poolId), beneficiaryBefore);
        assertEq(hook.pendingBeneficiaryWeth(poolId, beneficiary), beneficiaryBefore);

        if (mode == 0) {
            assertEq(fee, DegenFeeMath.feeFromGross(uint256(-amountSpecified), 5000));
        } else if (mode == 1) {
            uint256 grossWeth = uint256(-int256(observed.amount1Delta));
            assertEq(DegenFeeMath.grossFromNet(grossWeth - fee, 5000), grossWeth);
        } else if (mode == 2) {
            uint256 grossWeth = uint256(int256(observed.amount1Delta)) + fee;
            assertEq(fee, DegenFeeMath.feeFromGross(grossWeth, 5000));
        } else {
            assertEq(
                DegenFeeMath.grossFromNet(uint256(amountSpecified), 5000),
                uint256(amountSpecified) + fee
            );
        }
    }

    function _createSecondPool(address beneficiaryB)
        private
        returns (PoolKey memory keyB, PoolId poolB)
    {
        MockERC20 tokenB;
        for (uint256 i; i < 32; ++i) {
            MockERC20 candidate = new MockERC20("TOKEN B", "B", 18);
            if (address(candidate) < Currency.unwrap(currency1)) {
                tokenB = candidate;
                break;
            }
        }
        assertTrue(address(tokenB) != address(0), "could not mine token below WETH");
        tokenB.mint(address(this), type(uint128).max);
        tokenB.approve(address(modifyLiquidityRouter), type(uint256).max);
        tokenB.approve(address(swapRouter), type(uint256).max);

        keyB = hook.registerPool(address(tokenB), beneficiaryB);
        poolB = keyB.toId();
        manager.initialize(keyB, TickMath.getSqrtPriceAtTick(INITIAL_TICK));
        key = keyB;
        poolId = poolB;
        _addLiquidity(INITIAL_TICK, -120_000, 1e18);
        _addLiquidity(INITIAL_TICK - 200, -120_000, 1e18);
    }

    function _hookFlags() private pure returns (uint160) {
        return uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
    }
}

contract BlockingV2TransferToken is MockERC20 {
    error TransferBlocked();

    address public blockedSender;

    constructor(string memory name_, string memory symbol_) MockERC20(name_, symbol_, 18) {}

    function setBlockedSender(address sender) external {
        blockedSender = sender;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (msg.sender == blockedSender) revert TransferBlocked();
        return super.transfer(to, amount);
    }
}

contract DegenHoodV4HookV2FailureTest is DegenV4SwapHarness {
    using PoolIdLibrary for PoolKey;

    event ProtocolWethSweepFailed(
        PoolId indexed triggeringPoolId, uint256 attemptedAmount, bytes reason
    );

    int24 private constant INITIAL_TICK = -230_400;

    DegenHoodV4HookV2 private hook;
    BlockingV2TransferToken private wethToken;
    address private beneficiary = makeAddr("failureBeneficiary");
    address private treasury = makeAddr("failureTreasury");

    function setUp() public {
        BlockingV2TransferToken tokenA = new BlockingV2TransferToken("TOKEN A", "A");
        BlockingV2TransferToken tokenB = new BlockingV2TransferToken("TOKEN B", "B");
        _setUpV4InfrastructureWithTokens(tokenA, tokenB);
        wethToken = BlockingV2TransferToken(Currency.unwrap(currency1));

        DegenHoodFeeLocker feeLocker = new DegenHoodFeeLocker(address(this), address(wethToken));
        bytes memory constructorArgs =
            abi.encode(manager, address(this), address(wethToken), treasury, address(feeLocker));
        (address expected, bytes32 salt) = HookMiner.find(
            address(this), _hookFlags(), type(DegenHoodV4HookV2).creationCode, constructorArgs
        );
        hook = new DegenHoodV4HookV2{salt: salt}(
            manager, address(this), address(wethToken), treasury, address(feeLocker)
        );
        assertEq(address(hook), expected);

        vm.warp(10_000);
        key = hook.registerPool(Currency.unwrap(currency0), beneficiary);
        poolId = key.toId();
        manager.initialize(key, TickMath.getSqrtPriceAtTick(INITIAL_TICK));
        _addLiquidity(INITIAL_TICK, -120_000, 1e18);
        _addLiquidity(INITIAL_TICK - 200, -120_000, 1e18);
    }

    function test_failedAutoSweepPreservesBackingAndTradingThenRecoversExactlyOnce() public {
        vm.warp(10_030);
        swap(key, false, -int256(1e12), "");
        uint256 firstPending = hook.pendingProtocolWeth();
        uint256 accruedBeforeSecond = hook.totalProtocolWethAccrued(poolId);

        wethToken.setBlockedSender(address(manager));
        vm.expectEmit(true, false, false, false, address(hook));
        emit ProtocolWethSweepFailed(poolId, 0, "");
        swap(key, false, -int256(2e12), "");
        uint256 secondFee = hook.totalProtocolWethAccrued(poolId) - accruedBeforeSecond;

        assertGt(secondFee, 0);
        assertEq(hook.pendingProtocolWeth(), firstPending + secondFee);
        assertEq(hook.totalProtocolWethSwept(), 0);
        assertEq(wethToken.balanceOf(treasury), 0);
        assertEq(manager.balanceOf(address(hook), currency1.toId()), firstPending + secondFee);

        wethToken.setBlockedSender(address(0));
        uint256 accruedBeforeThird = hook.totalProtocolWethAccrued(poolId);
        swap(key, false, -int256(3e12), "");
        uint256 thirdFee = hook.totalProtocolWethAccrued(poolId) - accruedBeforeThird;

        assertEq(wethToken.balanceOf(treasury), firstPending + secondFee);
        assertEq(hook.totalProtocolWethSwept(), firstPending + secondFee);
        assertEq(hook.pendingProtocolWeth(), thirdFee);
        assertEq(manager.balanceOf(address(hook), currency1.toId()), thirdFee);
        assertEq(manager.balanceOf(address(hook), currency0.toId()), 0);
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(treasury), 0);
    }

    function test_failedManualSweepRevertsAndPreservesAccountingUntilRecovery() public {
        vm.warp(10_030);
        swap(key, false, -int256(1e12), "");
        uint256 pending = hook.pendingProtocolWeth();
        uint256 claims = manager.balanceOf(address(hook), currency1.toId());

        wethToken.setBlockedSender(address(manager));
        vm.expectRevert();
        hook.flushProtocolFees();

        assertEq(hook.pendingProtocolWeth(), pending);
        assertEq(hook.totalProtocolWethSwept(), 0);
        assertEq(manager.balanceOf(address(hook), currency1.toId()), claims);
        assertEq(wethToken.balanceOf(treasury), 0);

        wethToken.setBlockedSender(address(0));
        assertEq(hook.flushProtocolFees(), pending);
        assertEq(hook.pendingProtocolWeth(), 0);
        assertEq(hook.totalProtocolWethSwept(), pending);
        assertEq(manager.balanceOf(address(hook), currency1.toId()), 0);
        assertEq(wethToken.balanceOf(treasury), pending);
    }

    function _hookFlags() private pure returns (uint160) {
        return uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
    }
}
