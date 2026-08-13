// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {
    PositionInfo,
    PositionInfoLibrary
} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {IDegenHoodTokenV5} from "../interfaces/IDegenHoodTokenV5.sol";
import {IDegenV1FeeLocker} from "../interfaces/IDegenV1FeeLocker.sol";
import {IDegenV3Hook} from "../interfaces/IDegenV3Hook.sol";
import {IDegenV3LpLocker} from "../interfaces/IDegenV3LpLocker.sol";
import {DegenV3LaunchConstants} from "../libraries/DegenV3LaunchConstants.sol";

/// @title DEGEN V3 permanent ten-position LP locker
/// @notice Permanently holds launch NFTs and burns token-side LP fees from total supply.
contract DegenV3LpLocker is IDegenV3LpLocker, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using PositionInfoLibrary for PositionInfo;
    using SafeERC20 for IERC20;

    uint256 public constant POOL_SUPPLY = 100_000_000_000 ether;
    uint256 public constant RATE_DENOMINATOR = DegenV3LaunchConstants.RATE_DENOMINATOR;
    uint256 public constant TOKEN_RESERVE_RATE = 200_000;
    int24 public constant TICK_SPACING = DegenV3LaunchConstants.TICK_SPACING;

    uint256 private constant ROBINHOOD_CHAIN_ID = 4663;
    address private constant ROBINHOOD_POSITION_MANAGER =
        0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address private constant ROBINHOOD_TOKEN_RESERVE = 0x19e81C012B635646cA7543Ac1Dfca10B93835538;

    address public immutable module;
    address public immutable hook;
    address public immutable weth;
    address public immutable tokenReserve;
    IDegenV1FeeLocker public immutable feeLocker;
    IPositionManager public immutable positionManager;

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
        address positionManager_
    ) {
        if (
            module_ == address(0) || hook_ == address(0) || weth_ == address(0)
                || tokenReserve_ == address(0) || positionManager_ == address(0)
                || tokenReserve_ == address(this) || hook_.code.length == 0
                || positionManager_.code.length == 0
                || (block.chainid == ROBINHOOD_CHAIN_ID
                    && (positionManager_ != ROBINHOOD_POSITION_MANAGER
                        || tokenReserve_ != ROBINHOOD_TOKEN_RESERVE))
        ) revert InvalidAddress();
        if (
            feeLocker_.code.length == 0 || IDegenV1FeeLocker(feeLocker_).WETH() != weth_
                || IDegenV1FeeLocker(feeLocker_).LP_LOCKER() != address(this)
                || IDegenV1FeeLocker(feeLocker_).HOOK() != hook_
        ) revert InvalidFeeLocker();

        module = module_;
        hook = hook_;
        weth = weth_;
        tokenReserve = tokenReserve_;
        feeLocker = IDegenV1FeeLocker(feeLocker_);
        positionManager = IPositionManager(positionManager_);
    }

    function positionForToken(address token) external view returns (PositionConfig memory) {
        return _positions[token];
    }

    function registerPositions(
        PoolKey calldata poolKey,
        address token,
        uint256[10] calldata positionIds,
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

        firstPositionId = positionIds[0];
        for (uint256 i; i < DegenV3LaunchConstants.TRANCHE_COUNT; ++i) {
            if (
                positionIds[i] != firstPositionId + i
                    || IERC721(address(positionManager)).ownerOf(positionIds[i]) != address(this)
            ) revert InvalidPositionReceipt();
            (PoolKey memory positionKey, PositionInfo info) =
                positionManager.getPoolAndPositionInfo(positionIds[i]);
            if (
                PoolId.unwrap(positionKey.toId()) != PoolId.unwrap(poolKey.toId())
                    || info.tickLower() != DegenV3LaunchConstants.lowerTick(i)
                    || info.tickUpper() != DegenV3LaunchConstants.upperTick(i)
                    || positionManager.getPositionLiquidity(positionIds[i])
                        != DegenV3LaunchConstants.liquidity(poolSupply, i)
            ) revert InvalidPositionReceipt();
        }

        uint256 lockedTokenDust = IERC20(token).balanceOf(address(this));
        if (lockedTokenDust > poolSupply) revert UnsupportedTokenBehavior();
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
            IDegenV3Hook(hook).flushPoolFees(config.poolKey.toId(), beneficiary);
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
        IDegenV3Hook degenHook = IDegenV3Hook(hook);
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

    function _collectRewards(address token, PositionConfig storage config)
        private
        returns (uint256 tokenFees, uint256 wethFees)
    {
        IERC20 launchToken = IERC20(token);
        IERC20 wrappedEther = IERC20(weth);
        uint256 tokenBalanceBefore = launchToken.balanceOf(address(this));
        uint256 wethBalanceBefore = wrappedEther.balanceOf(address(this));
        bytes memory actions = new bytes(DegenV3LaunchConstants.TRANCHE_COUNT + 1);
        bytes[] memory params = new bytes[](DegenV3LaunchConstants.TRANCHE_COUNT + 1);
        for (uint256 i; i < DegenV3LaunchConstants.TRANCHE_COUNT; ++i) {
            actions[i] = bytes1(uint8(Actions.DECREASE_LIQUIDITY));
            params[i] = abi.encode(config.positionIds[i], 0, 0, 0, bytes(""));
        }
        actions[DegenV3LaunchConstants.TRANCHE_COUNT] = bytes1(uint8(Actions.TAKE_PAIR));
        params[DegenV3LaunchConstants.TRANCHE_COUNT] =
            abi.encode(config.poolKey.currency0, config.poolKey.currency1, address(this));
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        tokenFees = launchToken.balanceOf(address(this)) - tokenBalanceBefore;
        wethFees = wrappedEther.balanceOf(address(this)) - wethBalanceBefore;
        uint256 tokenReserveAmount = tokenFees * TOKEN_RESERVE_RATE / RATE_DENOMINATOR;
        uint256 tokenBurnAmount = tokenFees - tokenReserveAmount;
        if (tokenReserveAmount != 0) launchToken.safeTransfer(tokenReserve, tokenReserveAmount);
        if (tokenBurnAmount != 0) IDegenHoodTokenV5(token).burn(tokenBurnAmount);
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
        ) revert InvalidPoolKey();
        IDegenV3Hook.PoolConfig memory hookConfig = IDegenV3Hook(hook).getPoolConfig(poolKey.toId());
        if (
            !hookConfig.registered || !hookConfig.initialized || hookConfig.token != token
                || hookConfig.beneficiaryController != address(this)
        ) revert InvalidPoolKey();
        if (hookConfig.beneficiary != beneficiary) revert InvalidBeneficiary();
    }
}
