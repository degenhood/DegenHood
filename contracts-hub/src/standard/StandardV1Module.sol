// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {DomainId, LaunchContext, LaunchResult, TemplateId, Version} from "../LaunchHub.sol";
import {IStandardV1Hook} from "../interfaces/IStandardV1Hook.sol";
import {IStandardV1LpLocker} from "../interfaces/IStandardV1LpLocker.sol";
import {IStandardV1Module} from "../interfaces/IStandardV1Module.sol";

interface IStandardV1HookBinding {
    function module() external view returns (address);
    function poolManager() external view returns (IPoolManager);
    function feeLocker() external view returns (address);
}

interface IStandardV1LpLockerBinding {
    function module() external view returns (address);
    function hook() external view returns (address);
    function feeLocker() external view returns (address);
}

/// @notice Atomically configures a new Hub Standard V1 launch.
contract StandardV1Module is IStandardV1Module {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    uint256 public constant POOL_SUPPLY = 100_000_000_000 ether;
    TemplateId public constant TEMPLATE_ID = TemplateId.wrap(1);
    Version public constant VERSION = Version.wrap(1);
    bytes32 public constant EMPTY_SCHEMA_HASH = keccak256("EMPTY");
    int24 public constant INITIAL_TICK = -230_400;

    address public immutable kernel;
    DomainId public immutable domainId;
    bytes32 public immutable configHash;
    IStandardV1Hook public immutable hook;
    IStandardV1LpLocker public immutable lpLocker;
    IPoolManager public immutable poolManager;

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
        ) {
            revert InvalidAddress();
        }
        if (hook_.code.length == 0 || lpLocker_.code.length == 0) revert InvalidAddress();
        if (
            IStandardV1HookBinding(hook_).module() != address(this)
                || IStandardV1LpLockerBinding(lpLocker_).module() != address(this)
                || IStandardV1LpLockerBinding(lpLocker_).hook() != hook_
                || IStandardV1HookBinding(hook_).feeLocker()
                    != IStandardV1LpLockerBinding(lpLocker_).feeLocker()
        ) {
            revert InvalidChildBinding();
        }
        IPoolManager manager = IStandardV1HookBinding(hook_).poolManager();
        if (address(manager) == address(0)) revert InvalidChildBinding();
        kernel = kernel_;
        domainId = domainId_;
        configHash = configHash_;
        hook = IStandardV1Hook(hook_);
        lpLocker = IStandardV1LpLocker(lpLocker_);
        poolManager = manager;
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
        ) {
            revert InvalidLaunchContext();
        }
        IERC20 token = IERC20(context.token);
        uint256 balance = token.balanceOf(address(this));
        if (balance != POOL_SUPPLY) revert InvalidTokenBalance(POOL_SUPPLY, balance);

        PoolKey memory poolKey =
            hook.registerPool(context.token, context.beneficiary, address(lpLocker));
        poolManager.initialize(poolKey, TickMath.getSqrtPriceAtTick(INITIAL_TICK));
        token.forceApprove(address(lpLocker), POOL_SUPPLY);
        uint256 positionId = lpLocker.placeLiquidity(
            poolKey, context.token, POOL_SUPPLY, context.beneficiary, context.feeAdmin
        );
        token.forceApprove(address(lpLocker), 0);
        balance = token.balanceOf(address(this));
        if (balance != 0) revert TokenResidue(balance);

        bytes32 poolId = PoolId.unwrap(poolKey.toId());
        result = LaunchResult({poolId: poolId, positionId: positionId, configEcho: configHash});
        emit StandardLaunchConfigured(
            context.token, poolId, positionId, context.beneficiary, context.feeAdmin
        );
    }
}
