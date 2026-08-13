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
import {IDegenV3Hook} from "../interfaces/IDegenV3Hook.sol";
import {DegenFeeMath} from "../libraries/DegenFeeMath.sol";
import {DegenV3LaunchConstants} from "../libraries/DegenV3LaunchConstants.sol";

/// @title DEGEN_V3 Uniswap v4 hook
/// @notice Separates globally deliverable protocol WETH from per-pool creator WETH.
/// @dev Protocol delivery is permissionless and globally batched independently from user swaps.
contract DegenV3Hook is BaseHook, IDegenV3Hook, IUnlockCallback, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    uint24 public constant LP_FEE = uint24(DegenV3LaunchConstants.LP_FEE_RATE);
    int24 public constant TICK_SPACING = DegenV3LaunchConstants.TICK_SPACING;
    int24 public constant INITIAL_TICK = DegenV3LaunchConstants.INITIAL_TICK;
    uint256 private constant ROBINHOOD_CHAIN_ID = 4663;
    address private constant LIVE_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address private constant LIVE_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address private constant LIVE_DEGEN = 0x04d5D8a61DA0b6548B136412843aDBA55EbeaDE6;
    address private constant LIVE_OPERATING_TREASURY = 0x53F8a103F2C9451Bfb7157cCAE4461FbA39D39a0;
    address private constant LIVE_WETH_BUYBACK_VAULT = 0xdf894EC4B3d9Dbe30F81334cEeE0a8D667a35057;
    bytes32 private constant LIVE_DEGEN_POOL_ID =
        0x6ed2072a6360ee46bfac4645d195f1427b642fc40806b0b7fd8ad3cd9d07b028;

    address public immutable module;
    address public immutable weth;
    address public immutable operatingTreasury;
    address public immutable buybackVault;
    IDegenV1FeeLocker public immutable feeLocker;
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

    mapping(PoolId poolId => PackedPoolConfig config) private _poolConfigs;
    mapping(address token => PoolId poolId) private _poolIdsByToken;
    mapping(PoolId poolId => uint256 amount) public totalWethFeesAccrued;
    mapping(PoolId poolId => uint256 amount) public totalTreasuryWethAccrued;
    mapping(PoolId poolId => uint256 amount) public totalBuybackWethAccrued;
    uint256 public pendingTreasuryWeth;
    uint256 public pendingBuybackWeth;
    uint256 public totalTreasuryWethSwept;
    uint256 public totalBuybackWethSwept;
    mapping(PoolId poolId => mapping(address beneficiary => uint256 amount)) public
        pendingBeneficiaryWeth;
    mapping(PoolId poolId => uint256 amount) public pendingBeneficiaryTotalWeth;

    bool private _unlocking;
    uint256 private _unlockTreasuryAmount;
    uint256 private _unlockBuybackAmount;
    uint256 private _unlockCreatorAmount;

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
                || weth_.code.length == 0 || operatingTreasury_ == address(0)
                || buybackVault_ == address(0)
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
                    && (address(manager) != LIVE_POOL_MANAGER
                        || weth_ != LIVE_WETH
                        || operatingTreasury_ != LIVE_OPERATING_TREASURY
                        || buybackVault_ != LIVE_WETH_BUYBACK_VAULT
                        || vault.degen() != LIVE_DEGEN
                        || PoolId.unwrap(vault.poolId()) != LIVE_DEGEN_POOL_ID))
        ) {
            revert InvalidBuybackVault();
        }

        module = module_;
        weth = weth_;
        operatingTreasury = operatingTreasury_;
        buybackVault = buybackVault_;
        feeLocker = IDegenV1FeeLocker(feeLocker_);
        beneficiaryController = IDegenV1FeeLocker(feeLocker_).LP_LOCKER();
    }

    function registerPool(address token, address beneficiary, address controller)
        external
        onlyModule
        returns (PoolKey memory key)
    {
        if (token == address(0) || token == weth) revert InvalidToken();
        if (beneficiary == address(0)) revert InvalidBeneficiary();
        if (controller == address(0) || controller != beneficiaryController) {
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
        if (_poolConfigs[poolId].token != address(0)) revert PoolAlreadyRegistered();
        _poolConfigs[poolId] =
            PackedPoolConfig({token: token, initializedAt: 0, status: 0, beneficiary: beneficiary});
        _poolIdsByToken[token] = poolId;
        emit PoolRegistered(poolId, token, weth, controller);
    }

    function updateBeneficiary(address token, address newBeneficiary) external {
        if (newBeneficiary == address(0)) revert InvalidBeneficiary();
        PoolId poolId = _poolIdsByToken[token];
        PackedPoolConfig storage config = _poolConfigs[poolId];
        if (config.token == address(0)) revert PoolNotRegistered();
        if (msg.sender != beneficiaryController) revert OnlyBeneficiaryController();
        address previousBeneficiary = config.beneficiary;
        config.beneficiary = newBeneficiary;
        emit BeneficiaryUpdated(poolId, token, previousBeneficiary, newBeneficiary);
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

    function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        internal
        view
        override
        returns (bytes4)
    {
        PackedPoolConfig storage config = _poolConfigs[key.toId()];
        if (config.token == address(0)) revert PoolNotRegistered();
        if (sender != module) revert OnlyModule();
        if (config.initializedAt != 0) revert PoolAlreadyInitialized();
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
        PackedPoolConfig storage config = _poolConfigs[poolId];
        if (config.token == address(0)) revert PoolNotRegistered();
        if (sender != module) revert OnlyModule();
        if (config.initializedAt != 0) revert PoolAlreadyInitialized();
        if (sqrtPriceX96 != TickMath.getSqrtPriceAtTick(INITIAL_TICK) || tick != INITIAL_TICK) {
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
        _requireFullQuoteSettlement(params, wethDelta, totalRate);
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

    function _requireFullQuoteSettlement(
        IPoolManager.SwapParams calldata params,
        int128 wethDelta,
        uint256 totalRate
    ) private pure {
        bool exactInput = params.amountSpecified < 0;
        uint256 expectedPoolWeth;
        uint256 realizedPoolWeth;
        if (exactInput && !params.zeroForOne) {
            uint256 grossWeth = _absolute(params.amountSpecified);
            DegenFeeMath.FeeSplit memory split = DegenFeeMath.splitHookFee(grossWeth, totalRate);
            expectedPoolWeth = grossWeth - split.totalHookFee;
            if (wethDelta < 0) realizedPoolWeth = _absolute(int256(wethDelta));
        } else if (!exactInput && params.zeroForOne) {
            uint256 netWeth = uint256(params.amountSpecified);
            expectedPoolWeth = DegenFeeMath.grossFromNet(netWeth, totalRate);
            if (wethDelta > 0) realizedPoolWeth = uint128(wethDelta);
        } else {
            return;
        }
        if (realizedPoolWeth != expectedPoolWeth) {
            revert PartialFillUnsupported(expectedPoolWeth, realizedPoolWeth);
        }
    }

    function _accrueWethFee(
        PoolId poolId,
        PoolKey calldata key,
        uint256 grossWethBasis,
        uint256 totalRate,
        DegenFeeMath.FeeSplit memory split
    ) private {
        PackedPoolConfig storage config = _poolConfigs[poolId];
        uint256 cumulativeAmount = totalWethFeesAccrued[poolId] + split.totalHookFee;
        totalWethFeesAccrued[poolId] = cumulativeAmount;
        totalTreasuryWethAccrued[poolId] += split.treasuryCredit;
        totalBuybackWethAccrued[poolId] += split.buybackCredit;
        pendingTreasuryWeth += split.treasuryCredit;
        pendingBuybackWeth += split.buybackCredit;
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
            split.treasuryCredit,
            split.buybackCredit,
            split.roundingDust,
            cumulativeAmount
        );
        poolManager.mint(address(this), key.currency1.toId(), split.totalHookFee);
    }

    /// @notice Permissionlessly delivers both protocol WETH buckets atomically.
    function flushProtocolFees()
        external
        nonReentrant
        returns (uint256 treasuryPaid, uint256 buybackPaid)
    {
        treasuryPaid = pendingTreasuryWeth;
        buybackPaid = pendingBuybackWeth;
        if (treasuryPaid + buybackPaid == 0) return (0, 0);

        pendingTreasuryWeth = 0;
        pendingBuybackWeth = 0;
        totalTreasuryWethSwept += treasuryPaid;
        totalBuybackWethSwept += buybackPaid;
        _redeemClaims(treasuryPaid, buybackPaid, 0);
        emit ProtocolWethSwept(
            PoolId.wrap(bytes32(0)),
            msg.sender,
            treasuryPaid,
            buybackPaid,
            totalTreasuryWethSwept,
            totalBuybackWethSwept,
            false
        );
    }

    /// @notice Permissionlessly checkpoints one creator's attributed WETH into FeeLocker.
    /// @dev V2 deliberately leaves both global protocol buckets untouched.
    function flushPoolFees(PoolId poolId, address beneficiary)
        external
        nonReentrant
        returns (uint256 treasuryPaid, uint256 buybackPaid, uint256 beneficiaryStored)
    {
        if (_poolConfigs[poolId].token == address(0)) {
            revert PoolNotRegistered();
        }
        beneficiaryStored = pendingBeneficiaryWeth[poolId][beneficiary];
        if (beneficiaryStored == 0) return (0, 0, 0);

        pendingBeneficiaryWeth[poolId][beneficiary] = 0;
        pendingBeneficiaryTotalWeth[poolId] -= beneficiaryStored;
        _redeemClaims(0, 0, beneficiaryStored);

        IERC20 wethToken = IERC20(weth);
        wethToken.forceApprove(address(feeLocker), beneficiaryStored);
        uint256 received = feeLocker.storeFees(beneficiary, beneficiaryStored);
        wethToken.forceApprove(address(feeLocker), 0);
        if (received != beneficiaryStored) {
            revert UnexpectedLockerReceipt(beneficiaryStored, received);
        }

        emit BeneficiaryWethFlushed(poolId, beneficiary, msg.sender, beneficiaryStored);
        emit PoolFeesFlushed(poolId, beneficiary, msg.sender, 0, 0, beneficiaryStored);
    }

    function _redeemClaims(uint256 treasuryAmount, uint256 buybackAmount, uint256 creatorAmount)
        private
    {
        _unlocking = true;
        _unlockTreasuryAmount = treasuryAmount;
        _unlockBuybackAmount = buybackAmount;
        _unlockCreatorAmount = creatorAmount;
        poolManager.unlock(abi.encode(treasuryAmount, buybackAmount, creatorAmount));
        _unlocking = false;
        _unlockTreasuryAmount = 0;
        _unlockBuybackAmount = 0;
        _unlockCreatorAmount = 0;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || !_unlocking) revert UnauthorizedUnlock();
        (uint256 treasuryAmount, uint256 buybackAmount, uint256 creatorAmount) =
            abi.decode(data, (uint256, uint256, uint256));
        if (
            treasuryAmount != _unlockTreasuryAmount || buybackAmount != _unlockBuybackAmount
                || creatorAmount != _unlockCreatorAmount
        ) {
            revert UnauthorizedUnlock();
        }

        Currency wethCurrency = Currency.wrap(weth);
        poolManager.burn(
            address(this), wethCurrency.toId(), treasuryAmount + buybackAmount + creatorAmount
        );
        if (treasuryAmount != 0) poolManager.take(wethCurrency, operatingTreasury, treasuryAmount);
        if (buybackAmount != 0) poolManager.take(wethCurrency, buybackVault, buybackAmount);
        if (creatorAmount != 0) poolManager.take(wethCurrency, address(this), creatorAmount);
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
