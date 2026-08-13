// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {DomainId, LaunchContext, LaunchResult, TemplateId, Version} from "../LaunchHub.sol";
import {IDegenV1UniswapV3LpLocker} from "../interfaces/IDegenV1UniswapV3LpLocker.sol";
import {IDegenV1UniswapV3Module} from "../interfaces/IDegenV1UniswapV3Module.sol";
import {
    INonfungiblePositionManagerMinimal
} from "../interfaces/INonfungiblePositionManagerMinimal.sol";
import {IUniswapV3PoolMinimal} from "../interfaces/IUniswapV3PoolMinimal.sol";
import {DegenV1UniswapV3LaunchConstants} from "../libraries/DegenV1UniswapV3LaunchConstants.sol";

interface IDegenV1UniswapV3LpLockerBinding {
    function module() external view returns (address);
    function weth() external view returns (address);
    function positionManager() external view returns (INonfungiblePositionManagerMinimal);
    function v3Factory() external view returns (address);
}

/// @title DEGEN V1 — Uniswap V3 LaunchHub module
/// @notice Creates and validates the 1% pool, then permanently locks the complete launch supply.
/// @dev A later venue protocol-fee change may reduce future LP earnings, but cannot move the NFTs,
/// principal, or immutable locker fee destinations.
contract DegenV1UniswapV3Module is IDegenV1UniswapV3Module {
    using SafeERC20 for IERC20;

    uint256 public constant POOL_SUPPLY = 100_000_000_000 ether;
    TemplateId public constant TEMPLATE_ID = TemplateId.wrap(3);
    Version public constant VERSION = Version.wrap(1);
    bytes32 public constant EMPTY_SCHEMA_HASH = keccak256("EMPTY");

    address public immutable kernel;
    DomainId public immutable domainId;
    bytes32 public immutable configHash;
    IDegenV1UniswapV3LpLocker public immutable lpLocker;
    INonfungiblePositionManagerMinimal public immutable positionManager;
    address public immutable v3Factory;
    address public immutable weth;

    constructor(address kernel_, DomainId domainId_, bytes32 configHash_, address lpLocker_) {
        if (
            kernel_ == address(0) || DomainId.unwrap(domainId_) == bytes32(0)
                || configHash_ == bytes32(0) || lpLocker_ == address(0)
                || lpLocker_.code.length == 0
        ) {
            revert InvalidAddress();
        }

        IDegenV1UniswapV3LpLockerBinding binding = IDegenV1UniswapV3LpLockerBinding(lpLocker_);
        INonfungiblePositionManagerMinimal manager = binding.positionManager();
        address factory = binding.v3Factory();
        address wrappedEther = binding.weth();
        if (
            binding.module() != address(this) || address(manager) == address(0)
                || address(manager).code.length == 0 || factory == address(0)
                || factory.code.length == 0 || wrappedEther == address(0)
                || wrappedEther.code.length == 0 || manager.factory() != factory
        ) {
            revert InvalidChildBinding();
        }

        kernel = kernel_;
        domainId = domainId_;
        configHash = configHash_;
        lpLocker = IDegenV1UniswapV3LpLocker(lpLocker_);
        positionManager = manager;
        v3Factory = factory;
        weth = wrappedEther;
    }

    function configure(LaunchContext calldata context)
        external
        returns (LaunchResult memory result)
    {
        if (msg.sender != kernel) {
            revert OnlyKernel(msg.sender);
        }
        if (
            DomainId.unwrap(context.domainId) != DomainId.unwrap(domainId)
                || TemplateId.unwrap(context.templateId) != TemplateId.unwrap(TEMPLATE_ID)
                || Version.unwrap(context.version) != Version.unwrap(VERSION)
                || context.token == address(0) || context.token >= weth
                || context.feeAdmin == address(0) || context.beneficiary == address(0)
                || context.inputSchemaHash != EMPTY_SCHEMA_HASH || context.launchData.length != 0
        ) {
            revert InvalidLaunchContext();
        }

        IERC20 token = IERC20(context.token);
        uint256 balance = token.balanceOf(address(this));
        if (balance != POOL_SUPPLY) revert InvalidTokenBalance(POOL_SUPPLY, balance);

        uint160 initialSqrtPrice =
            TickMath.getSqrtPriceAtTick(DegenV1UniswapV3LaunchConstants.INITIAL_TICK);
        address pool = positionManager.createAndInitializePoolIfNecessary(
            context.token, weth, DegenV1UniswapV3LaunchConstants.POOL_FEE, initialSqrtPrice
        );
        _validatePool(pool, context.token, initialSqrtPrice);

        token.forceApprove(address(lpLocker), POOL_SUPPLY);
        uint256 firstPositionId = lpLocker.placeLiquidity(
            pool, context.token, POOL_SUPPLY, context.beneficiary, context.feeAdmin
        );
        token.forceApprove(address(lpLocker), 0);

        balance = token.balanceOf(address(this));
        if (balance != 0) revert TokenResidue(balance);

        result = LaunchResult({
            poolId: bytes32(uint256(uint160(pool))),
            positionId: firstPositionId,
            configEcho: configHash
        });
        emit DegenUniswapV3LaunchConfigured(
            context.token, pool, firstPositionId, context.beneficiary, context.feeAdmin
        );
    }

    function _validatePool(address pool, address token, uint160 initialSqrtPrice) private view {
        if (pool == address(0) || pool.code.length == 0) revert InvalidPoolState();
        IUniswapV3PoolMinimal candidate = IUniswapV3PoolMinimal(pool);
        (uint160 sqrtPriceX96, int24 tick,,,, uint8 feeProtocol, bool unlocked) = candidate.slot0();
        if (feeProtocol != 0) revert NonzeroProtocolFee(feeProtocol);
        if (
            candidate.factory() != v3Factory || candidate.token0() != token
                || candidate.token1() != weth
                || candidate.fee() != DegenV1UniswapV3LaunchConstants.POOL_FEE
                || candidate.tickSpacing() != DegenV1UniswapV3LaunchConstants.TICK_SPACING
                || sqrtPriceX96 != initialSqrtPrice
                || tick != DegenV1UniswapV3LaunchConstants.INITIAL_TICK || !unlocked
        ) {
            revert InvalidPoolState();
        }
    }
}
