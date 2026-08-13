// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IDegenHoodFeeLocker} from "./interfaces/IDegenHoodFeeLocker.sol";
import {IDegenHoodV4Hook} from "./interfaces/IDegenHoodV4Hook.sol";
import {IDegenHoodV4LpLocker} from "./interfaces/IDegenHoodV4LpLocker.sol";

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

/*
HEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEENEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEOoooooOEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEOooooooooooNEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEOooooooooooooooHEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEEEEEEEEEOooooooooooooooooooNEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEEEEEEEhooooooooooooooooooooooEEEEEEEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEEEEEEoooooooooooooooooooooooooOEEEEEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEEEEOooooooooooooooooooooooooooooNEEEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEEEooooooooooooooeEnooooooooooooooOEEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEDoooooooooooeEEEEEEEEEEeoooooooooooEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEoooooooogeEEEEEEEEEEEEEEEEEEeooooooooNEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEoooooogEEEEEEEEEEEEEEEEEEEEEEEEEEooooooOEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEooooooooooOOHEEEEEEEEEEEEEEEEhOOoooooooooOEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEOooooooogEoooooooooooOOOooooooooooonEooooooooEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEDooooooooEEEooooooooooooooooooooooodEEoooooooooEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEooooooooooOEEoooooooooeEEooooooooogEEoooooooooogEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEooooooooooooOEEEEEEnEEEEEEEenEEEEEEooooooooooogEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEooooooooooooNEEEEEEEEEEEEEEEEEEOoooooooooooeEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEENooooooooooEEEEEEEEEEEEEEEEoooooooooeEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEEEEhoooooooOEEEEEEEEEEEEoooooooeEEEEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEEEEEEEEEnooooNEEEEEEEEoooogEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEnoEEEEEOenEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE
gEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE
                                   DEGENHOOD
*/

