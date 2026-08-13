// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DegenHoodFeeLocker} from "../src/DegenHoodFeeLocker.sol";
import {DegenHoodV4Hook} from "../src/DegenHoodV4Hook.sol";
import {DegenHoodV4LpLocker} from "../src/DegenHoodV4LpLocker.sol";
import {IDegenHoodFeeLocker} from "../src/interfaces/IDegenHoodFeeLocker.sol";
import {IDegenHoodV4LpLocker} from "../src/interfaces/IDegenHoodV4LpLocker.sol";
import {DegenV4Fixture} from "./helpers/DegenV4Fixture.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {
    PositionInfo,
    PositionInfoLibrary
} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

contract DegenHoodV4LpLockerCustodyTest is DegenV4Fixture {
    using PositionInfoLibrary for PositionInfo;

    uint256 private constant STANDARD_SUPPLY = 100_000_000_000 ether;
    uint256 private constant TOKEN_RESERVE_RATE = 200_000;
    uint256 private constant RATE_DENOMINATOR = 1_000_000;
    int24 private constant INITIAL_TICK = -230_400;
    int24 private constant UPPER_TICK = -120_000;
    address private constant BURN_SINK = 0x000000000000000000000000000000000000dEaD;

    DegenHoodV4Hook private hook;
    DegenHoodFeeLocker private feeLocker;
    DegenHoodV4LpLocker private lpLocker;
    address private token;
    address private weth;
    address private beneficiary = makeAddr("lpBeneficiary");
    address private feeAdmin = makeAddr("feeAdmin");
    address private nextFeeAdmin = makeAddr("nextFeeAdmin");
    address private nextBeneficiary = makeAddr("nextBeneficiary");
    address private tokenAdmin = makeAddr("tokenAdmin");
    address private tokenReserve = makeAddr("tokenReserve");
    address private stranger = makeAddr("stranger");

    function setUp() public {
        _setUpV4Infrastructure();
        _setUpV4PositionManager();
        token = Currency.unwrap(currency0);
        weth = Currency.unwrap(currency1);

        feeLocker = new DegenHoodFeeLocker(address(this), weth);
        hook = _deployHook();
        lpLocker = new DegenHoodV4LpLocker(
            address(this),
            address(hook),
            weth,
            tokenReserve,
            address(feeLocker),
            address(positionManager),
            address(permit2)
        );
        feeLocker.setDepositor(address(lpLocker), true);
        feeLocker.setDepositor(address(hook), true);

        vm.warp(10_000);
        key = hook.registerPool(token, beneficiary, address(lpLocker));
        poolId = hook.poolIdForToken(token);
        manager.initialize(key, TickMath.getSqrtPriceAtTick(INITIAL_TICK));

        uint256 excess = IERC20(token).balanceOf(address(this)) - STANDARD_SUPPLY;
        MockERC20(token).burn(address(this), excess);
        IERC20(token).approve(address(lpLocker), STANDARD_SUPPLY);
    }

    function test_place_onlyFactoryMayPlaceStandardLaunchLiquidity() public {
        vm.prank(stranger);
        vm.expectRevert(IDegenHoodV4LpLocker.OnlyFactory.selector);
        lpLocker.placeLiquidity(key, token, STANDARD_SUPPLY, beneficiary, feeAdmin);

        vm.expectRevert(IDegenHoodV4LpLocker.InvalidPoolSupply.selector);
        lpLocker.placeLiquidity(key, token, STANDARD_SUPPLY - 1, beneficiary, feeAdmin);

        uint256 positionId =
            lpLocker.placeLiquidity(key, token, STANDARD_SUPPLY, beneficiary, feeAdmin);
        assertEq(positionId, 1);

        vm.expectRevert(IDegenHoodV4LpLocker.PositionAlreadyPlaced.selector);
        lpLocker.placeLiquidity(key, token, STANDARD_SUPPLY, beneficiary, feeAdmin);
    }

    function testFuzz_place_rejectsEveryNonStandardSupply(uint256 poolSupply) public {
        vm.assume(poolSupply != STANDARD_SUPPLY);
        vm.expectRevert(IDegenHoodV4LpLocker.InvalidPoolSupply.selector);
        lpLocker.placeLiquidity(key, token, poolSupply, beneficiary, feeAdmin);
    }

    function test_place_rejectsSubstitutedPoolKeyOrBeneficiary() public {
        PoolKey memory substituted = PoolKey({
            currency0: key.currency0,
            currency1: key.currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 400,
            hooks: key.hooks
        });

        vm.expectRevert(IDegenHoodV4LpLocker.InvalidPoolKey.selector);
        lpLocker.placeLiquidity(substituted, token, STANDARD_SUPPLY, beneficiary, feeAdmin);

        vm.expectRevert(IDegenHoodV4LpLocker.InvalidBeneficiary.selector);
        lpLocker.placeLiquidity(key, token, STANDARD_SUPPLY, address(0), feeAdmin);

        vm.expectRevert(IDegenHoodV4LpLocker.InvalidBeneficiary.selector);
        lpLocker.placeLiquidity(key, token, STANDARD_SUPPLY, stranger, feeAdmin);

        vm.expectRevert(IDegenHoodV4LpLocker.InvalidFeeAdmin.selector);
        lpLocker.placeLiquidity(key, token, STANDARD_SUPPLY, beneficiary, address(0));
    }

    function test_place_locksCanonicalPositionAndAccountsForEntireSupply() public {
        uint256 positionId =
            lpLocker.placeLiquidity(key, token, STANDARD_SUPPLY, beneficiary, feeAdmin);
        IDegenHoodV4LpLocker.PositionConfig memory config = lpLocker.positionForToken(token);
        (PoolKey memory positionKey, PositionInfo info) =
            positionManager.getPoolAndPositionInfo(positionId);
        uint128 liquidity = positionManager.getPositionLiquidity(positionId);

        assertEq(positionId, config.positionId);
        assertEq(config.beneficiary, beneficiary);
        assertEq(config.feeAdmin, feeAdmin);
        assertEq(config.poolSupply, STANDARD_SUPPLY);
        assertTrue(config.placed);
        assertEq(Currency.unwrap(positionKey.currency0), token);
        assertEq(Currency.unwrap(positionKey.currency1), weth);
        assertEq(positionKey.tickSpacing, 200);
        assertEq(info.tickLower(), INITIAL_TICK);
        assertEq(info.tickUpper(), UPPER_TICK);
        assertGt(liquidity, 0);
        assertEq(IERC721(address(positionManager)).ownerOf(positionId), address(lpLocker));

        uint256 expectedPrincipal = SqrtPriceMath.getAmount0Delta(
            TickMath.getSqrtPriceAtTick(INITIAL_TICK),
            TickMath.getSqrtPriceAtTick(UPPER_TICK),
            liquidity,
            true
        );
        assertEq(config.tokenPrincipal, expectedPrincipal);
        assertEq(config.tokenPrincipal + config.lockedTokenDust, STANDARD_SUPPLY);
        assertEq(IERC20(token).balanceOf(address(lpLocker)), config.lockedTokenDust);
        assertEq(IERC20(token).balanceOf(address(this)), 0);
    }

    function test_roles_launcherTokenAdminFeeAdminAndBeneficiaryHaveNoImplicitOverlap() public {
        lpLocker.placeLiquidity(key, token, STANDARD_SUPPLY, beneficiary, feeAdmin);
        IDegenHoodV4LpLocker.PositionConfig memory config = lpLocker.positionForToken(token);

        assertTrue(address(this) != tokenAdmin);
        assertTrue(address(this) != feeAdmin);
        assertTrue(address(this) != beneficiary);
        assertTrue(tokenAdmin != feeAdmin);
        assertTrue(feeAdmin != beneficiary);
        assertEq(config.beneficiary, beneficiary);
        assertEq(config.feeAdmin, feeAdmin);

        vm.expectRevert(IDegenHoodV4LpLocker.OnlyFeeAdmin.selector);
        lpLocker.updateBeneficiary(token, nextBeneficiary);

        vm.prank(tokenAdmin);
        vm.expectRevert(IDegenHoodV4LpLocker.OnlyFeeAdmin.selector);
        lpLocker.updateBeneficiary(token, nextBeneficiary);

        vm.prank(beneficiary);
        vm.expectRevert(IDegenHoodV4LpLocker.OnlyFeeAdmin.selector);
        lpLocker.updateBeneficiary(token, nextBeneficiary);
    }

    function test_updateBeneficiary_checkpointsOldStreamsThenOnlyFutureAccrualMoves() public {
        lpLocker.placeLiquidity(key, token, STANDARD_SUPPLY, beneficiary, feeAdmin);
        vm.warp(10_001);
        swap(key, false, -int256(1 ether), "");
        uint256 pendingHookWeth = hook.pendingBeneficiaryWeth(poolId, beneficiary);
        assertGt(pendingHookWeth, 0);

        vm.prank(feeAdmin);
        lpLocker.updateBeneficiary(token, nextBeneficiary);

        uint256 oldCredit = feeLocker.feesToClaim(beneficiary);
        assertGt(oldCredit, pendingHookWeth);
        assertEq(hook.pendingBeneficiaryWeth(poolId, beneficiary), 0);
        assertEq(hook.pendingTotalWeth(poolId), 0);
        assertEq(lpLocker.positionForToken(token).beneficiary, nextBeneficiary);
        assertEq(hook.getPoolConfig(poolId).beneficiary, nextBeneficiary);
        (uint256 tokenFeesAfterCheckpoint, uint256 wethFeesAfterCheckpoint) =
            lpLocker.collectRewards(token);
        assertEq(tokenFeesAfterCheckpoint, 0);
        assertEq(wethFeesAfterCheckpoint, 0);

        vm.warp(10_002);
        swap(key, false, -int256(1 ether), "");
        lpLocker.collectRewards(token);
        hook.flushPoolFees(poolId, nextBeneficiary);

        assertEq(feeLocker.feesToClaim(beneficiary), oldCredit);
        assertGt(feeLocker.feesToClaim(nextBeneficiary), 0);
    }

    function test_updateBeneficiary_failedHookCheckpointRollsBackEveryChange() public {
        lpLocker.placeLiquidity(key, token, STANDARD_SUPPLY, beneficiary, feeAdmin);
        vm.warp(10_001);
        swap(key, false, -int256(1 ether), "");
        uint256 pendingHookWeth = hook.pendingBeneficiaryWeth(poolId, beneficiary);
        feeLocker.setDepositor(address(hook), false);

        vm.prank(feeAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDegenHoodFeeLocker.UnauthorizedDepositor.selector, address(hook)
            )
        );
        lpLocker.updateBeneficiary(token, nextBeneficiary);

        assertEq(lpLocker.positionForToken(token).beneficiary, beneficiary);
        assertEq(hook.getPoolConfig(poolId).beneficiary, beneficiary);
        assertEq(hook.pendingBeneficiaryWeth(poolId, beneficiary), pendingHookWeth);
        assertEq(feeLocker.feesToClaim(beneficiary), 0);

        feeLocker.setDepositor(address(hook), true);
        vm.prank(feeAdmin);
        lpLocker.updateBeneficiary(token, nextBeneficiary);
        assertEq(lpLocker.positionForToken(token).beneficiary, nextBeneficiary);
        assertGt(feeLocker.feesToClaim(beneficiary), pendingHookWeth);
    }

    function test_updateBeneficiary_rejectsZeroAndRequiresNoRecipientAcceptance() public {
        lpLocker.placeLiquidity(key, token, STANDARD_SUPPLY, beneficiary, feeAdmin);

        vm.prank(feeAdmin);
        vm.expectRevert(IDegenHoodV4LpLocker.InvalidBeneficiary.selector);
        lpLocker.updateBeneficiary(token, address(0));

        address contractRecipient = address(new NonAcceptingBeneficiary());
        vm.prank(feeAdmin);
        lpLocker.updateBeneficiary(token, contractRecipient);
        assertEq(lpLocker.positionForToken(token).beneficiary, contractRecipient);
        assertEq(hook.getPoolConfig(poolId).beneficiary, contractRecipient);
    }

    function test_updateFeeAdmin_isOneStepAndDoesNotChangeBeneficiary() public {
        lpLocker.placeLiquidity(key, token, STANDARD_SUPPLY, beneficiary, feeAdmin);
        vm.warp(10_001);
        swap(key, false, -int256(1 ether), "");
        uint256 pendingHookWeth = hook.pendingBeneficiaryWeth(poolId, beneficiary);
        assertGt(pendingHookWeth, 0);

        vm.prank(stranger);
        vm.expectRevert(IDegenHoodV4LpLocker.OnlyFeeAdmin.selector);
        lpLocker.updateFeeAdmin(token, nextFeeAdmin);

        vm.prank(feeAdmin);
        vm.expectRevert(IDegenHoodV4LpLocker.InvalidFeeAdmin.selector);
        lpLocker.updateFeeAdmin(token, address(0));

        vm.prank(feeAdmin);
        lpLocker.updateFeeAdmin(token, nextFeeAdmin);
        assertEq(lpLocker.positionForToken(token).feeAdmin, nextFeeAdmin);
        assertEq(lpLocker.positionForToken(token).beneficiary, beneficiary);
        assertEq(hook.getPoolConfig(poolId).beneficiary, beneficiary);
        assertEq(hook.pendingBeneficiaryWeth(poolId, beneficiary), pendingHookWeth);
        assertEq(feeLocker.feesToClaim(beneficiary), 0);

        vm.prank(feeAdmin);
        vm.expectRevert(IDegenHoodV4LpLocker.OnlyFeeAdmin.selector);
        lpLocker.updateBeneficiary(token, nextBeneficiary);

        vm.prank(nextFeeAdmin);
        lpLocker.updateBeneficiary(token, nextBeneficiary);
        assertEq(lpLocker.positionForToken(token).beneficiary, nextBeneficiary);
        assertGt(feeLocker.feesToClaim(beneficiary), pendingHookWeth);
    }

    function test_custody_hasNoExternalEscapeOrArbitraryRewardConfiguration() public {
        uint256 positionId =
            lpLocker.placeLiquidity(key, token, STANDARD_SUPPLY, beneficiary, feeAdmin);
        assertTrue(IERC20(weth).transfer(address(lpLocker), 123));

        vm.startPrank(stranger);
        vm.expectRevert();
        IERC721(address(positionManager)).transferFrom(address(lpLocker), stranger, positionId);

        (bool withdrew,) = address(lpLocker)
            .call(abi.encodeWithSignature("withdrawERC20(address,address)", token, stranger));
        (bool rescued,) = address(lpLocker)
            .call(
                abi.encodeWithSignature("rescueToken(address,address,uint256)", weth, stranger, 123)
            );
        (bool unlocked,) = address(lpLocker)
            .call(abi.encodeWithSignature("unlockPosition(address,address)", token, stranger));
        (bool reconfigured,) = address(lpLocker)
            .call(
                abi.encodeWithSignature(
                    "updateRewardRecipient(address,uint256,address)", token, 0, stranger
                )
            );
        vm.stopPrank();

        assertFalse(withdrew);
        assertFalse(rescued);
        assertFalse(unlocked);
        assertFalse(reconfigured);
        assertEq(IERC721(address(positionManager)).ownerOf(positionId), address(lpLocker));
        assertEq(IERC20(weth).balanceOf(address(lpLocker)), 123);
        assertEq(lpLocker.positionForToken(token).beneficiary, beneficiary);
    }

    function test_collect_permissionlesslyRoutesBothAssetsAndCannotDoubleCount() public {
        _placeAndAccrueBothAssets();
        uint256 dustBefore = IERC20(token).balanceOf(address(lpLocker));

        vm.prank(stranger);
        (uint256 tokenFees, uint256 wethFees) = lpLocker.collectRewards(token);

        uint256 reserveShare = tokenFees * TOKEN_RESERVE_RATE / RATE_DENOMINATOR;
        assertGt(tokenFees, 0);
        assertGt(wethFees, 0);
        assertGt(tokenFees * TOKEN_RESERVE_RATE % RATE_DENOMINATOR, 0);
        assertEq(IERC20(token).balanceOf(tokenReserve), reserveShare);
        assertEq(IERC20(token).balanceOf(BURN_SINK), tokenFees - reserveShare);
        assertEq(feeLocker.feesToClaim(beneficiary), wethFees);
        assertEq(IERC20(weth).balanceOf(address(feeLocker)), wethFees);
        assertEq(IERC20(weth).balanceOf(address(lpLocker)), 0);
        assertEq(IERC20(token).balanceOf(address(lpLocker)), dustBefore);

        vm.prank(stranger);
        (uint256 repeatedTokenFees, uint256 repeatedWethFees) = lpLocker.collectRewards(token);
        assertEq(repeatedTokenFees, 0);
        assertEq(repeatedWethFees, 0);
        assertEq(IERC20(token).balanceOf(tokenReserve), reserveShare);
        assertEq(IERC20(token).balanceOf(BURN_SINK), tokenFees - reserveShare);
        assertEq(feeLocker.feesToClaim(beneficiary), wethFees);
    }

    function test_collect_manualCallIncludesTheFinalSwapWithoutAnotherSwap() public {
        lpLocker.placeLiquidity(key, token, STANDARD_SUPPLY, beneficiary, feeAdmin);
        vm.warp(10_030);
        swap(key, false, -int256(1 ether), "");

        (, uint256 wethFees) = lpLocker.collectRewards(token);

        assertGt(wethFees, 0);
        assertEq(feeLocker.feesToClaim(beneficiary), wethFees);
    }

    function test_collect_failedFeeLockerCreditRollsBackThenRemainsCollectible() public {
        lpLocker.placeLiquidity(key, token, STANDARD_SUPPLY, beneficiary, feeAdmin);
        vm.warp(10_030);
        swap(key, false, -int256(1 ether), "");
        uint256 tokenBalanceBefore = IERC20(token).balanceOf(address(lpLocker));
        feeLocker.setDepositor(address(lpLocker), false);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDegenHoodFeeLocker.UnauthorizedDepositor.selector, address(lpLocker)
            )
        );
        lpLocker.collectRewards(token);

        assertEq(feeLocker.feesToClaim(beneficiary), 0);
        assertEq(IERC20(weth).balanceOf(address(feeLocker)), 0);
        assertEq(IERC20(weth).balanceOf(address(lpLocker)), 0);
        assertEq(IERC20(token).balanceOf(address(lpLocker)), tokenBalanceBefore);

        feeLocker.setDepositor(address(lpLocker), true);
        (, uint256 wethFees) = lpLocker.collectRewards(token);
        assertGt(wethFees, 0);
        assertEq(feeLocker.feesToClaim(beneficiary), wethFees);
    }

    function _placeAndAccrueBothAssets() private {
        lpLocker.placeLiquidity(key, token, STANDARD_SUPPLY, beneficiary, feeAdmin);
        vm.warp(10_030);
        swap(key, false, -int256(1 ether), "");
        uint256 acquiredTokens = IERC20(token).balanceOf(address(this));
        assertGt(acquiredTokens, 1);
        swap(key, true, -int256(acquiredTokens / 2), "");
    }

    function _deployHook() private returns (DegenHoodV4Hook deployed) {
        bytes memory constructorArgs = abi.encode(
            manager, address(this), weth, makeAddr("operatingTreasury"), address(feeLocker)
        );
        (address expected, bytes32 salt) = HookMiner.find(
            address(this), _hookFlags(), type(DegenHoodV4Hook).creationCode, constructorArgs
        );
        deployed = new DegenHoodV4Hook{salt: salt}(
            manager, address(this), weth, makeAddr("operatingTreasury"), address(feeLocker)
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

contract NonAcceptingBeneficiary {}

contract BlockingLpTransferToken is MockERC20 {
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

contract DegenHoodV4LpLockerTransferFailureTest is DegenV4Fixture {
    uint256 private constant STANDARD_SUPPLY = 100_000_000_000 ether;
    int24 private constant INITIAL_TICK = -230_400;
    address private constant BURN_SINK = 0x000000000000000000000000000000000000dEaD;

    DegenHoodV4Hook private hook;
    DegenHoodFeeLocker private feeLocker;
    DegenHoodV4LpLocker private lpLocker;
    address private token;
    address private weth;
    address private beneficiary = makeAddr("blockingBeneficiary");
    address private feeAdmin = makeAddr("blockingFeeAdmin");
    address private tokenReserve = makeAddr("blockingTokenReserve");
    address private treasury = makeAddr("blockingTreasury");

    function setUp() public {
        BlockingLpTransferToken tokenA = new BlockingLpTransferToken("TOKEN A", "A");
        BlockingLpTransferToken tokenB = new BlockingLpTransferToken("TOKEN B", "B");
        _setUpV4InfrastructureWithTokens(tokenA, tokenB);
        _setUpV4PositionManager();
        token = Currency.unwrap(currency0);
        weth = Currency.unwrap(currency1);

        feeLocker = new DegenHoodFeeLocker(address(this), weth);
        hook = _deployHook();
        lpLocker = new DegenHoodV4LpLocker(
            address(this),
            address(hook),
            weth,
            tokenReserve,
            address(feeLocker),
            address(positionManager),
            address(permit2)
        );
        feeLocker.setDepositor(address(lpLocker), true);

        vm.warp(20_000);
        key = hook.registerPool(token, beneficiary, address(lpLocker));
        manager.initialize(key, TickMath.getSqrtPriceAtTick(INITIAL_TICK));
        BlockingLpTransferToken(token)
            .burn(address(this), IERC20(token).balanceOf(address(this)) - STANDARD_SUPPLY);
        IERC20(token).approve(address(lpLocker), STANDARD_SUPPLY);
        lpLocker.placeLiquidity(key, token, STANDARD_SUPPLY, beneficiary, feeAdmin);
        vm.warp(20_030);
        swap(key, false, -int256(1 ether), "");
        swap(key, true, -int256(IERC20(token).balanceOf(address(this)) / 2), "");
    }

    function test_collect_failedTokenDistributionRollsBackAllAssetsAndCheckpoint() public {
        uint256 lockedDust = IERC20(token).balanceOf(address(lpLocker));
        BlockingLpTransferToken(token).setBlockedSender(address(lpLocker));

        vm.expectRevert(BlockingLpTransferToken.TransferBlocked.selector);
        lpLocker.collectRewards(token);

        assertEq(IERC20(token).balanceOf(tokenReserve), 0);
        assertEq(IERC20(token).balanceOf(BURN_SINK), 0);
        assertEq(IERC20(token).balanceOf(address(lpLocker)), lockedDust);
        assertEq(IERC20(weth).balanceOf(address(lpLocker)), 0);
        assertEq(IERC20(weth).balanceOf(address(feeLocker)), 0);
        assertEq(feeLocker.feesToClaim(beneficiary), 0);

        BlockingLpTransferToken(token).setBlockedSender(address(0));
        (uint256 tokenFees, uint256 wethFees) = lpLocker.collectRewards(token);
        assertGt(tokenFees, 0);
        assertGt(wethFees, 0);
        assertEq(IERC20(token).balanceOf(tokenReserve), tokenFees / 5);
        assertEq(IERC20(token).balanceOf(BURN_SINK), tokenFees - tokenFees / 5);
        assertEq(feeLocker.feesToClaim(beneficiary), wethFees);
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
