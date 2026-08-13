// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IDegenHoodFeeLocker} from "./interfaces/IDegenHoodFeeLocker.sol";
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

/// @title DegenHood v4 hook, version 2
/// @notice Separates globally sweepable protocol WETH from per-pool creator WETH accounting.
/// @dev V1 remains immutable. New launches opt into this hook through a versioned factory template.
contract DegenHoodV4HookV2 is BaseHook, IUnlockCallback, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    struct PoolConfig {
        address token;
        address beneficiary;
        address beneficiaryController;
        bool registered;
        bool initialized;
        uint64 initializedAt;
    }

    error FeeAmountOverflow(uint256 amount);
    error InvalidAddress();
    error InvalidBeneficiary();
    error InvalidBeneficiaryController();
    error InvalidFeeLocker();
    error InvalidInitialPrice();
    error InvalidToken();
    error InvalidTokenOrder();
    error OnlyFactory();
    error OnlyBeneficiaryController();
    error OnlySelf();
    error ProtocolSweepAmountMismatch(uint256 expected, uint256 actual);
    error PoolAlreadyInitialized();
    error PoolAlreadyRegistered();
    error PoolNotInitialized();
    error PoolNotRegistered();
    error UnauthorizedUnlock();
    error UnexpectedLockerReceipt(uint256 expected, uint256 received);

    event PoolRegistered(
        PoolId indexed poolId,
        address indexed token,
        address indexed weth,
        address beneficiaryController
    );
    event PoolInitialized(PoolId indexed poolId, uint64 initializedAt, uint24 lpFee);
    event BeneficiaryUpdated(
        PoolId indexed poolId,
        address indexed token,
        address indexed previousBeneficiary,
        address newBeneficiary
    );
    event WethHookFeeAccrued(
        PoolId indexed poolId,
        address indexed beneficiary,
        uint256 grossWethBasis,
        uint256 totalRate,
        uint256 totalFee,
        uint256 permanentFee,
        uint256 temporaryFee,
        uint256 beneficiaryCredit,
        uint256 protocolCredit,
        uint256 roundingDust,
        uint256 cumulativeAmount
    );
    event ProtocolWethSwept(
        PoolId indexed triggeringPoolId,
        address indexed caller,
        uint256 amount,
        uint256 cumulativeSwept,
        bool automatic
    );
    event ProtocolWethSweepFailed(
        PoolId indexed triggeringPoolId, uint256 attemptedAmount, bytes reason
    );
    event BeneficiaryWethFlushed(
        PoolId indexed poolId,
        address indexed beneficiary,
        address indexed caller,
        uint256 beneficiaryStored
    );
    event PoolFeesFlushed(
        PoolId indexed poolId,
        address indexed beneficiary,
        address indexed caller,
        uint256 protocolPaid,
        uint256 beneficiaryStored
    );

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
    mapping(PoolId poolId => uint256 amount) public totalProtocolWethAccrued;
    uint256 public pendingProtocolWeth;
    uint256 public totalProtocolWethSwept;
    mapping(PoolId poolId => mapping(address beneficiary => uint256 amount)) public
        pendingBeneficiaryWeth;
    mapping(PoolId poolId => uint256 amount) public pendingBeneficiaryTotalWeth;

    bool private _unlocking;
    uint256 private _unlockAmount;
    address private _unlockRecipient;

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
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        _requireInitialized(poolId);
        _attemptProtocolWethSweep(poolId, sender);
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
        totalProtocolWethAccrued[poolId] += split.protocolCredit;
        pendingProtocolWeth += split.protocolCredit;
        pendingBeneficiaryWeth[poolId][config.beneficiary] += split.beneficiaryTemporary;
        pendingBeneficiaryTotalWeth[poolId] += split.beneficiaryTemporary;
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

    /// @notice Redeems protocol-owned WETH claims while PoolManager is already unlocked.
    /// @dev Only the hook itself may enter this catchable boundary from `_beforeSwap`.
    function sweepProtocolWethDuringSwap(uint256 amount) external {
        if (msg.sender != address(this)) revert OnlySelf();
        uint256 expected = pendingProtocolWeth;
        if (amount != expected) revert ProtocolSweepAmountMismatch(expected, amount);
        pendingProtocolWeth = 0;
        totalProtocolWethSwept += amount;
        Currency wethCurrency = Currency.wrap(weth);
        poolManager.burn(address(this), wethCurrency.toId(), amount);
        poolManager.take(wethCurrency, operatingTreasury, amount);
    }

    function _attemptProtocolWethSweep(PoolId triggeringPoolId, address caller) private {
        uint256 amount = pendingProtocolWeth;
        if (amount == 0) return;

        try this.sweepProtocolWethDuringSwap(amount) {
            emit ProtocolWethSwept(triggeringPoolId, caller, amount, totalProtocolWethSwept, true);
        } catch (bytes memory reason) {
            emit ProtocolWethSweepFailed(triggeringPoolId, amount, reason);
        }
    }

    /// @notice Permissionlessly delivers all currently pending protocol WETH to treasury.
    /// @dev This is the quiet-period fallback; active pools normally sweep on their next swap.
    function flushProtocolFees() external nonReentrant returns (uint256 protocolPaid) {
        protocolPaid = pendingProtocolWeth;
        if (protocolPaid == 0) return 0;

        pendingProtocolWeth = 0;
        totalProtocolWethSwept += protocolPaid;
        _redeemWethClaims(protocolPaid, operatingTreasury);

        emit ProtocolWethSwept(
            PoolId.wrap(bytes32(0)), msg.sender, protocolPaid, totalProtocolWethSwept, false
        );
    }

    /// @notice Permissionlessly checkpoints one creator's already-attributed WETH into FeeLocker.
    /// @dev V2 deliberately leaves the global protocol bucket untouched.
    function flushPoolFees(PoolId poolId, address beneficiary)
        external
        nonReentrant
        returns (uint256 protocolPaid, uint256 beneficiaryStored)
    {
        if (!_poolConfigs[poolId].registered) revert PoolNotRegistered();

        beneficiaryStored = pendingBeneficiaryWeth[poolId][beneficiary];
        if (beneficiaryStored == 0) return (0, 0);

        pendingBeneficiaryWeth[poolId][beneficiary] = 0;
        pendingBeneficiaryTotalWeth[poolId] -= beneficiaryStored;
        _redeemWethClaims(beneficiaryStored, address(this));

        IERC20 wethToken = IERC20(weth);
        wethToken.forceApprove(address(feeLocker), beneficiaryStored);
        uint256 received = feeLocker.storeFees(beneficiary, beneficiaryStored);
        wethToken.forceApprove(address(feeLocker), 0);
        if (received != beneficiaryStored) {
            revert UnexpectedLockerReceipt(beneficiaryStored, received);
        }

        emit BeneficiaryWethFlushed(poolId, beneficiary, msg.sender, beneficiaryStored);
        emit PoolFeesFlushed(poolId, beneficiary, msg.sender, 0, beneficiaryStored);
    }

    function _redeemWethClaims(uint256 amount, address recipient) private {
        _unlocking = true;
        _unlockAmount = amount;
        _unlockRecipient = recipient;
        poolManager.unlock(abi.encode(amount, recipient));
        _unlocking = false;
        _unlockAmount = 0;
        _unlockRecipient = address(0);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || !_unlocking) revert UnauthorizedUnlock();
        (uint256 amount, address recipient) = abi.decode(data, (uint256, address));
        if (amount != _unlockAmount || recipient != _unlockRecipient) revert UnauthorizedUnlock();

        Currency wethCurrency = Currency.wrap(weth);
        poolManager.burn(address(this), wethCurrency.toId(), amount);
        poolManager.take(wethCurrency, recipient, amount);
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
