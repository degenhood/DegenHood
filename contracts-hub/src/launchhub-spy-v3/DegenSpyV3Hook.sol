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
import {IDegenSpyV3Hook} from "../interfaces/IDegenSpyV3Hook.sol";
import {DegenFeeMath} from "../libraries/DegenFeeMath.sol";
import {DegenSpyV3LaunchConstants} from "../libraries/DegenSpyV3LaunchConstants.sol";

/// @title SPY V4 V3 hook
/// @notice Uses raw SPY units and isolates global protocol buckets from creator accounting.
contract DegenSpyV3Hook is BaseHook, IDegenSpyV3Hook, IUnlockCallback, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    uint24 public constant LP_FEE = uint24(DegenSpyV3LaunchConstants.LP_FEE_RATE);
    int24 public constant TICK_SPACING = DegenSpyV3LaunchConstants.TICK_SPACING;
    int24 public constant INITIAL_TICK = DegenSpyV3LaunchConstants.INITIAL_TICK;
    uint256 private constant ROBINHOOD_CHAIN_ID = 4663;
    address private constant LIVE_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address private constant LIVE_V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address private constant LIVE_DEGEN = 0x04d5D8a61DA0b6548B136412843aDBA55EbeaDE6;
    address private constant LIVE_SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address private constant LIVE_OPERATING_TREASURY = 0x53F8a103F2C9451Bfb7157cCAE4461FbA39D39a0;
    address private constant LIVE_SPY_BUYBACK_VAULT = 0x910313C5303FeCf33A2DBB1d945AAD9C26a3a952;

    address public immutable module;
    address public immutable spy;
    address public immutable operatingTreasury;
    address public immutable buybackVault;
    IDegenSpyV1FeeLocker public immutable feeLocker;
    address public immutable beneficiaryController;

    /// @notice Two-slot internal pool record; the public getter reconstructs the stable tuple.
    /// @dev Slot N: bits 0..159 token | 160..199 initializedAt | 200..207 status |
    ///      208..255 unused. Slot N+1: bits 0..159 beneficiary | 160..255 unused.
    struct PackedPoolConfig {
        address token;
        uint40 initializedAt;
        uint8 status;
        address beneficiary;
    }

    mapping(PoolId => PackedPoolConfig) private _poolConfigs;
    mapping(address => PoolId) private _poolIdsByToken;
    mapping(PoolId => uint256) public totalRawSpyFeesAccrued;
    mapping(PoolId => uint256) public totalTreasuryRawSpyAccrued;
    mapping(PoolId => uint256) public totalBuybackRawSpyAccrued;
    uint256 public pendingTreasuryRawSpy;
    uint256 public pendingBuybackRawSpy;
    uint256 public totalTreasuryRawSpySwept;
    uint256 public totalBuybackRawSpySwept;
    mapping(PoolId => mapping(address => uint256)) public pendingBeneficiaryRawSpy;
    mapping(PoolId => uint256) public pendingBeneficiaryTotalRawSpy;

    bool private _unlocking;
    uint256 private _unlockTreasury;
    uint256 private _unlockBuyback;
    uint256 private _unlockCreator;

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
        ) revert InvalidAddress();
        if (
            feeLocker_.code.length == 0 || IDegenSpyV1FeeLocker(feeLocker_).SPY() != spy_
                || IDegenSpyV1FeeLocker(feeLocker_).HOOK() != address(this)
        ) revert InvalidFeeLocker();
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
                        || operatingTreasury_ != LIVE_OPERATING_TREASURY
                        || buybackVault_ != LIVE_SPY_BUYBACK_VAULT
                        || vaultFactory != LIVE_V3_FACTORY
                        || vault.degen() != LIVE_DEGEN))
        ) revert InvalidBuybackVault();

        module = module_;
        spy = spy_;
        operatingTreasury = operatingTreasury_;
        buybackVault = buybackVault_;
        feeLocker = IDegenSpyV1FeeLocker(feeLocker_);
        beneficiaryController = IDegenSpyV1FeeLocker(feeLocker_).LP_LOCKER();
    }

    function registerPool(address token, address beneficiary, address controller)
        external
        onlyModule
        returns (PoolKey memory key)
    {
        if (token == address(0) || token == spy) revert InvalidToken();
        if (beneficiary == address(0)) revert InvalidBeneficiary();
        if (controller == address(0) || controller != beneficiaryController) {
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
        if (_poolConfigs[poolId].token != address(0)) revert PoolAlreadyRegistered();
        _poolConfigs[poolId] = PackedPoolConfig(token, 0, 0, beneficiary);
        _poolIdsByToken[token] = poolId;
        emit PoolRegistered(poolId, token, spy, controller);
    }

    function updateBeneficiary(address token, address newBeneficiary) external {
        if (newBeneficiary == address(0)) revert InvalidBeneficiary();
        PackedPoolConfig storage config = _poolConfigs[_poolIdsByToken[token]];
        if (config.token == address(0)) revert PoolNotRegistered();
        if (msg.sender != beneficiaryController) revert OnlyBeneficiaryController();
        address previous = config.beneficiary;
        config.beneficiary = newBeneficiary;
        emit BeneficiaryUpdated(_poolIdsByToken[token], token, previous, newBeneficiary);
    }

    function getPoolConfig(PoolId poolId) external view returns (PoolConfig memory) {
        PackedPoolConfig storage config = _poolConfigs[poolId];
        return PoolConfig({
            token: config.token,
            beneficiary: config.beneficiary,
            beneficiaryController: beneficiaryController,
            registered: config.token != address(0),
            initialized: config.initializedAt != 0,
            initializedAt: uint64(config.initializedAt)
        });
    }

    function poolIdForToken(address token) external view returns (PoolId) {
        return _poolIdsByToken[token];
    }

    function _beforeInitialize(address sender, PoolKey calldata key, uint160 price)
        internal
        view
        override
        returns (bytes4)
    {
        PackedPoolConfig storage config = _poolConfigs[key.toId()];
        if (config.token == address(0)) revert PoolNotRegistered();
        if (sender != module) revert OnlyModule();
        if (config.initializedAt != 0) revert PoolAlreadyInitialized();
        if (price != TickMath.getSqrtPriceAtTick(INITIAL_TICK)) revert InvalidInitialPrice();
        return BaseHook.beforeInitialize.selector;
    }

    function _afterInitialize(address sender, PoolKey calldata key, uint160 price, int24 tick)
        internal
        override
        returns (bytes4)
    {
        PoolId poolId = key.toId();
        PackedPoolConfig storage config = _poolConfigs[poolId];
        if (config.token == address(0)) revert PoolNotRegistered();
        if (sender != module) revert OnlyModule();
        if (config.initializedAt != 0) revert PoolAlreadyInitialized();
        if (price != TickMath.getSqrtPriceAtTick(INITIAL_TICK) || tick != INITIAL_TICK) {
            revert InvalidInitialPrice();
        }
        poolManager.updateDynamicLPFee(key, LP_FEE);
        config.initializedAt = uint40(block.timestamp);
        emit PoolInitialized(poolId, uint64(config.initializedAt), LP_FEE);
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
        uint256 rate = _totalHookRate(poolId);
        DegenFeeMath.FeeSplit memory split;
        uint256 gross;
        if (params.amountSpecified < 0 && !params.zeroForOne) {
            gross = _absolute(params.amountSpecified);
            split = DegenFeeMath.splitHookFee(gross, rate);
        } else if (params.amountSpecified >= 0 && params.zeroForOne) {
            uint256 net = uint256(params.amountSpecified);
            gross = DegenFeeMath.grossFromNet(net, rate);
            split = DegenFeeMath.splitRealizedHookFee(gross, rate, gross - net);
        }
        if (split.totalHookFee == 0) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        _accrue(poolId, key, gross, rate, split);
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
        uint256 rate = _totalHookRate(poolId);
        DegenFeeMath.FeeSplit memory split;
        uint256 gross;
        int128 spyDelta = delta.amount1();
        _requireFullQuoteSettlement(params, spyDelta, rate);
        if (params.amountSpecified < 0 && params.zeroForOne && spyDelta > 0) {
            gross = uint128(spyDelta);
            split = DegenFeeMath.splitHookFee(gross, rate);
        } else if (params.amountSpecified >= 0 && !params.zeroForOne && spyDelta < 0) {
            uint256 poolSpy = _absolute(int256(spyDelta));
            gross = DegenFeeMath.grossFromNet(poolSpy, rate);
            split = DegenFeeMath.splitRealizedHookFee(gross, rate, gross - poolSpy);
        }
        if (split.totalHookFee == 0) return (BaseHook.afterSwap.selector, 0);
        _accrue(poolId, key, gross, rate, split);
        return (BaseHook.afterSwap.selector, _toInt128(split.totalHookFee));
    }

    function _requireFullQuoteSettlement(
        IPoolManager.SwapParams calldata params,
        int128 spyDelta,
        uint256 rate
    ) private pure {
        bool exactInput = params.amountSpecified < 0;
        uint256 expectedPoolSpy;
        uint256 realizedPoolSpy;
        if (exactInput && !params.zeroForOne) {
            uint256 grossSpy = _absolute(params.amountSpecified);
            DegenFeeMath.FeeSplit memory split = DegenFeeMath.splitHookFee(grossSpy, rate);
            expectedPoolSpy = grossSpy - split.totalHookFee;
            if (spyDelta < 0) realizedPoolSpy = _absolute(int256(spyDelta));
        } else if (!exactInput && params.zeroForOne) {
            uint256 netSpy = uint256(params.amountSpecified);
            expectedPoolSpy = DegenFeeMath.grossFromNet(netSpy, rate);
            if (spyDelta > 0) realizedPoolSpy = uint128(spyDelta);
        } else {
            return;
        }
        if (realizedPoolSpy != expectedPoolSpy) {
            revert PartialFillUnsupported(expectedPoolSpy, realizedPoolSpy);
        }
    }

    function _accrue(
        PoolId poolId,
        PoolKey calldata key,
        uint256 gross,
        uint256 rate,
        DegenFeeMath.FeeSplit memory split
    ) private {
        PackedPoolConfig storage config = _poolConfigs[poolId];
        uint256 cumulative = totalRawSpyFeesAccrued[poolId] + split.totalHookFee;
        totalRawSpyFeesAccrued[poolId] = cumulative;
        totalTreasuryRawSpyAccrued[poolId] += split.treasuryCredit;
        totalBuybackRawSpyAccrued[poolId] += split.buybackCredit;
        pendingTreasuryRawSpy += split.treasuryCredit;
        pendingBuybackRawSpy += split.buybackCredit;
        pendingBeneficiaryRawSpy[poolId][config.beneficiary] += split.beneficiaryTemporary;
        pendingBeneficiaryTotalRawSpy[poolId] += split.beneficiaryTemporary;
        emit RawSpyHookFeeAccrued(
            poolId,
            config.beneficiary,
            gross,
            rate,
            split.totalHookFee,
            split.permanentFee,
            split.temporaryFee,
            split.beneficiaryTemporary,
            split.treasuryCredit,
            split.buybackCredit,
            split.roundingDust,
            cumulative
        );
        poolManager.mint(address(this), key.currency1.toId(), split.totalHookFee);
    }

    function flushProtocolFees()
        external
        nonReentrant
        returns (uint256 treasuryPaid, uint256 buybackPaid)
    {
        treasuryPaid = pendingTreasuryRawSpy;
        buybackPaid = pendingBuybackRawSpy;
        if (treasuryPaid + buybackPaid == 0) return (0, 0);
        pendingTreasuryRawSpy = 0;
        pendingBuybackRawSpy = 0;
        totalTreasuryRawSpySwept += treasuryPaid;
        totalBuybackRawSpySwept += buybackPaid;
        _redeem(treasuryPaid, buybackPaid, 0);
        emit ProtocolRawSpySwept(
            PoolId.wrap(bytes32(0)),
            msg.sender,
            treasuryPaid,
            buybackPaid,
            totalTreasuryRawSpySwept,
            totalBuybackRawSpySwept,
            false
        );
    }

    function flushPoolFees(PoolId poolId, address beneficiary)
        external
        nonReentrant
        returns (uint256 treasuryPaid, uint256 buybackPaid, uint256 beneficiaryStored)
    {
        if (_poolConfigs[poolId].token == address(0)) {
            revert PoolNotRegistered();
        }
        beneficiaryStored = pendingBeneficiaryRawSpy[poolId][beneficiary];
        if (beneficiaryStored == 0) return (0, 0, 0);
        pendingBeneficiaryRawSpy[poolId][beneficiary] = 0;
        pendingBeneficiaryTotalRawSpy[poolId] -= beneficiaryStored;
        _redeem(0, 0, beneficiaryStored);
        IERC20 quote = IERC20(spy);
        quote.forceApprove(address(feeLocker), beneficiaryStored);
        uint256 received = feeLocker.storeFees(beneficiary, beneficiaryStored);
        quote.forceApprove(address(feeLocker), 0);
        if (received != beneficiaryStored) {
            revert UnexpectedLockerReceipt(beneficiaryStored, received);
        }
        emit PoolFeesFlushed(poolId, beneficiary, msg.sender, 0, 0, beneficiaryStored);
    }

    function _redeem(uint256 treasuryAmount, uint256 buybackAmount, uint256 creatorAmount) private {
        _unlocking = true;
        _unlockTreasury = treasuryAmount;
        _unlockBuyback = buybackAmount;
        _unlockCreator = creatorAmount;
        poolManager.unlock(abi.encode(treasuryAmount, buybackAmount, creatorAmount));
        _unlocking = false;
        _unlockTreasury = 0;
        _unlockBuyback = 0;
        _unlockCreator = 0;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || !_unlocking) revert UnauthorizedUnlock();
        (uint256 treasuryAmount, uint256 buybackAmount, uint256 creatorAmount) =
            abi.decode(data, (uint256, uint256, uint256));
        if (
            treasuryAmount != _unlockTreasury || buybackAmount != _unlockBuyback
                || creatorAmount != _unlockCreator
        ) revert UnauthorizedUnlock();
        Currency quote = Currency.wrap(spy);
        poolManager.burn(
            address(this), quote.toId(), treasuryAmount + buybackAmount + creatorAmount
        );
        if (treasuryAmount != 0) poolManager.take(quote, operatingTreasury, treasuryAmount);
        if (buybackAmount != 0) poolManager.take(quote, buybackVault, buybackAmount);
        if (creatorAmount != 0) poolManager.take(quote, address(this), creatorAmount);
        return bytes("");
    }

    function _absolute(int256 amount) private pure returns (uint256) {
        unchecked {
            return uint256(-(amount + 1)) + 1;
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
        PackedPoolConfig storage config = _poolConfigs[poolId];
        if (config.token == address(0)) revert PoolNotRegistered();
        if (config.initializedAt == 0) revert PoolNotInitialized();
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
