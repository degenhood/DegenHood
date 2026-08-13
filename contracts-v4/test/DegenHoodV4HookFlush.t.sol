// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DegenHoodFeeLocker} from "../src/DegenHoodFeeLocker.sol";
import {DegenHoodV4Hook} from "../src/DegenHoodV4Hook.sol";
import {IDegenHoodFeeLocker} from "../src/interfaces/IDegenHoodFeeLocker.sol";
import {IDegenHoodV4Hook} from "../src/interfaces/IDegenHoodV4Hook.sol";
import {DegenFeeMath} from "../src/libraries/DegenFeeMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {DegenV4SwapHarness} from "./helpers/DegenV4SwapHarness.sol";

contract DegenHoodV4HookFlushTest is DegenV4SwapHarness {
    using PoolIdLibrary for PoolKey;

    int24 private constant INITIAL_TICK = -230_400;
    uint256 private constant INITIAL_TOTAL_RATE = 800_000;

    DegenHoodV4Hook private hook;
    DegenHoodFeeLocker private feeLocker;
    address private token;
    address private weth;
    address private treasury = makeAddr("operatingTreasury");
    address private beneficiary = makeAddr("beneficiary");
    address private nextBeneficiary = makeAddr("nextBeneficiary");
    address private stranger = makeAddr("stranger");

    function setUp() public {
        _setUpV4Infrastructure();
        token = Currency.unwrap(currency0);
        weth = Currency.unwrap(currency1);
        feeLocker = new DegenHoodFeeLocker(address(this), weth);
        hook = _deployHook();
        feeLocker.setDepositor(address(hook), true);

        vm.warp(10_000);
        key = hook.registerPool(token, beneficiary);
        poolId = key.toId();
        manager.initialize(key, TickMath.getSqrtPriceAtTick(INITIAL_TICK));
        _addLiquidity(INITIAL_TICK, -120_000, 1e18);
    }

    function test_flush_routesBackedProtocolAndTemporaryBeneficiaryWeth() public {
        uint256 grossWeth = 1e12;
        DegenFeeMath.FeeSplit memory split =
            DegenFeeMath.splitHookFee(grossWeth, INITIAL_TOTAL_RATE);
        _buy(grossWeth);

        assertEq(hook.pendingProtocolWeth(poolId), split.protocolCredit);
        assertEq(hook.pendingBeneficiaryWeth(poolId, beneficiary), split.beneficiaryTemporary);
        assertEq(hook.pendingTotalWeth(poolId), split.totalHookFee);
        assertEq(manager.balanceOf(address(hook), currency1.toId()), split.totalHookFee);
        assertEq(currency1.balanceOf(address(hook)), 0);
        assertEq(currency1.balanceOf(address(feeLocker)), 0);

        vm.prank(stranger);
        (uint256 protocolPaid, uint256 beneficiaryStored) = hook.flushPoolFees(poolId, beneficiary);

        assertEq(protocolPaid, split.protocolCredit);
        assertEq(beneficiaryStored, split.beneficiaryTemporary);
        assertEq(currency1.balanceOf(treasury), split.protocolCredit);
        assertEq(currency1.balanceOf(address(feeLocker)), split.beneficiaryTemporary);
        assertEq(feeLocker.feesToClaim(beneficiary), split.beneficiaryTemporary);
        assertEq(manager.balanceOf(address(hook), currency1.toId()), 0);
        assertEq(hook.pendingProtocolWeth(poolId), 0);
        assertEq(hook.pendingBeneficiaryWeth(poolId, beneficiary), 0);
        assertEq(hook.pendingTotalWeth(poolId), 0);
    }

    function test_flush_beneficiaryUpdateCannotRelabelOldEntitlement() public {
        uint256 grossWeth = 1e12;
        DegenFeeMath.FeeSplit memory initialSplit =
            DegenFeeMath.splitHookFee(grossWeth, INITIAL_TOTAL_RATE);
        _buy(grossWeth);

        hook.updateBeneficiary(token, nextBeneficiary);
        vm.warp(10_030);
        _buy(grossWeth);
        uint256 permanentFee = DegenFeeMath.feeFromGross(grossWeth, 5000);

        assertEq(
            hook.pendingBeneficiaryWeth(poolId, beneficiary), initialSplit.beneficiaryTemporary
        );
        assertEq(hook.pendingBeneficiaryWeth(poolId, nextBeneficiary), 0);
        assertEq(hook.pendingProtocolWeth(poolId), initialSplit.protocolCredit + permanentFee);

        hook.flushPoolFees(poolId, beneficiary);
        hook.flushPoolFees(poolId, nextBeneficiary);

        assertEq(feeLocker.feesToClaim(beneficiary), initialSplit.beneficiaryTemporary);
        assertEq(feeLocker.feesToClaim(nextBeneficiary), 0);
        assertEq(currency1.balanceOf(treasury), initialSplit.protocolCredit + permanentFee);
    }

    function test_flush_onlyRegisteredControllerCanUpdateBeneficiaryAndZeroIsRejected() public {
        vm.prank(stranger);
        vm.expectRevert(IDegenHoodV4Hook.OnlyBeneficiaryController.selector);
        hook.updateBeneficiary(token, nextBeneficiary);

        vm.expectRevert(IDegenHoodV4Hook.InvalidBeneficiary.selector);
        hook.updateBeneficiary(token, address(0));

        assertEq(hook.getPoolConfig(poolId).beneficiary, beneficiary);
    }

    function test_flush_arbitraryBeneficiaryCannotRedirectCredit() public {
        uint256 grossWeth = 1e12;
        DegenFeeMath.FeeSplit memory split =
            DegenFeeMath.splitHookFee(grossWeth, INITIAL_TOTAL_RATE);
        _buy(grossWeth);

        vm.prank(stranger);
        hook.flushPoolFees(poolId, stranger);

        assertEq(feeLocker.feesToClaim(stranger), 0);
        assertEq(hook.pendingBeneficiaryWeth(poolId, beneficiary), split.beneficiaryTemporary);
        assertEq(currency1.balanceOf(treasury), split.protocolCredit);

        vm.prank(stranger);
        hook.flushPoolFees(poolId, beneficiary);
        assertEq(feeLocker.feesToClaim(beneficiary), split.beneficiaryTemporary);
    }

    function test_flush_failedLockerDepositRollsBackClaimAndTreasuryTransfer() public {
        uint256 grossWeth = 1e12;
        DegenFeeMath.FeeSplit memory split =
            DegenFeeMath.splitHookFee(grossWeth, INITIAL_TOTAL_RATE);
        _buy(grossWeth);
        feeLocker.setDepositor(address(hook), false);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDegenHoodFeeLocker.UnauthorizedDepositor.selector, address(hook)
            )
        );
        hook.flushPoolFees(poolId, beneficiary);

        assertEq(currency1.balanceOf(treasury), 0);
        assertEq(currency1.balanceOf(address(feeLocker)), 0);
        assertEq(manager.balanceOf(address(hook), currency1.toId()), split.totalHookFee);
        assertEq(hook.pendingTotalWeth(poolId), split.totalHookFee);
        assertEq(hook.pendingProtocolWeth(poolId), split.protocolCredit);
        assertEq(hook.pendingBeneficiaryWeth(poolId, beneficiary), split.beneficiaryTemporary);
    }

    function test_flush_directUnlockCallbackIsRejected() public {
        vm.prank(address(manager));
        vm.expectRevert(IDegenHoodV4Hook.UnauthorizedUnlock.selector);
        hook.unlockCallback(abi.encode(uint256(1)));
    }

    function _buy(uint256 grossWeth) private {
        swap(key, false, -int256(grossWeth), "");
    }

    function _deployHook() private returns (DegenHoodV4Hook deployed) {
        bytes memory constructorArgs =
            abi.encode(manager, address(this), weth, treasury, address(feeLocker));
        (address expected, bytes32 salt) = HookMiner.find(
            address(this), _hookFlags(), type(DegenHoodV4Hook).creationCode, constructorArgs
        );
        deployed = new DegenHoodV4Hook{salt: salt}(
            manager, address(this), weth, treasury, address(feeLocker)
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

contract BlockingHookTransferToken is MockERC20 {
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

contract DegenHoodV4HookTreasuryFailureTest is DegenV4SwapHarness {
    using PoolIdLibrary for PoolKey;

    int24 private constant INITIAL_TICK = -230_400;

    DegenHoodV4Hook private hook;
    DegenHoodFeeLocker private feeLocker;
    BlockingHookTransferToken private wethToken;
    address private token;
    address private weth;
    address private beneficiary = makeAddr("failureBeneficiary");
    address private treasury = makeAddr("failureTreasury");

    function setUp() public {
        BlockingHookTransferToken tokenA = new BlockingHookTransferToken("TOKEN A", "A");
        BlockingHookTransferToken tokenB = new BlockingHookTransferToken("TOKEN B", "B");
        _setUpV4InfrastructureWithTokens(tokenA, tokenB);
        token = Currency.unwrap(currency0);
        weth = Currency.unwrap(currency1);
        wethToken = BlockingHookTransferToken(weth);
        feeLocker = new DegenHoodFeeLocker(address(this), weth);
        hook = _deployHook();
        feeLocker.setDepositor(address(hook), true);

        vm.warp(10_000);
        key = hook.registerPool(token, beneficiary);
        poolId = key.toId();
        manager.initialize(key, TickMath.getSqrtPriceAtTick(INITIAL_TICK));
        _addLiquidity(INITIAL_TICK, -120_000, 1e18);
    }

    function test_flush_failedTreasuryTransferRollsBackClaimAndPendingAccounting() public {
        swap(key, false, -1e12, "");
        uint256 pendingTotal = hook.pendingTotalWeth(poolId);
        uint256 pendingProtocol = hook.pendingProtocolWeth(poolId);
        uint256 pendingBeneficiary = hook.pendingBeneficiaryWeth(poolId, beneficiary);
        wethToken.setBlockedSender(address(hook));

        vm.expectRevert(BlockingHookTransferToken.TransferBlocked.selector);
        hook.flushPoolFees(poolId, beneficiary);

        assertEq(wethToken.balanceOf(treasury), 0);
        assertEq(wethToken.balanceOf(address(feeLocker)), 0);
        assertEq(manager.balanceOf(address(hook), currency1.toId()), pendingTotal);
        assertEq(hook.pendingTotalWeth(poolId), pendingTotal);
        assertEq(hook.pendingProtocolWeth(poolId), pendingProtocol);
        assertEq(hook.pendingBeneficiaryWeth(poolId, beneficiary), pendingBeneficiary);
    }

    function _deployHook() private returns (DegenHoodV4Hook deployed) {
        bytes memory constructorArgs =
            abi.encode(manager, address(this), weth, treasury, address(feeLocker));
        (address expected, bytes32 salt) = HookMiner.find(
            address(this), _hookFlags(), type(DegenHoodV4Hook).creationCode, constructorArgs
        );
        deployed = new DegenHoodV4Hook{salt: salt}(
            manager, address(this), weth, treasury, address(feeLocker)
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
