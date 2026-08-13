// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IDegenBuybackVault} from "../interfaces/IDegenBuybackVault.sol";
import {IDegenV1UniswapV3LpLocker} from "../interfaces/IDegenV1UniswapV3LpLocker.sol";
import {
    INonfungiblePositionManagerMinimal
} from "../interfaces/INonfungiblePositionManagerMinimal.sol";
import {IUniswapV3PoolMinimal} from "../interfaces/IUniswapV3PoolMinimal.sol";
import {DegenV1UniswapV3LaunchConstants} from "../libraries/DegenV1UniswapV3LaunchConstants.sol";

/// @title DEGEN V1 — Uniswap V3 permanent multi-position LP locker
/// @notice Places the complete launch supply into six Uniswap v3 positions and holds every NFT
/// permanently. A single permissionless call collects all seven positions and routes measured fees.
/// @dev There is deliberately no NFT, principal, rescue, sweep or arbitrary-call exit.
contract DegenV1UniswapV3LpLocker is IDegenV1UniswapV3LpLocker, IERC721Receiver, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant POOL_SUPPLY = 100_000_000_000 ether;
    uint256 public constant RATE_DENOMINATOR = 1_000_000;
    uint256 public constant CREATOR_WETH_PIPS = 700_000;
    uint256 public constant TREASURY_WETH_PIPS = 150_000;
    uint256 public constant TOKEN_RESERVE_PIPS = 200_000;
    address public constant BURN_SINK = 0x000000000000000000000000000000000000dEaD;
    uint256 private constant ROBINHOOD_CHAIN_ID = 4663;
    address private constant LIVE_DEGEN = 0x04d5D8a61DA0b6548B136412843aDBA55EbeaDE6;
    bytes32 private constant LIVE_DEGEN_POOL_ID =
        0x6ed2072a6360ee46bfac4645d195f1427b642fc40806b0b7fd8ad3cd9d07b028;

    address public immutable module;
    address public immutable weth;
    INonfungiblePositionManagerMinimal public immutable positionManager;
    address public immutable v3Factory;
    address public immutable treasury;
    address public immutable tokenReserve;
    address public immutable buybackVault;

    mapping(address token => PositionConfig config) private _positions;

    modifier onlyModule() {
        if (msg.sender != module) revert OnlyModule();
        _;
    }

    constructor(
        address module_,
        address weth_,
        address positionManager_,
        address treasury_,
        address tokenReserve_,
        address buybackVault_
    ) {
        if (
            module_ == address(0) || weth_ == address(0) || positionManager_ == address(0)
                || treasury_ == address(0) || tokenReserve_ == address(0)
                || buybackVault_ == address(0) || weth_.code.length == 0
                || positionManager_.code.length == 0 || buybackVault_.code.length == 0
                || treasury_ == address(this) || tokenReserve_ == address(this)
        ) {
            revert InvalidAddress();
        }

        address factory_ = INonfungiblePositionManagerMinimal(positionManager_).factory();
        if (factory_ == address(0) || factory_.code.length == 0) revert InvalidAddress();
        IDegenBuybackVault vault = IDegenBuybackVault(buybackVault_);
        if (
            address(vault.poolManager()).code.length == 0 || vault.weth() != weth_
                || vault.degen() == address(0) || PoolId.unwrap(vault.poolId()) == bytes32(0)
                || vault.burnSink() != BURN_SINK
                || (block.chainid == ROBINHOOD_CHAIN_ID
                    && (vault.degen() != LIVE_DEGEN
                        || PoolId.unwrap(vault.poolId()) != LIVE_DEGEN_POOL_ID))
        ) {
            revert InvalidBuybackVault();
        }

        module = module_;
        weth = weth_;
        positionManager = INonfungiblePositionManagerMinimal(positionManager_);
        v3Factory = factory_;
        treasury = treasury_;
        tokenReserve = tokenReserve_;
        buybackVault = buybackVault_;
    }

    function positionForToken(address token) external view returns (PositionConfig memory) {
        return _positions[token];
    }

    function placeLiquidity(
        address pool,
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
        _validatePool(pool, token);

        IERC20 launchToken = IERC20(token);
        uint256 balanceBefore = launchToken.balanceOf(address(this));
        launchToken.safeTransferFrom(msg.sender, address(this), poolSupply);
        uint256 balanceAfterTransfer = launchToken.balanceOf(address(this));
        if (
            balanceAfterTransfer < balanceBefore
                || balanceAfterTransfer - balanceBefore != poolSupply
        ) {
            revert UnsupportedTokenBehavior();
        }

        launchToken.forceApprove(address(positionManager), poolSupply);
        uint256[7] memory positionIds;
        uint256 tokenPrincipal;
        for (uint256 i; i < DegenV1UniswapV3LaunchConstants.TRANCHE_COUNT; ++i) {
            uint256 trancheSupply = poolSupply * DegenV1UniswapV3LaunchConstants.supplySharePips(i)
                / DegenV1UniswapV3LaunchConstants.RATE_DENOMINATOR;
            (uint256 positionId,, uint256 amount0, uint256 amount1) = positionManager.mint(
                INonfungiblePositionManagerMinimal.MintParams({
                    token0: token,
                    token1: weth,
                    fee: DegenV1UniswapV3LaunchConstants.POOL_FEE,
                    tickLower: DegenV1UniswapV3LaunchConstants.lowerTick(i),
                    tickUpper: DegenV1UniswapV3LaunchConstants.upperTick(i),
                    amount0Desired: trancheSupply,
                    amount1Desired: 0,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: address(this),
                    deadline: block.timestamp
                })
            );
            if (amount0 == 0 || amount0 > trancheSupply || amount1 != 0) {
                revert UnsupportedTokenBehavior();
            }
            _validatePositionReceipt(positionIds, i, positionId, token);
            positionIds[i] = positionId;
            tokenPrincipal += amount0;
        }
        launchToken.forceApprove(address(positionManager), 0);

        uint256 balanceAfter = launchToken.balanceOf(address(this));
        if (balanceAfter < balanceBefore) revert PrincipalAccountingMismatch();
        uint256 lockedTokenDust = balanceAfter - balanceBefore;
        if (tokenPrincipal + lockedTokenDust != poolSupply) {
            revert PrincipalAccountingMismatch();
        }

        _positions[token] = PositionConfig({
            pool: pool,
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
            pool,
            firstPositionId,
            beneficiary,
            feeAdmin,
            poolSupply,
            tokenPrincipal,
            lockedTokenDust
        );
    }

    /// @notice Collects all six position fees and routes them to immutable destinations.
    /// @dev Anyone may call. Only balance increases observed during this call are routed.
    function claimFees(address token)
        external
        nonReentrant
        returns (uint256 beneficiaryWethDelivered)
    {
        PositionConfig storage config = _positions[token];
        if (!config.placed) revert PositionNotPlaced();
        beneficiaryWethDelivered = _collectAndRoute(token, config, msg.sender);
    }

    /// @notice Checkpoints accrued fees to the old beneficiary before changing future routing.
    function updateBeneficiary(address token, address newBeneficiary) external nonReentrant {
        if (newBeneficiary == address(0) || newBeneficiary == address(this)) {
            revert InvalidBeneficiary();
        }
        PositionConfig storage config = _positions[token];
        if (!config.placed) revert PositionNotPlaced();
        if (msg.sender != config.feeAdmin) revert OnlyFeeAdmin();

        address oldBeneficiary = config.beneficiary;
        _collectAndRoute(token, config, msg.sender);
        config.beneficiary = newBeneficiary;
        emit BeneficiaryUpdated(token, oldBeneficiary, newBeneficiary);
    }

    function updateFeeAdmin(address token, address newFeeAdmin) external {
        if (newFeeAdmin == address(0)) revert InvalidFeeAdmin();
        PositionConfig storage config = _positions[token];
        if (!config.placed) revert PositionNotPlaced();
        if (msg.sender != config.feeAdmin) revert OnlyFeeAdmin();

        address oldFeeAdmin = config.feeAdmin;
        config.feeAdmin = newFeeAdmin;
        emit FeeAdminUpdated(token, oldFeeAdmin, newFeeAdmin);
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC721Receiver.onERC721Received.selector;
    }

    function _validatePool(address pool, address token) private view {
        if (pool == address(0) || token == address(0) || token >= weth || pool.code.length == 0) {
            revert InvalidPool();
        }

        IUniswapV3PoolMinimal candidate = IUniswapV3PoolMinimal(pool);
        (uint160 sqrtPriceX96, int24 tick,,,,,) = candidate.slot0();
        if (
            candidate.factory() != v3Factory || candidate.token0() != token
                || candidate.token1() != weth
                || candidate.fee() != DegenV1UniswapV3LaunchConstants.POOL_FEE
                || candidate.tickSpacing() != DegenV1UniswapV3LaunchConstants.TICK_SPACING
                || sqrtPriceX96
                    != TickMath.getSqrtPriceAtTick(DegenV1UniswapV3LaunchConstants.INITIAL_TICK)
                || tick != DegenV1UniswapV3LaunchConstants.INITIAL_TICK
        ) {
            revert InvalidPool();
        }
    }

    function _collectAndRoute(address token, PositionConfig storage config, address caller)
        private
        returns (uint256 creatorWeth)
    {
        IERC20 launchToken = IERC20(token);
        IERC20 wrappedEther = IERC20(weth);
        uint256 tokenBalanceBefore = launchToken.balanceOf(address(this));
        uint256 wethBalanceBefore = wrappedEther.balanceOf(address(this));

        for (uint256 i; i < DegenV1UniswapV3LaunchConstants.TRANCHE_COUNT; ++i) {
            positionManager.collect(
                INonfungiblePositionManagerMinimal.CollectParams({
                    tokenId: config.positionIds[i],
                    recipient: address(this),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );
        }

        uint256 tokenBalanceAfter = launchToken.balanceOf(address(this));
        uint256 wethBalanceAfter = wrappedEther.balanceOf(address(this));
        if (tokenBalanceAfter < tokenBalanceBefore || wethBalanceAfter < wethBalanceBefore) {
            revert FeeAccountingMismatch();
        }
        uint256 tokenFees = tokenBalanceAfter - tokenBalanceBefore;
        uint256 wethFees = wethBalanceAfter - wethBalanceBefore;

        uint256 tokenToReserve = tokenFees * TOKEN_RESERVE_PIPS / RATE_DENOMINATOR;
        uint256 tokenToBurn = tokenFees - tokenToReserve;
        creatorWeth = wethFees * CREATOR_WETH_PIPS / RATE_DENOMINATOR;
        uint256 treasuryWeth = wethFees * TREASURY_WETH_PIPS / RATE_DENOMINATOR;
        uint256 buybackWeth = wethFees - creatorWeth - treasuryWeth;

        if (tokenToReserve != 0) launchToken.safeTransfer(tokenReserve, tokenToReserve);
        if (tokenToBurn != 0) launchToken.safeTransfer(BURN_SINK, tokenToBurn);
        if (creatorWeth != 0) wrappedEther.safeTransfer(config.beneficiary, creatorWeth);
        if (treasuryWeth != 0) wrappedEther.safeTransfer(treasury, treasuryWeth);
        if (buybackWeth != 0) wrappedEther.safeTransfer(buybackVault, buybackWeth);

        if (
            launchToken.balanceOf(address(this)) != tokenBalanceBefore
                || wrappedEther.balanceOf(address(this)) != wethBalanceBefore
        ) {
            revert FeeAccountingMismatch();
        }

        emit FeesDelivered(
            token,
            config.beneficiary,
            caller,
            tokenFees,
            tokenToReserve,
            tokenToBurn,
            wethFees,
            creatorWeth,
            treasuryWeth,
            buybackWeth
        );
    }

    function _validatePositionReceipt(
        uint256[7] memory existingIds,
        uint256 index,
        uint256 positionId,
        address token
    ) private view {
        if (positionId == 0 || positionManager.ownerOf(positionId) != address(this)) {
            revert InvalidPositionReceipt();
        }
        for (uint256 i; i < index; ++i) {
            if (existingIds[i] == positionId) revert InvalidPositionReceipt();
        }

        (
            ,,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,,,,
        ) = positionManager.positions(positionId);
        if (
            token0 != token || token1 != weth || fee != DegenV1UniswapV3LaunchConstants.POOL_FEE
                || tickLower != DegenV1UniswapV3LaunchConstants.lowerTick(index)
                || tickUpper != DegenV1UniswapV3LaunchConstants.upperTick(index) || liquidity == 0
        ) {
            revert InvalidPositionReceipt();
        }
    }
}
