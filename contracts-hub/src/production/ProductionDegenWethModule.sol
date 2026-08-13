// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {IDegenHoodTokenV5} from "../interfaces/IDegenHoodTokenV5.sol";
import {IDegenV3Hook} from "../interfaces/IDegenV3Hook.sol";
import {IDegenV3LpLocker} from "../interfaces/IDegenV3LpLocker.sol";
import {DegenV3LaunchConstants} from "../libraries/DegenV3LaunchConstants.sol";
import {
    DomainId,
    LaunchContext,
    LaunchResult,
    TemplateId,
    Version
} from "./ProductionLaunchTypes.sol";

interface IDegenV3HookBinding {
    function module() external view returns (address);
    function poolManager() external view returns (IPoolManager);
    function feeLocker() external view returns (address);
}

interface IDegenV3LpLockerBinding {
    function module() external view returns (address);
    function hook() external view returns (address);
    function feeLocker() external view returns (address);
    function positionManager() external view returns (IPositionManager);
    function tokenReserve() external view returns (address);
}

interface IDegenWethModule {
    /// @notice Raised when `configure` is called by any account other than the bound kernel.
    /// @param caller Account that attempted configuration.
    error OnlyKernel(address caller);
    /// @notice Raised when construction receives a required zero-address dependency.
    error InvalidAddress();
    /// @notice Raised when the hook or locker does not point back to the expected V3 graph.
    error InvalidChildBinding();
    /// @notice Raised when template, version, schema, or launch arguments differ from this module.
    error InvalidLaunchContext();
    /// @notice Raised when the module does not hold the exact fixed launch supply before minting.
    /// @param expected Required token balance.
    /// @param actual Observed token balance.
    error InvalidTokenBalance(uint256 expected, uint256 actual);
    /// @notice Raised when a launched token fails the transfer/balance behavior required for settlement.
    error UnsupportedTokenBehavior();
    /// @notice Raised when token balance remains in the module after all positions are minted.
    /// @param balance Unexpected residue remaining in the module.
    error TokenResidue(uint256 balance);
    /// @notice Raised when a minted position's owner, pool, ticks, or liquidity differs from the curve.
    error InvalidPositionReceipt();

    /// @notice Emitted after the pool and all ten permanent positions are configured successfully.
    /// @param token Launched token address.
    /// @param poolId Uniswap v4 pool identifier.
    /// @param firstPositionId Token ID of the first contiguous position receipt.
    /// @param beneficiary Initial creator fee beneficiary.
    /// @param feeAdmin Account permitted to rotate creator fee destinations.
    /// @param maxWalletBps Flat-phase wallet cap in basis points of fixed supply.
    /// @param maxTxBps Flat-phase transaction cap in basis points of fixed supply.
    /// @param restrictionClock Clock discriminator for the schedule; `1` means unix timestamp.
    /// @param restrictionStartTime Timestamp at which the immutable cap schedule began.
    /// @param flatEndTime First timestamp of the linear cap-release phase.
    /// @param rampEndTime First timestamp at which both caps are fully unrestricted.
    event DegenLaunchConfigured(
        address indexed token,
        bytes32 indexed poolId,
        uint256 indexed firstPositionId,
        address beneficiary,
        address feeAdmin,
        uint16 maxWalletBps,
        uint16 maxTxBps,
        uint8 restrictionClock,
        uint40 restrictionStartTime,
        uint40 flatEndTime,
        uint40 rampEndTime
    );

    /// @notice Configures the one-sided ten-position pool for a kernel-created token.
    /// @param context Kernel-authenticated launch context.
    /// @return result Token, pool, fee claimer, and launch-specific result returned to the kernel.
    function configure(LaunchContext calldata context) external returns (LaunchResult memory result);
    /// @notice Returns the only kernel authorized to configure this module.
    /// @return kernel_ Bound LaunchHub kernel.
    function kernel() external view returns (address kernel_);
    /// @notice Returns the domain in which this module is registered.
    /// @return domainId_ Bound LaunchHub domain identifier.
    function domainId() external view returns (DomainId domainId_);
    /// @notice Returns the immutable configuration commitment admitted by the kernel.
    /// @return configHash_ Hash of the reviewed module graph and launch policy.
    function configHash() external view returns (bytes32 configHash_);
}