/// @title DegenHood v4 permanent LP locker
/// @notice Mints the canonical launch position into permanent contract custody.
/// @dev Permanent single-position token/WETH custody with permissionless fee collection and no NFT
///      or pool-currency principal withdrawal path.
contract DegenHoodV4LpLocker is IDegenHoodV4LpLocker, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    uint256 public constant STANDARD_SUPPLY = 100_000_000_000 ether;
    uint256 public constant RATE_DENOMINATOR = 1_000_000;
    uint256 public constant TOKEN_RESERVE_RATE = 200_000;
    int24 public constant TICK_SPACING = 200;
    int24 public constant INITIAL_TICK = -230_400;
    int24 public constant UPPER_TICK = -120_000;
    address public constant BURN_SINK = 0x000000000000000000000000000000000000dEaD;

    address public immutable factory;
    address public immutable hook;
    address public immutable weth;
    address public immutable tokenReserve;
    IDegenHoodFeeLocker public immutable feeLocker;
    IPositionManager public immutable positionManager;
    IAllowanceTransfer public immutable permit2;

    mapping(address token => PositionConfig config) private _positions;

    modifier onlyFactory() {
        if (msg.sender != factory) revert OnlyFactory();
        _;
    }

    constructor(
        address factory_,
        address hook_,
        address weth_,
        address tokenReserve_,
        address feeLocker_,
        address positionManager_,
        address permit2_
    ) {
        if (
            factory_ == address(0) || hook_ == address(0) || weth_ == address(0)
                || tokenReserve_ == address(0) || positionManager_ == address(0)
                || permit2_ == address(0)
        ) {
            revert InvalidAddress();
        }
        if (
            hook_.code.length == 0 || positionManager_.code.length == 0 || permit2_.code.length == 0
        ) {
            revert InvalidAddress();
        }
        if (feeLocker_.code.length == 0 || IDegenHoodFeeLocker(feeLocker_).WETH() != weth_) {
            revert InvalidFeeLocker();
        }
        factory = factory_;
        hook = hook_;
        weth = weth_;
        tokenReserve = tokenReserve_;
        feeLocker = IDegenHoodFeeLocker(feeLocker_);
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
    ) external onlyFactory nonReentrant returns (uint256 positionId) {
        if (beneficiary == address(0)) revert InvalidBeneficiary();
        if (feeAdmin == address(0)) revert InvalidFeeAdmin();
        if (poolSupply != STANDARD_SUPPLY) revert InvalidPoolSupply();
        if (_positions[token].placed) revert PositionAlreadyPlaced();
        _validatePoolKey(poolKey, token, beneficiary);

        IERC20 launchToken = IERC20(token);
        uint256 balanceBefore = launchToken.balanceOf(address(this));
        launchToken.safeTransferFrom(msg.sender, address(this), poolSupply);
        if (launchToken.balanceOf(address(this)) - balanceBefore != poolSupply) {
            revert UnsupportedTokenBehavior();
        }

        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(INITIAL_TICK);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(UPPER_TICK);
        uint128 liquidity =
            LiquidityAmounts.getLiquidityForAmounts(sqrtLower, sqrtLower, sqrtUpper, poolSupply, 0);

        bytes memory actions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            poolKey,
            INITIAL_TICK,
            UPPER_TICK,
            uint256(liquidity),
            uint128(poolSupply),
            uint128(0),
            address(this),
            bytes("")
        );
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);

        launchToken.forceApprove(address(permit2), poolSupply);
        permit2.approve(
            token, address(positionManager), uint160(poolSupply), uint48(block.timestamp)
        );

        positionId = positionManager.nextTokenId();
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        permit2.approve(token, address(positionManager), 0, 0);
        launchToken.forceApprove(address(permit2), 0);

        if (IERC721(address(positionManager)).ownerOf(positionId) != address(this)) {
            revert InvalidPositionReceipt();
        }
        uint256 lockedTokenDust = launchToken.balanceOf(address(this)) - balanceBefore;
        uint256 tokenPrincipal = poolSupply - lockedTokenDust;
        _positions[token] = PositionConfig({
            poolKey: poolKey,
            positionId: positionId,
            beneficiary: beneficiary,
            feeAdmin: feeAdmin,
            poolSupply: poolSupply,
            tokenPrincipal: tokenPrincipal,
            lockedTokenDust: lockedTokenDust,
            placed: true
        });

        emit LiquidityPlaced(
            token,
            positionId,
            beneficiary,
            feeAdmin,
            poolSupply,
            tokenPrincipal,
            lockedTokenDust,
            INITIAL_TICK,
            UPPER_TICK
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

    function updateBeneficiary(address token, address newBeneficiary) external nonReentrant {
        if (newBeneficiary == address(0)) revert InvalidBeneficiary();
        PositionConfig storage config = _positions[token];
        if (!config.placed) revert PositionNotFound();
        if (msg.sender != config.feeAdmin) revert OnlyFeeAdmin();

        address previousBeneficiary = config.beneficiary;
        _collectRewards(token, config);

        IDegenHoodV4Hook degenHook = IDegenHoodV4Hook(hook);
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

        bytes memory actions =
            abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(config.positionId, 0, 0, 0, bytes(""));
        params[1] = abi.encode(config.poolKey.currency0, config.poolKey.currency1, address(this));
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        tokenFees = launchToken.balanceOf(address(this)) - tokenBalanceBefore;
        wethFees = wrappedEther.balanceOf(address(this)) - wethBalanceBefore;
        uint256 tokenReserveAmount = tokenFees * TOKEN_RESERVE_RATE / RATE_DENOMINATOR;
        uint256 tokenBurnAmount = tokenFees - tokenReserveAmount;

        if (tokenReserveAmount != 0) launchToken.safeTransfer(tokenReserve, tokenReserveAmount);
        if (tokenBurnAmount != 0) launchToken.safeTransfer(BURN_SINK, tokenBurnAmount);
        if (wethFees != 0) {
            wrappedEther.forceApprove(address(feeLocker), wethFees);
            uint256 stored = feeLocker.storeFees(config.beneficiary, wethFees);
            if (stored != wethFees) revert UnsupportedTokenBehavior();
            wrappedEther.forceApprove(address(feeLocker), 0);
        }

        emit FeesCollected(
            token,
            config.positionId,
            config.beneficiary,
            tokenFees,
            tokenReserveAmount,
            tokenBurnAmount,
            wethFees
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
        IDegenHoodV4Hook.PoolConfig memory hookConfig =
            IDegenHoodV4Hook(hook).getPoolConfig(poolKey.toId());
        if (!hookConfig.registered || !hookConfig.initialized || hookConfig.token != token) {
            revert InvalidPoolKey();
        }
        if (hookConfig.beneficiaryController != address(this)) revert InvalidPoolKey();
        if (hookConfig.beneficiary != beneficiary) revert InvalidBeneficiary();
    }
}
