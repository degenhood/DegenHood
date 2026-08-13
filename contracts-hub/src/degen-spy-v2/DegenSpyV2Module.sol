// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {DomainId, LaunchContext, LaunchResult, TemplateId, Version} from "../LaunchHub.sol";
import {IAccessControlsRegistryMinimal} from "../interfaces/IAccessControlsRegistryMinimal.sol";
import {IDegenSpyV2Hook} from "../interfaces/IDegenSpyV2Hook.sol";
import {IDegenSpyV2LpLocker} from "../interfaces/IDegenSpyV2LpLocker.sol";
import {IDegenSpyV2Module} from "../interfaces/IDegenSpyV2Module.sol";
import {IRobinhoodStockToken} from "../interfaces/IRobinhoodStockToken.sol";
import {DegenSpyV2LaunchConstants} from "../libraries/DegenSpyV2LaunchConstants.sol";

interface IDegenSpyV2HookBinding {
    function module() external view returns (address);
    function poolManager() external view returns (IPoolManager);
    function feeLocker() external view returns (address);
    function spy() external view returns (address);
    function operatingTreasury() external view returns (address);
    function buybackVault() external view returns (address);
}

interface IDegenSpyV2LockerBinding {
    function module() external view returns (address);
    function hook() external view returns (address);
    function feeLocker() external view returns (address);
    function spy() external view returns (address);
    function positionManager() external view returns (address);
    function permit2() external view returns (address);
}

/// @title SPY V4 V2 LaunchHub module
/// @notice Revalidates the issuer transfer surface before creating the ~25 SPY six-position pool.
contract DegenSpyV2Module is IDegenSpyV2Module {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    uint256 public constant POOL_SUPPLY = 100_000_000_000 ether;
    TemplateId public constant TEMPLATE_ID = TemplateId.wrap(4);
    Version public constant VERSION = Version.wrap(2);
    bytes32 public constant EMPTY_SCHEMA_HASH = keccak256("EMPTY");
    int24 public constant INITIAL_TICK = DegenSpyV2LaunchConstants.INITIAL_TICK;

    address public immutable kernel;
    DomainId public immutable domainId;
    bytes32 public immutable configHash;
    IDegenSpyV2Hook public immutable hook;
    IDegenSpyV2LpLocker public immutable lpLocker;
    IPoolManager public immutable poolManager;
    IRobinhoodStockToken public immutable spy;
    mapping(address => uint256) public launchUiMultiplier;

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
        ) revert InvalidAddress();
        if (hook_.code.length == 0 || lpLocker_.code.length == 0) revert InvalidAddress();
        IDegenSpyV2HookBinding hookBinding = IDegenSpyV2HookBinding(hook_);
        IDegenSpyV2LockerBinding lockerBinding = IDegenSpyV2LockerBinding(lpLocker_);
        address quoteToken = hookBinding.spy();
        if (
            hookBinding.module() != address(this) || lockerBinding.module() != address(this)
                || lockerBinding.hook() != hook_ || lockerBinding.spy() != quoteToken
                || hookBinding.feeLocker() != lockerBinding.feeLocker()
                || (block.chainid == 4663 && quoteToken != DegenSpyV2LaunchConstants.SPY)
        ) revert InvalidChildBinding();
        IPoolManager manager = hookBinding.poolManager();
        if (address(manager) == address(0) || quoteToken.code.length == 0) {
            revert InvalidChildBinding();
        }
        kernel = kernel_;
        domainId = domainId_;
        configHash = configHash_;
        hook = IDegenSpyV2Hook(hook_);
        lpLocker = IDegenSpyV2LpLocker(lpLocker_);
        poolManager = manager;
        spy = IRobinhoodStockToken(quoteToken);
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
        uint256 observedMultiplier = _validateSpyTransferSurface(context.beneficiary);
        IERC20 token = IERC20(context.token);
        uint256 balance = token.balanceOf(address(this));
        if (balance != POOL_SUPPLY) revert InvalidTokenBalance(POOL_SUPPLY, balance);
        PoolKey memory poolKey =
            hook.registerPool(context.token, context.beneficiary, address(lpLocker));
        poolManager.initialize(poolKey, TickMath.getSqrtPriceAtTick(INITIAL_TICK));
        token.forceApprove(address(lpLocker), POOL_SUPPLY);
        uint256 firstPositionId = lpLocker.placeLiquidity(
            poolKey, context.token, POOL_SUPPLY, context.beneficiary, context.feeAdmin
        );
        token.forceApprove(address(lpLocker), 0);
        balance = token.balanceOf(address(this));
        if (balance != 0) revert TokenResidue(balance);
        launchUiMultiplier[context.token] = observedMultiplier;
        bytes32 poolId = PoolId.unwrap(poolKey.toId());
        result = LaunchResult({poolId: poolId, positionId: firstPositionId, configEcho: configHash});
        emit DegenSpyLaunchConfigured(
            context.token,
            poolId,
            firstPositionId,
            context.beneficiary,
            context.feeAdmin,
            observedMultiplier
        );
    }

    function _validateSpyTransferSurface(address beneficiary) private view returns (uint256) {
        bytes32 observedUid = spy.uid();
        if (observedUid != DegenSpyV2LaunchConstants.SPY_UID) {
            revert InvalidSpyIdentity(observedUid);
        }
        address registryAddress = spy.ACCESS_CONTROLLED_REGISTRY();
        if (
            registryAddress.code.length == 0
                || (block.chainid == 4663
                    && registryAddress != DegenSpyV2LaunchConstants.SPY_REGISTRY)
        ) revert InvalidSpyRegistry(registryAddress);
        IAccessControlsRegistryMinimal registry = IAccessControlsRegistryMinimal(registryAddress);
        if (spy.paused() || registry.paused()) revert SpyTransfersPaused();
        IDegenSpyV2HookBinding hookBinding = IDegenSpyV2HookBinding(address(hook));
        IDegenSpyV2LockerBinding lockerBinding = IDegenSpyV2LockerBinding(address(lpLocker));
        _requireNotBlocked(registry, address(hook));
        _requireNotBlocked(registry, address(lpLocker));
        _requireNotBlocked(registry, hookBinding.feeLocker());
        _requireNotBlocked(registry, hookBinding.operatingTreasury());
        _requireNotBlocked(registry, hookBinding.buybackVault());
        _requireNotBlocked(registry, address(poolManager));
        _requireNotBlocked(registry, lockerBinding.positionManager());
        _requireNotBlocked(registry, lockerBinding.permit2());
        _requireNotBlocked(registry, address(this));
        _requireNotBlocked(registry, beneficiary);
        return spy.uiMultiplier();
    }

    function _requireNotBlocked(IAccessControlsRegistryMinimal registry, address account)
        private
        view
    {
        if (registry.isBlocked(account)) revert SpyAddressBlocked(account);
    }
}