/// @title Degen WETH LaunchHub module
/// @notice Creates the reviewed ten-position WETH pool for production template 1/1.
contract DegenWethModule is IDegenWethModule {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    uint256 public constant POOL_SUPPLY = 100_000_000_000 ether;
    TemplateId public constant TEMPLATE_ID = TemplateId.wrap(1);
    Version public constant VERSION = Version.wrap(1);
    bytes32 public constant EMPTY_SCHEMA_HASH = keccak256("EMPTY");
    uint8 public constant RESTRICTION_CLOCK_TIMESTAMP = 1;
    int24 public constant INITIAL_TICK = DegenV3LaunchConstants.INITIAL_TICK;

    uint256 private constant ROBINHOOD_CHAIN_ID = 4663;
    address private constant ROBINHOOD_POSITION_MANAGER =
        0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address private constant ROBINHOOD_TOKEN_RESERVE = 0x19e81C012B635646cA7543Ac1Dfca10B93835538;

    address public immutable kernel;
    DomainId public immutable domainId;
    bytes32 public immutable configHash;
    IDegenV3Hook public immutable hook;
    IDegenV3LpLocker public immutable lpLocker;
    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;

    constructor(
        address kernel_,
        DomainId domainId_,
        bytes32 configHash_,
        address hook_,
        address lpLocker_
    ) {
        if (
            kernel_ == address(0) || DomainId.unwrap(domainId_) == bytes32(0)
                || configHash_ == bytes32(0) || hook_ == address(0) || lpLocker_ == address(0)
                || hook_.code.length == 0 || lpLocker_.code.length == 0
        ) revert InvalidAddress();
        IDegenV3HookBinding hookBinding = IDegenV3HookBinding(hook_);
        IDegenV3LpLockerBinding lockerBinding = IDegenV3LpLockerBinding(lpLocker_);
        if (
            hookBinding.module() != address(this) || lockerBinding.module() != address(this)
                || lockerBinding.hook() != hook_
                || hookBinding.feeLocker() != lockerBinding.feeLocker()
        ) revert InvalidChildBinding();

        IPoolManager manager = hookBinding.poolManager();
        IPositionManager positions = lockerBinding.positionManager();
        if (
            address(manager) == address(0) || address(positions) == address(0)
                || (block.chainid == ROBINHOOD_CHAIN_ID
                    && (address(positions) != ROBINHOOD_POSITION_MANAGER
                        || lockerBinding.tokenReserve() != ROBINHOOD_TOKEN_RESERVE))
        ) {
            revert InvalidChildBinding();
        }
        kernel = kernel_;
        domainId = domainId_;
        configHash = configHash_;
        hook = IDegenV3Hook(hook_);
        lpLocker = IDegenV3LpLocker(lpLocker_);
        poolManager = manager;
        positionManager = positions;
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
                || context.token == address(0) || context.feeAdmin == address(0)
                || context.beneficiary == address(0) || context.inputSchemaHash != EMPTY_SCHEMA_HASH
                || context.launchData.length != 0
        ) revert InvalidLaunchContext();

        IERC20 token = IERC20(context.token);
        uint256 balance = token.balanceOf(address(this));
        if (balance != POOL_SUPPLY) revert InvalidTokenBalance(POOL_SUPPLY, balance);
        PoolKey memory poolKey =
            hook.registerPool(context.token, context.beneficiary, address(lpLocker));
        poolManager.initialize(poolKey, TickMath.getSqrtPriceAtTick(INITIAL_TICK));

        uint256 positionManagerBalanceBefore = token.balanceOf(address(positionManager));
        token.safeTransfer(address(positionManager), POOL_SUPPLY);
        if (token.balanceOf(address(positionManager)) - positionManagerBalanceBefore != POOL_SUPPLY)
        {
            revert UnsupportedTokenBehavior();
        }

        uint256 firstPositionId = positionManager.nextTokenId();
        uint256[10] memory positionIds;
        bytes memory actions = new bytes(DegenV3LaunchConstants.TRANCHE_COUNT + 3);
        bytes[] memory params = new bytes[](DegenV3LaunchConstants.TRANCHE_COUNT + 3);
        for (uint256 i; i < DegenV3LaunchConstants.TRANCHE_COUNT; ++i) {
            positionIds[i] = firstPositionId + i;
            actions[i] = bytes1(uint8(Actions.MINT_POSITION));
            uint256 trancheSupply = DegenV3LaunchConstants.trancheSupply(POOL_SUPPLY, i);
            params[i] = abi.encode(
                poolKey,
                DegenV3LaunchConstants.lowerTick(i),
                DegenV3LaunchConstants.upperTick(i),
                uint256(DegenV3LaunchConstants.liquidity(POOL_SUPPLY, i)),
                uint128(trancheSupply),
                uint128(0),
                address(lpLocker),
                bytes("")
            );
        }

        uint256 settleIndex = DegenV3LaunchConstants.TRANCHE_COUNT;
        actions[settleIndex] = bytes1(uint8(Actions.SETTLE));
        params[settleIndex] =
            abi.encode(poolKey.currency0, uint256(ActionConstants.OPEN_DELTA), false);
        actions[settleIndex + 1] = bytes1(uint8(Actions.CLOSE_CURRENCY));
        params[settleIndex + 1] = abi.encode(poolKey.currency1);
        actions[settleIndex + 2] = bytes1(uint8(Actions.SWEEP));
        params[settleIndex + 2] = abi.encode(poolKey.currency0, address(lpLocker));
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        for (uint256 i; i < DegenV3LaunchConstants.TRANCHE_COUNT; ++i) {
            if (IERC721(address(positionManager)).ownerOf(positionIds[i]) != address(lpLocker)) {
                revert InvalidPositionReceipt();
            }
        }
        if (token.balanceOf(address(positionManager)) != positionManagerBalanceBefore) {
            revert TokenResidue(token.balanceOf(address(positionManager)));
        }
        firstPositionId = lpLocker.registerPositions(
            poolKey, context.token, positionIds, POOL_SUPPLY, context.beneficiary, context.feeAdmin
        );
        balance = token.balanceOf(address(this));
        if (balance != 0) revert TokenResidue(balance);

        bytes32 poolId = PoolId.unwrap(poolKey.toId());
        result = LaunchResult({poolId: poolId, positionId: firstPositionId, configEcho: configHash});
        IDegenHoodTokenV5 restrictedToken = IDegenHoodTokenV5(context.token);
        emit DegenLaunchConfigured(
            context.token,
            poolId,
            firstPositionId,
            context.beneficiary,
            context.feeAdmin,
            uint16(restrictedToken.MAX_WALLET_BPS()),
            uint16(restrictedToken.MAX_TX_BPS()),
            RESTRICTION_CLOCK_TIMESTAMP,
            restrictedToken.restrictionStartTime(),
            restrictedToken.flatEndTime(),
            restrictedToken.rampEndTime()
        );
    }
}
