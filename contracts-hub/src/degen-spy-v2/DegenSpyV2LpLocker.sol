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

import {IDegenSpyV1FeeLocker} from "../interfaces/IDegenSpyV1FeeLocker.sol";
import {IDegenSpyV2Hook} from "../interfaces/IDegenSpyV2Hook.sol";
import {IDegenSpyV2LpLocker} from "../interfaces/IDegenSpyV2LpLocker.sol";
import {DegenSpyV2LaunchConstants} from "../libraries/DegenSpyV2LaunchConstants.sol";

/// @title SPY V4 V2 permanent six-position LP locker
/// @notice Routes token LP fees 80% dead/20% reserve and raw-SPY fees to the creator.
contract DegenSpyV2LpLocker is IDegenSpyV2LpLocker, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    uint256 public constant POOL_SUPPLY = 100_000_000_000 ether;
    uint256 public constant RATE_DENOMINATOR = 1_000_000;
    uint256 public constant TOKEN_RESERVE_RATE = 200_000;
    int24 public constant TICK_SPACING = DegenSpyV2LaunchConstants.TICK_SPACING;
    int24 public constant INITIAL_TICK = DegenSpyV2LaunchConstants.INITIAL_TICK;
    address public constant BURN_SINK = 0x000000000000000000000000000000000000dEaD;

    address public immutable module;
    address public immutable hook;
    address public immutable spy;
    address public immutable tokenReserve;
    IDegenSpyV1FeeLocker public immutable feeLocker;
    IPositionManager public immutable positionManager;
    IAllowanceTransfer public immutable permit2;
    mapping(address => PositionConfig) private _positions;

    modifier onlyModule() {
        if (msg.sender != module) revert OnlyModule();
        _;
    }

    constructor(
        address module_,
        address hook_,
        address spy_,
        address tokenReserve_,
        address feeLocker_,
        address positionManager_,
        address permit2_
    ) {
        if (
            module_ == address(0) || hook_ == address(0) || spy_ == address(0)
                || tokenReserve_ == address(0) || positionManager_ == address(0)
                || permit2_ == address(0) || tokenReserve_ == address(this)
        ) revert InvalidAddress();
        if (
            hook_.code.length == 0 || spy_.code.length == 0 || positionManager_.code.length == 0
                || permit2_.code.length == 0
        ) revert InvalidAddress();
        if (
            feeLocker_.code.length == 0 || IDegenSpyV1FeeLocker(feeLocker_).SPY() != spy_
                || IDegenSpyV1FeeLocker(feeLocker_).LP_LOCKER() != address(this)
                || IDegenSpyV1FeeLocker(feeLocker_).HOOK() != hook_
        ) revert InvalidFeeLocker();
        module = module_;
        hook = hook_;
        spy = spy_;
        tokenReserve = tokenReserve_;
        feeLocker = IDegenSpyV1FeeLocker(feeLocker_);
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

        uint256[6] memory positionIds;
        uint160 sqrtInitial = TickMath.getSqrtPriceAtTick(INITIAL_TICK);
        for (uint256 i; i < DegenSpyV2LaunchConstants.TRANCHE_COUNT; ++i) {
            uint256 trancheSupply =
                poolSupply * DegenSpyV2LaunchConstants.supplySharePips(i) / RATE_DENOMINATOR;
            int24 lower = DegenSpyV2LaunchConstants.lowerTick(i);
            int24 upper = DegenSpyV2LaunchConstants.upperTick(i);
            uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtInitial,
                TickMath.getSqrtPriceAtTick(lower),
                TickMath.getSqrtPriceAtTick(upper),
                trancheSupply,
                0
            );
            uint256 positionId = positionManager.nextTokenId();
            positionIds[i] = positionId;
            _mintPosition(poolKey, lower, upper, liquidity, trancheSupply);
            if (IERC721(address(positionManager)).ownerOf(positionId) != address(this)) {
                revert InvalidPositionReceipt();
            }
        }
        permit2.approve(token, address(positionManager), 0, 0);
        launchToken.forceApprove(address(permit2), 0);
        uint256 dust = launchToken.balanceOf(address(this)) - balanceBefore;
        _positions[token] = PositionConfig({
            poolKey: poolKey,
            positionIds: positionIds,
            beneficiary: beneficiary,
            feeAdmin: feeAdmin,
            poolSupply: poolSupply,
            tokenPrincipal: poolSupply - dust,
            lockedTokenDust: dust,
            placed: true
        });
        firstPositionId = positionIds[0];
        emit LiquidityPlaced(
            token, firstPositionId, beneficiary, feeAdmin, poolSupply, poolSupply - dust, dust
        );
    }

    function collectRewards(address token)
        external
        nonReentrant
        returns (uint256 tokenFees, uint256 rawSpyFees)
    {
        PositionConfig storage config = _positions[token];
        if (!config.placed) revert PositionNotFound();
        return _collectRewards(token, config);
    }

    function claimFees(address token)
        external
        nonReentrant
        returns (uint256 beneficiaryRawSpyDelivered)
    {
        PositionConfig storage config = _positions[token];
        if (!config.placed) revert PositionNotFound();
        address beneficiary = config.beneficiary;
        (uint256 lpTokenFees, uint256 lpRawSpyStored) = _collectRewards(token, config);
        (,, uint256 hookCreatorRawSpyStored) =
            IDegenSpyV2Hook(hook).flushPoolFees(config.poolKey.toId(), beneficiary);
        beneficiaryRawSpyDelivered = feeLocker.claimFor(beneficiary);
        emit FeesDelivered(
            token,
            beneficiary,
            msg.sender,
            lpTokenFees,
            lpRawSpyStored,
            hookCreatorRawSpyStored,
            beneficiaryRawSpyDelivered
        );
    }

    function updateBeneficiary(address token, address newBeneficiary) external nonReentrant {
        if (newBeneficiary == address(0) || newBeneficiary == address(this)) {
            revert InvalidBeneficiary();
        }
        PositionConfig storage config = _positions[token];
        if (!config.placed) revert PositionNotFound();
        if (msg.sender != config.feeAdmin) revert OnlyFeeAdmin();
        address previous = config.beneficiary;
        _collectRewards(token, config);
        IDegenSpyV2Hook(hook).flushPoolFees(config.poolKey.toId(), previous);
        IDegenSpyV2Hook(hook).updateBeneficiary(token, newBeneficiary);
        config.beneficiary = newBeneficiary;
        emit BeneficiaryUpdated(token, previous, newBeneficiary, msg.sender);
    }

    function updateFeeAdmin(address token, address newFeeAdmin) external {
        if (newFeeAdmin == address(0)) revert InvalidFeeAdmin();
        PositionConfig storage config = _positions[token];
        if (!config.placed) revert PositionNotFound();
        if (msg.sender != config.feeAdmin) revert OnlyFeeAdmin();
        address previous = config.feeAdmin;
        config.feeAdmin = newFeeAdmin;
        emit FeeAdminUpdated(token, previous, newFeeAdmin);
    }

    function _mintPosition(
        PoolKey calldata poolKey,
        int24 lower,
        int24 upper,
        uint128 liquidity,
        uint256 trancheSupply
    ) private {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR)
        );
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            poolKey,
            lower,
            upper,
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
        returns (uint256 tokenFees, uint256 rawSpyFees)
    {
        IERC20 launchToken = IERC20(token);
        IERC20 quote = IERC20(spy);
        uint256 tokenBefore = launchToken.balanceOf(address(this));
        uint256 quoteBefore = quote.balanceOf(address(this));
        for (uint256 i; i < DegenSpyV2LaunchConstants.TRANCHE_COUNT; ++i) {
            bytes memory actions =
                abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
            bytes[] memory params = new bytes[](2);
            params[0] = abi.encode(config.positionIds[i], 0, 0, 0, bytes(""));
            params[1] =
                abi.encode(config.poolKey.currency0, config.poolKey.currency1, address(this));
            positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        }
        tokenFees = launchToken.balanceOf(address(this)) - tokenBefore;
        rawSpyFees = quote.balanceOf(address(this)) - quoteBefore;
        uint256 reserveAmount = tokenFees * TOKEN_RESERVE_RATE / RATE_DENOMINATOR;
        uint256 burnAmount = tokenFees - reserveAmount;
        if (reserveAmount != 0) launchToken.safeTransfer(tokenReserve, reserveAmount);
        if (burnAmount != 0) launchToken.safeTransfer(BURN_SINK, burnAmount);
        if (rawSpyFees != 0) {
            quote.forceApprove(address(feeLocker), rawSpyFees);
            uint256 stored = feeLocker.storeFees(config.beneficiary, rawSpyFees);
            quote.forceApprove(address(feeLocker), 0);
            if (stored != rawSpyFees) revert UnsupportedTokenBehavior();
        }
        emit FeesCollected(
            token, config.beneficiary, tokenFees, reserveAmount, burnAmount, rawSpyFees
        );
    }

    function _validatePoolKey(PoolKey calldata poolKey, address token, address beneficiary)
        private
        view
    {
        if (
            token == address(0) || token >= spy || Currency.unwrap(poolKey.currency0) != token
                || Currency.unwrap(poolKey.currency1) != spy
                || poolKey.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG
                || poolKey.tickSpacing != TICK_SPACING || address(poolKey.hooks) != hook
        ) revert InvalidPoolKey();
        IDegenSpyV2Hook.PoolConfig memory config =
            IDegenSpyV2Hook(hook).getPoolConfig(poolKey.toId());
        if (
            !config.registered || !config.initialized || config.token != token
                || config.beneficiaryController != address(this)
        ) revert InvalidPoolKey();
        if (config.beneficiary != beneficiary) revert InvalidBeneficiary();
    }
}
