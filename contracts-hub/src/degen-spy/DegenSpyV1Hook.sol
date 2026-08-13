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

import {IDegenSpyBuybackVault} from "../interfaces/IDegenSpyBuybackVault.sol";
import {IDegenSpyV1FeeLocker} from "../interfaces/IDegenSpyV1FeeLocker.sol";
import {IDegenSpyV1Hook} from "../interfaces/IDegenSpyV1Hook.sol";
import {DegenFeeMath} from "../libraries/DegenFeeMath.sol";
import {DegenSpyV1LaunchConstants} from "../libraries/DegenSpyV1LaunchConstants.sol";

/// @title SPY V4.1 Uniswap v4 hook
/// @notice Applies immutable launch and permanent fees to canonical token/SPY pools.
/// @dev Fee settlement is permissionless but every destination is constructor-bound. An
/// exact-input SPY buy charges the hook fee against requested input. If a caller supplies a tight
/// sqrtPriceLimitX96 and the swap partially fills, the fee can therefore exceed the fee on realized
/// SPY input. Integrators must disclose and quote this behavior rather than assuming realized-input
/// fee accounting for that quadrant.
contract DegenSpyV1Hook is BaseHook, IDegenSpyV1Hook, IUnlockCallback, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    uint24 public constant LP_FEE = uint24(DegenSpyV1LaunchConstants.LP_FEE_RATE);
    int24 public constant TICK_SPACING = DegenSpyV1LaunchConstants.TICK_SPACING;
    int24 public constant INITIAL_TICK = DegenSpyV1LaunchConstants.INITIAL_TICK;
    uint256 private constant ROBINHOOD_CHAIN_ID = 4663;
    address private constant LIVE_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address private constant LIVE_V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address private constant LIVE_DEGEN = 0x04d5D8a61DA0b6548B136412843aDBA55EbeaDE6;
    address private constant LIVE_SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;

    address public immutable module;
    address public immutable spy;
    address public immutable operatingTreasury;
    address public immutable buybackVault;
    IDegenSpyV1FeeLocker public immutable feeLocker;

    mapping(PoolId poolId => PoolConfig config) private _poolConfigs;
    mapping(address token => PoolId poolId) private _poolIdsByToken;
    mapping(PoolId poolId => uint256 amount) public totalRawSpyFeesAccrued;
    mapping(PoolId poolId => uint256 amount) public pendingTreasuryRawSpy;
    mapping(PoolId poolId => uint256 amount) public pendingBuybackRawSpy;
    mapping(PoolId poolId => mapping(address beneficiary => uint256 amount)) public
        pendingBeneficiaryRawSpy;
    mapping(PoolId poolId => uint256 amount) public pendingTotalRawSpy;

    bool private _unlocking;
    uint256 private _unlockAmount;

    modifier onlyModule() {
        if (msg.sender != module) revert OnlyModule();
        _;
    }

    constructor(
        IPoolManager manager,
        address module_,
        address spy_,
        address operatingTreasury_,
        address buybackVault_,
        address feeLocker_
    ) BaseHook(manager) {
        if (
            address(manager) == address(0) || module_ == address(0) || spy_ == address(0)
                || spy_.code.length == 0 || operatingTreasury_ == address(0)
                || buybackVault_ == address(0)
        ) {
            revert InvalidAddress();
        }
        if (
            feeLocker_.code.length == 0 || IDegenSpyV1FeeLocker(feeLocker_).SPY() != spy_
                || IDegenSpyV1FeeLocker(feeLocker_).HOOK() != address(this)
        ) {
            revert InvalidFeeLocker();
        }
        if (buybackVault_.code.length == 0) revert InvalidBuybackVault();
        IDegenSpyBuybackVault vault = IDegenSpyBuybackVault(buybackVault_);
        address vaultFactory = address(vault.v3Factory());
        if (
            vaultFactory == address(0) || vaultFactory.code.length == 0 || vault.spy() != spy_
                || vault.degen() == address(0) || vault.poolFee() != 10_000
                || vault.tickSpacing() != 200
                || vault.burnSink() != 0x000000000000000000000000000000000000dEaD
                || (block.chainid == ROBINHOOD_CHAIN_ID
                    && (address(manager) != LIVE_POOL_MANAGER
                        || spy_ != LIVE_SPY
                        || vaultFactory != LIVE_V3_FACTORY
                        || vault.degen() != LIVE_DEGEN))
        ) {
            revert InvalidBuybackVault();
        }

        module = module_;
        spy = spy_;
        operatingTreasury = operatingTreasury_;
        buybackVault = buybackVault_;
        feeLocker = IDegenSpyV1FeeLocker(feeLocker_);
    }

    function registerPool(address token, address beneficiary, address beneficiaryController)
        external
        onlyModule
        returns (PoolKey memory key)
    {
        if (token == address(0) || token == spy) revert InvalidToken();
        if (beneficiary == address(0)) revert InvalidBeneficiary();
        if (beneficiaryController == address(0) || beneficiaryController != feeLocker.LP_LOCKER()) {
            revert InvalidBeneficiaryController();
        }
        if (token > spy) revert InvalidTokenOrder();

        key = PoolKey({
            currency0: Currency.wrap(token),
            currency1: Currency.wrap(spy),
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
        emit PoolRegistered(poolId, token, spy, beneficiaryController);
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
        uint256 grossRawSpyBasis;
        if (exactInput && !params.zeroForOne) {
            grossRawSpyBasis = _absolute(params.amountSpecified);
            split = DegenFeeMath.splitHookFee(grossRawSpyBasis, totalRate);
        } else if (!exactInput && params.zeroForOne) {
            uint256 netRawSpy = uint256(params.amountSpecified);
            grossRawSpyBasis = DegenFeeMath.grossFromNet(netRawSpy, totalRate);
            split = DegenFeeMath.splitRealizedHookFee(
                grossRawSpyBasis, totalRate, grossRawSpyBasis - netRawSpy
            );
        }

        if (split.totalHookFee == 0) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        _accrueRawSpyFee(poolId, key, grossRawSpyBasis, totalRate, split);
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
        int128 spyDelta = delta.amount1();
        DegenFeeMath.FeeSplit memory split;
        uint256 grossRawSpyBasis;
        if (exactInput && params.zeroForOne && spyDelta > 0) {
            grossRawSpyBasis = uint128(spyDelta);
            split = DegenFeeMath.splitHookFee(grossRawSpyBasis, totalRate);
        } else if (!exactInput && !params.zeroForOne && spyDelta < 0) {
            uint256 poolRawSpy = _absolute(int256(spyDelta));
            grossRawSpyBasis = DegenFeeMath.grossFromNet(poolRawSpy, totalRate);
            split = DegenFeeMath.splitRealizedHookFee(
                grossRawSpyBasis, totalRate, grossRawSpyBasis - poolRawSpy
            );
        }

        if (split.totalHookFee == 0) return (BaseHook.afterSwap.selector, 0);
        _accrueRawSpyFee(poolId, key, grossRawSpyBasis, totalRate, split);
        return (BaseHook.afterSwap.selector, _toInt128(split.totalHookFee));
    }

    function _accrueRawSpyFee(
        PoolId poolId,
        PoolKey calldata key,
        uint256 grossRawSpyBasis,
        uint256 totalRate,
        DegenFeeMath.FeeSplit memory split
    ) private {
        PoolConfig storage config = _poolConfigs[poolId];
        uint256 cumulativeAmount = totalRawSpyFeesAccrued[poolId] + split.totalHookFee;
        totalRawSpyFeesAccrued[poolId] = cumulativeAmount;
        pendingTreasuryRawSpy[poolId] += split.treasuryCredit;
        pendingBuybackRawSpy[poolId] += split.buybackCredit;
        pendingBeneficiaryRawSpy[poolId][config.beneficiary] += split.beneficiaryTemporary;
        pendingTotalRawSpy[poolId] += split.totalHookFee;

        emit RawSpyHookFeeAccrued(
            poolId,
            config.beneficiary,
            grossRawSpyBasis,
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

        treasuryPaid = pendingTreasuryRawSpy[poolId];
        buybackPaid = pendingBuybackRawSpy[poolId];
        beneficiaryStored = pendingBeneficiaryRawSpy[poolId][beneficiary];
        uint256 amount = treasuryPaid + buybackPaid + beneficiaryStored;
        if (amount == 0) return (0, 0, 0);

        pendingTreasuryRawSpy[poolId] = 0;
        pendingBuybackRawSpy[poolId] = 0;
        pendingBeneficiaryRawSpy[poolId][beneficiary] = 0;
        pendingTotalRawSpy[poolId] -= amount;

        _unlocking = true;
        _unlockAmount = amount;
        poolManager.unlock(abi.encode(amount));
        _unlocking = false;
        _unlockAmount = 0;

        IERC20 spyToken = IERC20(spy);
        if (treasuryPaid != 0) spyToken.safeTransfer(operatingTreasury, treasuryPaid);
        if (buybackPaid != 0) spyToken.safeTransfer(buybackVault, buybackPaid);
        if (beneficiaryStored != 0) {
            spyToken.forceApprove(address(feeLocker), beneficiaryStored);
            uint256 received = feeLocker.storeFees(beneficiary, beneficiaryStored);
            spyToken.forceApprove(address(feeLocker), 0);
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

        Currency spyCurrency = Currency.wrap(spy);
        poolManager.burn(address(this), spyCurrency.toId(), amount);
        poolManager.take(spyCurrency, address(this), amount);
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
