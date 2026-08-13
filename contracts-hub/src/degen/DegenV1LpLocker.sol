// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {IDegenV1FeeLocker} from "../interfaces/IDegenV1FeeLocker.sol";
import {IDegenV1Hook} from "../interfaces/IDegenV1Hook.sol";
import {IDegenV1LpLocker} from "../interfaces/IDegenV1LpLocker.sol";
import {DegenLaunchConstants} from "../libraries/DegenLaunchConstants.sol";

/// @title DEGEN_V1 permanent multi-position LP locker
/// @notice Places the complete launch supply into six permanent positions and routes all fees.
/// @dev There is deliberately no NFT, principal, rescue, sweep, or arbitrary-call exit.
contract DegenV1LpLocker is IDegenV1LpLocker, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    uint256 public constant POOL_SUPPLY = 100_000_000_000 ether;
    uint256 public constant RATE_DENOMINATOR = 1_000_000;
    uint256 public constant TOKEN_RESERVE_RATE = 200_000;
    int24 public constant TICK_SPACING = 200;
    int24 public constant INITIAL_TICK = -246_400;
    address public constant BURN_SINK = 0x000000000000000000000000000000000000dEaD;

    address public immutable module;
    address public immutable hook;
    address public immutable weth;
    address public immutable tokenReserve;
    IDegenV1FeeLocker public immutable feeLocker;
    IPositionManager public immutable positionManager;
    IAllowanceTransfer public immutable permit2;

    mapping(address token => PositionConfig config) private _positions;

    modifier onlyModule() {
        if (msg.sender != module) revert OnlyModule();
        _;
    }

    constructor(
        address module_,
        address hook_,
        address weth_,
        address tokenReserve_,
        address feeLocker_,
        address positionManager_,
        address permit2_
    ) {
        if (
            module_ == address(0) || hook_ == address(0) || weth_ == address(0)
                || tokenReserve_ == address(0) || positionManager_ == address(0)
                || permit2_ == address(0) || tokenReserve_ == address(this)
        ) {
            revert InvalidAddress();
        }
        if (
            hook_.code.length == 0 || positionManager_.code.length == 0 || permit2_.code.length == 0
        ) {
            revert InvalidAddress();
        }
        if (
            feeLocker_.code.length == 0 || IDegenV1FeeLocker(feeLocker_).WETH() != weth_
                || IDegenV1FeeLocker(feeLocker_).LP_LOCKER() != address(this)
                || IDegenV1FeeLocker(feeLocker_).HOOK() != hook_
        ) {
            revert InvalidFeeLocker();
        }

        module = module_;
        hook = hook_;
        weth = weth_;
        tokenReserve = tokenReserve_;
        feeLocker = IDegenV1FeeLocker(feeLocker_);
        positionManager = IPositionManager(positionManager_);
        permit2 = IAllowanceTransfer(permit2_);
    }

    function positionForToken(address token) external view returns (PositionConfig memory) {
        return _positions[token];
    }

    function placeLiquidity(
        PoolKey calldata poolKey,
        address token,
        uint256 poolSupply,
        address beneficiary,
        address feeAdmin
    ) external onlyModule nonReentrant returns (uint256 firstPositionId) {
        if (beneficiary == address(0) || beneficiary == address(this)) {
            revert InvalidBeneficiary();
        }
        if (feeAdmin == address(0)) revert InvalidFeeAdmin();
        if (poolSupply != POOL_SUPPLY) revert InvalidPoolSupply();
        if (_positions[token].placed) revert PositionAlreadyPlaced();
        _validatePoolKey(poolKey, token, beneficiary);

        IERC20 launchToken = IERC20(token);
        uint256 balanceBefore = launchToken.balanceOf(address(this));
        launchToken.safeTransferFrom(msg.sender, address(this), poolSupply);
        if (launchToken.balanceOf(address(this)) - balanceBefore != poolSupply) {
            revert UnsupportedTokenBehavior();
        }

        launchToken.forceApprove(address(permit2), poolSupply);
        permit2.approve(
            token, address(positionManager), uint160(poolSupply), uint48(block.timestamp)
        );

        uint256[7] memory positionIds;
        uint160 sqrtInitial = TickMath.getSqrtPriceAtTick(INITIAL_TICK);
        for (uint256 i; i < DegenLaunchConstants.TRANCHE_COUNT; ++i) {
            uint256 trancheSupply =
                poolSupply * DegenLaunchConstants.supplySharePips(i) / RATE_DENOMINATOR;
            int24 tickLower = DegenLaunchConstants.lowerTick(i);
            int24 tickUpper = DegenLaunchConstants.upperTick(i);
            uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtInitial,
                TickMath.getSqrtPriceAtTick(tickLower),
                TickMath.getSqrtPriceAtTick(tickUpper),
                trancheSupply,
                0
            );

            uint256 positionId = positionManager.nextTokenId();
            positionIds[i] = positionId;
            _mintPosition(poolKey, tickLower, tickUpper, liquidity, trancheSupply);
            if (IERC721(address(positionManager)).ownerOf(positionId) != address(this)) {
                revert InvalidPositionReceipt();
            }
        }

        permit2.approve(token, address(positionManager), 0, 0);
        launchToken.forceApprove(address(permit2), 0);

        uint256 lockedTokenDust = launchToken.balanceOf(address(this)) - balanceBefore;
        uint256 tokenPrincipal = poolSupply - lockedTokenDust;
        _positions[token] = PositionConfig({
            poolKey: poolKey,
            positionIds: positionIds,
            beneficiary: beneficiary,
            feeAdmin: feeAdmin,
            poolSupply: poolSupply,
            tokenPrincipal: tokenPrincipal,
            lockedTokenDust: lockedTokenDust,
            placed: true
        });

        firstPositionId = positionIds[0];
        emit LiquidityPlaced(
            token,
            firstPositionId,
            beneficiary,
            feeAdmin,
            poolSupply,
            tokenPrincipal,
            lockedTokenDust
        );
    }

    function collectRewards(address token)
        external
        nonReentrant
        returns (uint256 tokenFees, uint256 wethFees)
    {
        PositionConfig storage config = _positions[token];
        if (!config.placed) revert PositionNotFound();
        return _collectRewards(token, config);
    }

    function claimFees(address token)
        external
        nonReentrant
        returns (uint256 beneficiaryWethDelivered)
    {
        PositionConfig storage config = _positions[token];
        if (!config.placed) revert PositionNotFound();

        address beneficiary = config.beneficiary;
        (uint256 lpTokenFees, uint256 lpWethStored) = _collectRewards(token, config);
        (,, uint256 hookCreatorWethStored) =
            IDegenV1Hook(hook).flushPoolFees(config.poolKey.toId(), beneficiary);
        beneficiaryWethDelivered = feeLocker.claimFor(beneficiary);

        emit FeesDelivered(
            token,
            beneficiary,
            msg.sender,
            lpTokenFees,
            lpWethStored,
            hookCreatorWethStored,
            beneficiaryWethDelivered
        );
    }

    function updateBeneficiary(address token, address newBeneficiary) external nonReentrant {
        if (newBeneficiary == address(0) || newBeneficiary == address(this)) {
            revert InvalidBeneficiary();
        }
        PositionConfig storage config = _positions[token];
        if (!config.placed) revert PositionNotFound();
        if (msg.sender != config.feeAdmin) revert OnlyFeeAdmin();

        address previousBeneficiary = config.beneficiary;
        _collectRewards(token, config);

        IDegenV1Hook degenHook = IDegenV1Hook(hook);
        degenHook.flushPoolFees(config.poolKey.toId(), previousBeneficiary);
        degenHook.updateBeneficiary(token, newBeneficiary);
        config.beneficiary = newBeneficiary;

        emit BeneficiaryUpdated(token, previousBeneficiary, newBeneficiary, msg.sender);
    }

    function updateFeeAdmin(address token, address newFeeAdmin) external {
        if (newFeeAdmin == address(0)) revert InvalidFeeAdmin();
        PositionConfig storage config = _positions[token];
        if (!config.placed) revert PositionNotFound();
        if (msg.sender != config.feeAdmin) revert OnlyFeeAdmin();

        address previousFeeAdmin = config.feeAdmin;
        config.feeAdmin = newFeeAdmin;
        emit FeeAdminUpdated(token, previousFeeAdmin, newFeeAdmin);
    }

    function _mintPosition(
        PoolKey calldata poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 trancheSupply
    ) private {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR)
        );
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            poolKey,
            tickLower,
            tickUpper,
            uint256(liquidity),
            uint128(trancheSupply),
            uint128(0),
            address(this),
            bytes("")
        );
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    function _collectRewards(address token, PositionConfig storage config)
        private
        returns (uint256 tokenFees, uint256 wethFees)
    {
        IERC20 launchToken = IERC20(token);
        IERC20 wrappedEther = IERC20(weth);
        uint256 tokenBalanceBefore = launchToken.balanceOf(address(this));
        uint256 wethBalanceBefore = wrappedEther.balanceOf(address(this));

        for (uint256 i; i < DegenLaunchConstants.TRANCHE_COUNT; ++i) {
            bytes memory actions =
                abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
            bytes[] memory params = new bytes[](2);
            params[0] = abi.encode(config.positionIds[i], 0, 0, 0, bytes(""));
            params[1] =
                abi.encode(config.poolKey.currency0, config.poolKey.currency1, address(this));
            positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        }

        tokenFees = launchToken.balanceOf(address(this)) - tokenBalanceBefore;
        wethFees = wrappedEther.balanceOf(address(this)) - wethBalanceBefore;
        uint256 tokenReserveAmount = tokenFees * TOKEN_RESERVE_RATE / RATE_DENOMINATOR;
        uint256 tokenBurnAmount = tokenFees - tokenReserveAmount;

        if (tokenReserveAmount != 0) {
            launchToken.safeTransfer(tokenReserve, tokenReserveAmount);
        }
        if (tokenBurnAmount != 0) launchToken.safeTransfer(BURN_SINK, tokenBurnAmount);
        if (wethFees != 0) {
            wrappedEther.forceApprove(address(feeLocker), wethFees);
            uint256 stored = feeLocker.storeFees(config.beneficiary, wethFees);
            wrappedEther.forceApprove(address(feeLocker), 0);
            if (stored != wethFees) revert UnsupportedTokenBehavior();
        }

        emit FeesCollected(
            token, config.beneficiary, tokenFees, tokenReserveAmount, tokenBurnAmount, wethFees
        );
    }

    function _validatePoolKey(PoolKey calldata poolKey, address token, address beneficiary)
        private
        view
    {
        if (
            token == address(0) || token >= weth || Currency.unwrap(poolKey.currency0) != token
                || Currency.unwrap(poolKey.currency1) != weth
                || poolKey.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG
                || poolKey.tickSpacing != TICK_SPACING || address(poolKey.hooks) != hook
        ) {
            revert InvalidPoolKey();
        }

        IDegenV1Hook.PoolConfig memory hookConfig = IDegenV1Hook(hook).getPoolConfig(poolKey.toId());
        if (
            !hookConfig.registered || !hookConfig.initialized || hookConfig.token != token
                || hookConfig.beneficiaryController != address(this)
        ) {
            revert InvalidPoolKey();
        }
        if (hookConfig.beneficiary != beneficiary) revert InvalidBeneficiary();
    }
}
