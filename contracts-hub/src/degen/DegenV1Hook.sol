// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";

import {IDegenBuybackVault} from "../interfaces/IDegenBuybackVault.sol";
import {IDegenV1FeeLocker} from "../interfaces/IDegenV1FeeLocker.sol";
import {IDegenV1Hook} from "../interfaces/IDegenV1Hook.sol";
import {DegenFeeMath} from "../libraries/DegenFeeMath.sol";
import {DegenLaunchConstants} from "../libraries/DegenLaunchConstants.sol";

/// @title DEGEN_V1 Uniswap v4 hook
/// @notice Applies immutable launch and permanent fees to canonical token/WETH pools.
/// @dev Fee settlement is permissionless but every destination is constructor-bound. An
/// exact-input WETH buy charges the hook fee against requested input. If a caller supplies a tight
/// sqrtPriceLimitX96 and the swap partially fills, the fee can therefore exceed the fee on realized
/// WETH input. Integrators must disclose and quote this behavior rather than assuming realized-input
/// fee accounting for that quadrant.
contract DegenV1Hook is BaseHook, IDegenV1Hook, IUnlockCallback, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    uint24 public constant LP_FEE = uint24(DegenLaunchConstants.LP_FEE_RATE);
    int24 public constant TICK_SPACING = 200;
    int24 public constant INITIAL_TICK = -246_400;
    uint256 private constant ROBINHOOD_CHAIN_ID = 4663;
    address private constant LIVE_DEGEN = 0x04d5D8a61DA0b6548B136412843aDBA55EbeaDE6;
    bytes32 private constant LIVE_DEGEN_POOL_ID =
        0x6ed2072a6360ee46bfac4645d195f1427b642fc40806b0b7fd8ad3cd9d07b028;

    address public immutable module;
    address public immutable weth;
    address public immutable operatingTreasury;
    address public immutable buybackVault;
    IDegenV1FeeLocker public immutable feeLocker;

    mapping(PoolId poolId => PoolConfig config) private _poolConfigs;
    mapping(address token => PoolId poolId) private _poolIdsByToken;
    mapping(PoolId poolId => uint256 amount) public totalWethFeesAccrued;
    mapping(PoolId poolId => uint256 amount) public pendingTreasuryWeth;
    mapping(PoolId poolId => uint256 amount) public pendingBuybackWeth;
    mapping(PoolId poolId => mapping(address beneficiary => uint256 amount)) public
        pendingBeneficiaryWeth;
    mapping(PoolId poolId => uint256 amount) public pendingTotalWeth;

    bool private _unlocking;
    uint256 private _unlockAmount;

    modifier onlyModule() {
        if (msg.sender != module) revert OnlyModule();
        _;
    }

    constructor(
        IPoolManager manager,
        address module_,
        address weth_,
        address operatingTreasury_,
        address buybackVault_,
        address feeLocker_
    ) BaseHook(manager) {
        if (
            address(manager) == address(0) || module_ == address(0) || weth_ == address(0)
                || operatingTreasury_ == address(0) || buybackVault_ == address(0)
        ) {
            revert InvalidAddress();
        }
        if (
            feeLocker_.code.length == 0 || IDegenV1FeeLocker(feeLocker_).WETH() != weth_
                || IDegenV1FeeLocker(feeLocker_).HOOK() != address(this)
        ) {
            revert InvalidFeeLocker();
        }
        if (buybackVault_.code.length == 0) revert InvalidBuybackVault();
        IDegenBuybackVault vault = IDegenBuybackVault(buybackVault_);
        if (
            address(vault.poolManager()) != address(manager) || vault.weth() != weth_
                || vault.degen() == address(0) || PoolId.unwrap(vault.poolId()) == bytes32(0)
                || vault.burnSink() != 0x000000000000000000000000000000000000dEaD
                || (block.chainid == ROBINHOOD_CHAIN_ID
                    && (vault.degen() != LIVE_DEGEN
                        || PoolId.unwrap(vault.poolId()) != LIVE_DEGEN_POOL_ID))
        ) {
            revert InvalidBuybackVault();
        }

        module = module_;
        weth = weth_;
        operatingTreasury = operatingTreasury_;
        buybackVault = buybackVault_;
        feeLocker = IDegenV1FeeLocker(feeLocker_);
    }

    function registerPool(address token, address beneficiary, address beneficiaryController)
        external
        onlyModule
        returns (PoolKey memory key)
    {
        if (token == address(0) || token == weth) revert InvalidToken();
        if (beneficiary == address(0)) revert InvalidBeneficiary();
        if (beneficiaryController == address(0) || beneficiaryController != feeLocker.LP_LOCKER()) {
            revert InvalidBeneficiaryController();
        }
        if (token > weth) revert InvalidTokenOrder();

        key = PoolKey({
            currency0: Currency.wrap(token),
            currency1: Currency.wrap(weth),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(this))
        });
        PoolId poolId = key.toId();
        if (_poolConfigs[poolId].registered) revert PoolAlreadyRegistered();

        _poolConfigs[poolId] = PoolConfig({
            token: token,
            beneficiary: beneficiary,
            beneficiaryController: beneficiaryController,
            registered: true,
            initialized: false,
            initializedAt: 0
        });
        _poolIdsByToken[token] = poolId;
        emit PoolRegistered(poolId, token, weth, beneficiaryController);
    }

    function updateBeneficiary(address token, address newBeneficiary) external {
        if (newBeneficiary == address(0)) revert InvalidBeneficiary();
        PoolId poolId = _poolIdsByToken[token];
        PoolConfig storage config = _poolConfigs[poolId];
        if (!config.registered) revert PoolNotRegistered();
        if (msg.sender != config.beneficiaryController) revert OnlyBeneficiaryController();

        address previousBeneficiary = config.beneficiary;
        config.beneficiary = newBeneficiary;
        emit BeneficiaryUpdated(poolId, token, previousBeneficiary, newBeneficiary);
    }

    function getPoolConfig(PoolId poolId) external view returns (PoolConfig memory) {
        return _poolConfigs[poolId];
    }

    function poolIdForToken(address token) external view returns (PoolId) {
        return _poolIdsByToken[token];
    }

    function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        internal
        view
        override
        returns (bytes4)
    {
        PoolConfig storage config = _poolConfigs[key.toId()];
        if (!config.registered) revert PoolNotRegistered();
        if (sender != module) revert OnlyModule();
        if (config.initialized) revert PoolAlreadyInitialized();
        if (sqrtPriceX96 != TickMath.getSqrtPriceAtTick(INITIAL_TICK)) {
            revert InvalidInitialPrice();
        }
        return BaseHook.beforeInitialize.selector;
    }

    function _afterInitialize(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24 tick
    ) internal override returns (bytes4) {
        PoolId poolId = key.toId();
        PoolConfig storage config = _poolConfigs[poolId];
        if (!config.registered) revert PoolNotRegistered();
        if (sender != module) revert OnlyModule();
        if (config.initialized) revert PoolAlreadyInitialized();
        if (sqrtPriceX96 != TickMath.getSqrtPriceAtTick(INITIAL_TICK) || tick != INITIAL_TICK) {
            revert InvalidInitialPrice();
        }

        poolManager.updateDynamicLPFee(key, LP_FEE);
        config.initialized = true;
        config.initializedAt = uint64(block.timestamp);
        emit PoolInitialized(poolId, config.initializedAt, LP_FEE);
        return BaseHook.afterInitialize.selector;
    }

    function _beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        _requireInitialized(poolId);
        poolManager.updateDynamicLPFee(key, LP_FEE);
        uint256 totalRate = _totalHookRate(poolId);

        bool exactInput = params.amountSpecified < 0;
        DegenFeeMath.FeeSplit memory split;
        uint256 grossWethBasis;
        if (exactInput && !params.zeroForOne) {
            grossWethBasis = _absolute(params.amountSpecified);
            split = DegenFeeMath.splitHookFee(grossWethBasis, totalRate);
        } else if (!exactInput && params.zeroForOne) {
            uint256 netWeth = uint256(params.amountSpecified);
            grossWethBasis = DegenFeeMath.grossFromNet(netWeth, totalRate);
            split = DegenFeeMath.splitRealizedHookFee(
                grossWethBasis, totalRate, grossWethBasis - netWeth
            );
        }

        if (split.totalHookFee == 0) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        _accrueWethFee(poolId, key, grossWethBasis, totalRate, split);
        return
            (BaseHook.beforeSwap.selector, toBeforeSwapDelta(_toInt128(split.totalHookFee), 0), 0);
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        _requireInitialized(poolId);
        uint256 totalRate = _totalHookRate(poolId);

        bool exactInput = params.amountSpecified < 0;
        int128 wethDelta = delta.amount1();
        DegenFeeMath.FeeSplit memory split;
        uint256 grossWethBasis;
        if (exactInput && params.zeroForOne && wethDelta > 0) {
            grossWethBasis = uint128(wethDelta);
            split = DegenFeeMath.splitHookFee(grossWethBasis, totalRate);
        } else if (!exactInput && !params.zeroForOne && wethDelta < 0) {
            uint256 poolWeth = _absolute(int256(wethDelta));
            grossWethBasis = DegenFeeMath.grossFromNet(poolWeth, totalRate);
            split = DegenFeeMath.splitRealizedHookFee(
                grossWethBasis, totalRate, grossWethBasis - poolWeth
            );
        }

        if (split.totalHookFee == 0) return (BaseHook.afterSwap.selector, 0);
        _accrueWethFee(poolId, key, grossWethBasis, totalRate, split);
        return (BaseHook.afterSwap.selector, _toInt128(split.totalHookFee));
    }

    function _accrueWethFee(
        PoolId poolId,
        PoolKey calldata key,
        uint256 grossWethBasis,
        uint256 totalRate,
        DegenFeeMath.FeeSplit memory split
    ) private {
        PoolConfig storage config = _poolConfigs[poolId];
        uint256 cumulativeAmount = totalWethFeesAccrued[poolId] + split.totalHookFee;
        totalWethFeesAccrued[poolId] = cumulativeAmount;
        pendingTreasuryWeth[poolId] += split.treasuryCredit;
        pendingBuybackWeth[poolId] += split.buybackCredit;
        pendingBeneficiaryWeth[poolId][config.beneficiary] += split.beneficiaryTemporary;
        pendingTotalWeth[poolId] += split.totalHookFee;

        emit WethHookFeeAccrued(
            poolId,
            config.beneficiary,
            grossWethBasis,
            totalRate,
            split.totalHookFee,
            split.permanentFee,
            split.temporaryFee,
            split.beneficiaryTemporary,
            split.treasuryCredit,
            split.buybackCredit,
            split.roundingDust,
            cumulativeAmount
        );
        poolManager.mint(address(this), key.currency1.toId(), split.totalHookFee);
    }

    function flushPoolFees(PoolId poolId, address beneficiary)
        external
        nonReentrant
        returns (uint256 treasuryPaid, uint256 buybackPaid, uint256 beneficiaryStored)
    {
        if (!_poolConfigs[poolId].registered) {
            revert PoolNotRegistered();
        }

        treasuryPaid = pendingTreasuryWeth[poolId];
        buybackPaid = pendingBuybackWeth[poolId];
        beneficiaryStored = pendingBeneficiaryWeth[poolId][beneficiary];
        uint256 amount = treasuryPaid + buybackPaid + beneficiaryStored;
        if (amount == 0) return (0, 0, 0);

        pendingTreasuryWeth[poolId] = 0;
        pendingBuybackWeth[poolId] = 0;
        pendingBeneficiaryWeth[poolId][beneficiary] = 0;
        pendingTotalWeth[poolId] -= amount;

        _unlocking = true;
        _unlockAmount = amount;
        poolManager.unlock(abi.encode(amount));
        _unlocking = false;
        _unlockAmount = 0;

        IERC20 wethToken = IERC20(weth);
        if (treasuryPaid != 0) wethToken.safeTransfer(operatingTreasury, treasuryPaid);
        if (buybackPaid != 0) wethToken.safeTransfer(buybackVault, buybackPaid);
        if (beneficiaryStored != 0) {
            wethToken.forceApprove(address(feeLocker), beneficiaryStored);
            uint256 received = feeLocker.storeFees(beneficiary, beneficiaryStored);
            wethToken.forceApprove(address(feeLocker), 0);
            if (received != beneficiaryStored) {
                revert UnexpectedLockerReceipt(beneficiaryStored, received);
            }
        }

        emit PoolFeesFlushed(
            poolId, beneficiary, msg.sender, treasuryPaid, buybackPaid, beneficiaryStored
        );
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || !_unlocking) revert UnauthorizedUnlock();
        uint256 amount = abi.decode(data, (uint256));
        if (amount != _unlockAmount) revert UnauthorizedUnlock();

        Currency wethCurrency = Currency.wrap(weth);
        poolManager.burn(address(this), wethCurrency.toId(), amount);
        poolManager.take(wethCurrency, address(this), amount);
        return bytes("");
    }

    function _absolute(int256 negativeAmount) private pure returns (uint256) {
        unchecked {
            return uint256(-(negativeAmount + 1)) + 1;
        }
    }

    function _toInt128(uint256 amount) private pure returns (int128) {
        if (amount > uint256(uint128(type(int128).max))) revert FeeAmountOverflow(amount);
        return int128(int256(amount));
    }

    function _totalHookRate(PoolId poolId) private view returns (uint256) {
        return DegenFeeMath.totalHookRate(_poolConfigs[poolId].initializedAt, block.timestamp);
    }

    function _requireInitialized(PoolId poolId) private view {
        PoolConfig storage config = _poolConfigs[poolId];
        if (!config.registered) revert PoolNotRegistered();
        if (!config.initialized) revert PoolNotInitialized();
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
