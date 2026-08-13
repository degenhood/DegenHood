// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IDegenHoodFeeLocker} from "./interfaces/IDegenHoodFeeLocker.sol";
import {IDegenHoodV4Hook} from "./interfaces/IDegenHoodV4Hook.sol";
import {DegenFeeMath} from "./libraries/DegenFeeMath.sol";
import {DegenLaunchConstants} from "./libraries/DegenLaunchConstants.sol";

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

/// @title DegenHood v4 hook
/// @notice Registers canonical token/WETH pools and fixes their Uniswap LP fee at 0.7%.
/// @dev The factory registers the exact PoolKey, then initializes that key through PoolManager.
///      All economic changes require a separately deployed, versioned hook and factory.
contract DegenHoodV4Hook is BaseHook, IDegenHoodV4Hook, IUnlockCallback, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    uint24 public constant LP_FEE = uint24(DegenLaunchConstants.LP_FEE_RATE);
    int24 public constant TICK_SPACING = 200;
    int24 public constant INITIAL_TICK = -230_400;

    address public immutable factory;
    address public immutable weth;
    address public immutable operatingTreasury;
    IDegenHoodFeeLocker public immutable feeLocker;

    mapping(PoolId poolId => PoolConfig config) private _poolConfigs;
    mapping(address token => PoolId poolId) private _poolIdsByToken;
    mapping(PoolId poolId => uint256 amount) public totalWethFeesAccrued;
    mapping(PoolId poolId => uint256 amount) public pendingProtocolWeth;
    mapping(PoolId poolId => mapping(address beneficiary => uint256 amount)) public
        pendingBeneficiaryWeth;
    mapping(PoolId poolId => uint256 amount) public pendingTotalWeth;

    bool private _unlocking;
    uint256 private _unlockAmount;

    modifier onlyFactory() {
        if (msg.sender != factory) revert OnlyFactory();
        _;
    }

    constructor(
        IPoolManager manager,
        address factory_,
        address weth_,
        address operatingTreasury_,
        address feeLocker_
    ) BaseHook(manager) {
        if (
            address(manager) == address(0) || factory_ == address(0) || weth_ == address(0)
                || operatingTreasury_ == address(0)
        ) {
            revert InvalidAddress();
        }
        if (feeLocker_.code.length == 0 || IDegenHoodFeeLocker(feeLocker_).WETH() != weth_) {
            revert InvalidFeeLocker();
        }
        factory = factory_;
        weth = weth_;
        operatingTreasury = operatingTreasury_;
        feeLocker = IDegenHoodFeeLocker(feeLocker_);
    }

    /// @inheritdoc IDegenHoodV4Hook
    function registerPool(address token, address beneficiary)
        external
        onlyFactory
        returns (PoolKey memory key)
    {
        return _registerPool(token, beneficiary, factory);
    }

    function registerPool(address token, address beneficiary, address beneficiaryController)
        external
        onlyFactory
        returns (PoolKey memory key)
    {
        return _registerPool(token, beneficiary, beneficiaryController);
    }

    function _registerPool(address token, address beneficiary, address beneficiaryController)
        private
        returns (PoolKey memory key)
    {
        if (token == address(0) || token == weth) revert InvalidToken();
        if (beneficiary == address(0)) revert InvalidBeneficiary();
        if (beneficiaryController == address(0)) revert InvalidBeneficiaryController();
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

    /// @inheritdoc IDegenHoodV4Hook
    function getPoolConfig(PoolId poolId) external view returns (PoolConfig memory) {
        return _poolConfigs[poolId];
    }

    /// @inheritdoc IDegenHoodV4Hook
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
        if (sender != factory) revert OnlyFactory();
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
        if (sender != factory) revert OnlyFactory();
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
        pendingProtocolWeth[poolId] += split.protocolCredit;
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
            split.protocolCredit,
            split.roundingDust,
            cumulativeAmount
        );
        poolManager.mint(address(this), key.currency1.toId(), split.totalHookFee);
    }

    function flushPoolFees(PoolId poolId, address beneficiary)
        external
        nonReentrant
        returns (uint256 protocolPaid, uint256 beneficiaryStored)
    {
        if (!_poolConfigs[poolId].registered) revert PoolNotRegistered();

        protocolPaid = pendingProtocolWeth[poolId];
        beneficiaryStored = pendingBeneficiaryWeth[poolId][beneficiary];
        uint256 amount = protocolPaid + beneficiaryStored;
        if (amount == 0) return (0, 0);

        pendingProtocolWeth[poolId] = 0;
        pendingBeneficiaryWeth[poolId][beneficiary] = 0;
        pendingTotalWeth[poolId] -= amount;

        _unlocking = true;
        _unlockAmount = amount;
        poolManager.unlock(abi.encode(amount));
        _unlocking = false;
        _unlockAmount = 0;

        IERC20 wethToken = IERC20(weth);
        if (protocolPaid != 0) wethToken.safeTransfer(operatingTreasury, protocolPaid);
        if (beneficiaryStored != 0) {
            wethToken.forceApprove(address(feeLocker), beneficiaryStored);
            uint256 received = feeLocker.storeFees(beneficiary, beneficiaryStored);
            wethToken.forceApprove(address(feeLocker), 0);
            if (received != beneficiaryStored) {
                revert UnexpectedLockerReceipt(beneficiaryStored, received);
            }
        }

        emit PoolFeesFlushed(poolId, beneficiary, msg.sender, protocolPaid, beneficiaryStored);
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
