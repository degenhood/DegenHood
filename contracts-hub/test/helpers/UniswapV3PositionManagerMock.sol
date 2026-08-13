// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {
    INonfungiblePositionManagerMinimal
} from "../../src/interfaces/INonfungiblePositionManagerMinimal.sol";
import {IUniswapV3PoolMinimal} from "../../src/interfaces/IUniswapV3PoolMinimal.sol";

contract V3FixtureToken is ERC20 {
    bool public revertTransfers;
    address public blockedRecipient;
    address public oneShotRebateSender;
    uint256 public oneShotRebateAmount;

    error ForcedTransferFailure();

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }

    function setRevertTransfers(bool enabled) external {
        revertTransfers = enabled;
    }

    function setBlockedRecipient(address recipient) external {
        blockedRecipient = recipient;
    }

    function setOneShotSenderRebate(address sender, uint256 amount) external {
        oneShotRebateSender = sender;
        oneShotRebateAmount = amount;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (
            from != address(0)
                && (revertTransfers || (blockedRecipient != address(0) && to == blockedRecipient))
        ) revert ForcedTransferFailure();
        super._update(from, to, value);
        if (from != address(0) && from == oneShotRebateSender && oneShotRebateAmount != 0) {
            uint256 rebate = oneShotRebateAmount;
            oneShotRebateSender = address(0);
            oneShotRebateAmount = 0;
            _mint(from, rebate);
        }
    }
}

contract UniswapV3PoolMock is IUniswapV3PoolMinimal {
    address public immutable override factory;
    address public immutable override token0;
    address public immutable override token1;
    uint24 public immutable override fee;
    int24 public immutable override tickSpacing;

    uint160 private _sqrtPriceX96;
    int24 private _tick;
    uint8 private _feeProtocol;

    error OnlyFactory();

    constructor(
        address factory_,
        address token0_,
        address token1_,
        uint24 fee_,
        int24 tickSpacing_,
        uint160 sqrtPriceX96_
    ) {
        factory = factory_;
        token0 = token0_;
        token1 = token1_;
        fee = fee_;
        tickSpacing = tickSpacing_;
        _setSlot0(sqrtPriceX96_, TickMath.getTickAtSqrtPrice(sqrtPriceX96_), 0);
    }

    function setSlot0(uint160 sqrtPriceX96_, int24 tick_, uint8 feeProtocol_) external {
        if (msg.sender != factory) revert OnlyFactory();
        _setSlot0(sqrtPriceX96_, tick_, feeProtocol_);
    }

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        )
    {
        return (_sqrtPriceX96, _tick, 0, 1, 1, _feeProtocol, true);
    }

    function _setSlot0(uint160 sqrtPriceX96_, int24 tick_, uint8 feeProtocol_) private {
        _sqrtPriceX96 = sqrtPriceX96_;
        _tick = tick_;
        _feeProtocol = feeProtocol_;
    }
}

    /// @notice Adversarial position-manager fixture for the DEGEN V1 — Uniswap V3 PoC only.
    contract UniswapV3PositionManagerMock is INonfungiblePositionManagerMinimal {
        using SafeERC20 for IERC20;

        uint256 private constant PIPS = 1_000_000;

        struct MockPosition {
            address owner;
            address token0;
            address token1;
            uint24 fee;
            int24 tickLower;
            int24 tickUpper;
            uint128 liquidity;
            uint128 tokensOwed0;
            uint128 tokensOwed1;
        }

        address public immutable override factory = address(this);
        address public immutable owner = address(this);
        uint256 public mintConsumptionPips = PIPS;
        uint256 public nextTokenId;
        bool public lieAboutOwner;
        bool public revertCollect;
        bool public lastReentrySucceeded;
        uint256 public collectReturnBonus0;
        uint256 public collectReturnBonus1;
        address public collectReentryTarget;
        bytes public collectReentryData;

        mapping(uint24 fee => int24 tickSpacing) public feeAmountTickSpacing;
        mapping(bytes32 poolKey => address pool) private _pools;
        mapping(uint256 tokenId => MockPosition position) private _positions;

        error InvalidFeeTier(uint24 fee);
        error InvalidPoolTokens();
        error InvalidPrice();
        error PoolNotCreated();
        error InvalidTickRange();
        error InvalidRecipient();
        error DeadlineExpired();
        error MinimumAmountNotMet();
        error InvalidConsumptionPips();
        error UnknownPosition(uint256 tokenId);
        error NotPositionOwner(uint256 tokenId, address caller);
        error FeeAmountOverflow();
        error ForcedCollectFailure();

        function setFeeTier(uint24 fee, int24 tickSpacing) external {
            if (fee == 0 || tickSpacing <= 0) revert InvalidFeeTier(fee);
            feeAmountTickSpacing[fee] = tickSpacing;
        }

        function setMintConsumptionPips(uint256 consumptionPips) external {
            if (consumptionPips > PIPS) revert InvalidConsumptionPips();
            mintConsumptionPips = consumptionPips;
        }

        function setLieAboutOwner(bool enabled) external {
            lieAboutOwner = enabled;
        }

        function setRevertCollect(bool enabled) external {
            revertCollect = enabled;
        }

        function setCollectReentry(address target, bytes calldata data) external {
            collectReentryTarget = target;
            collectReentryData = data;
        }

        function setCollectReturnBonus(uint256 amount0Bonus, uint256 amount1Bonus) external {
            collectReturnBonus0 = amount0Bonus;
            collectReturnBonus1 = amount1Bonus;
        }

        function getPool(address tokenA, address tokenB, uint24 fee)
            external
            view
            returns (address)
        {
            (address token0, address token1) = _sort(tokenA, tokenB);
            return _pools[_poolKey(token0, token1, fee)];
        }

        function setPoolState(address pool, uint160 sqrtPriceX96, int24 tick, uint8 feeProtocol)
            external
        {
            UniswapV3PoolMock(pool).setSlot0(sqrtPriceX96, tick, feeProtocol);
        }

        function createAndInitializePoolIfNecessary(
            address token0,
            address token1,
            uint24 fee,
            uint160 sqrtPriceX96
        ) external payable returns (address pool) {
            if (token0 == address(0) || token0 >= token1) revert InvalidPoolTokens();
            int24 spacing = feeAmountTickSpacing[fee];
            if (spacing == 0) revert InvalidFeeTier(fee);
            if (sqrtPriceX96 == 0) revert InvalidPrice();

            bytes32 key = _poolKey(token0, token1, fee);
            pool = _pools[key];
            if (pool == address(0)) {
                pool = address(
                    new UniswapV3PoolMock(address(this), token0, token1, fee, spacing, sqrtPriceX96)
                );
                _pools[key] = pool;
            }
        }

        function mint(MintParams calldata params)
            external
            payable
            returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
        {
            if (params.deadline < block.timestamp) revert DeadlineExpired();
            if (params.recipient == address(0)) revert InvalidRecipient();
            int24 spacing = feeAmountTickSpacing[params.fee];
            if (
                spacing == 0 || params.tickLower >= params.tickUpper
                    || params.tickLower % spacing != 0 || params.tickUpper % spacing != 0
            ) {
                revert InvalidTickRange();
            }
            address pool = _pools[_poolKey(params.token0, params.token1, params.fee)];
            if (pool == address(0)) revert PoolNotCreated();

            amount0 = Math.mulDiv(params.amount0Desired, mintConsumptionPips, PIPS);
            amount1 = Math.mulDiv(params.amount1Desired, mintConsumptionPips, PIPS);
            if (amount0 < params.amount0Min || amount1 < params.amount1Min) {
                revert MinimumAmountNotMet();
            }
            if (amount0 != 0) IERC20(params.token0).safeTransferFrom(msg.sender, pool, amount0);
            if (amount1 != 0) IERC20(params.token1).safeTransferFrom(msg.sender, pool, amount1);

            uint256 liquidityValue = amount0 + amount1;
            liquidity = uint128(Math.min(liquidityValue, type(uint128).max));
            tokenId = ++nextTokenId;
            _positions[tokenId] = MockPosition({
                owner: params.recipient,
                token0: params.token0,
                token1: params.token1,
                fee: params.fee,
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                liquidity: liquidity,
                tokensOwed0: 0,
                tokensOwed1: 0
            });
        }

        function accrueFees(uint256 tokenId, uint256 amount0, uint256 amount1) external {
            MockPosition storage position = _positions[tokenId];
            if (position.owner == address(0)) revert UnknownPosition(tokenId);
            if (amount0 > type(uint128).max || amount1 > type(uint128).max) {
                revert FeeAmountOverflow();
            }

            uint256 nextOwed0 = uint256(position.tokensOwed0) + amount0;
            uint256 nextOwed1 = uint256(position.tokensOwed1) + amount1;
            if (nextOwed0 > type(uint128).max || nextOwed1 > type(uint128).max) {
                revert FeeAmountOverflow();
            }
            if (amount0 != 0) {
                IERC20(position.token0).safeTransferFrom(msg.sender, address(this), amount0);
            }
            if (amount1 != 0) {
                IERC20(position.token1).safeTransferFrom(msg.sender, address(this), amount1);
            }
            position.tokensOwed0 = uint128(nextOwed0);
            position.tokensOwed1 = uint128(nextOwed1);
        }

        function collect(CollectParams calldata params)
            external
            payable
            returns (uint256 amount0, uint256 amount1)
        {
            if (revertCollect) revert ForcedCollectFailure();
            if (params.recipient == address(0)) revert InvalidRecipient();
            MockPosition storage position = _positions[params.tokenId];
            if (position.owner == address(0)) revert UnknownPosition(params.tokenId);
            if (msg.sender != position.owner) revert NotPositionOwner(params.tokenId, msg.sender);

            address reentryTarget = collectReentryTarget;
            if (reentryTarget != address(0)) {
                bytes memory reentryData = collectReentryData;
                collectReentryTarget = address(0);
                delete collectReentryData;
                (lastReentrySucceeded,) = reentryTarget.call(reentryData);
            }

            amount0 = Math.min(uint256(position.tokensOwed0), uint256(params.amount0Max));
            amount1 = Math.min(uint256(position.tokensOwed1), uint256(params.amount1Max));
            position.tokensOwed0 -= uint128(amount0);
            position.tokensOwed1 -= uint128(amount1);

            if (amount0 != 0) IERC20(position.token0).safeTransfer(params.recipient, amount0);
            if (amount1 != 0) IERC20(position.token1).safeTransfer(params.recipient, amount1);
            amount0 += collectReturnBonus0;
            amount1 += collectReturnBonus1;
        }

        function ownerOf(uint256 tokenId) external view returns (address positionOwner) {
            positionOwner = _positions[tokenId].owner;
            if (positionOwner == address(0)) revert UnknownPosition(tokenId);
            if (lieAboutOwner) return address(0);
        }

        function positions(uint256 tokenId)
            external
            view
            returns (
                uint96 nonce,
                address operator,
                address token0,
                address token1,
                uint24 fee,
                int24 tickLower,
                int24 tickUpper,
                uint128 liquidity,
                uint256 feeGrowthInside0LastX128,
                uint256 feeGrowthInside1LastX128,
                uint128 tokensOwed0,
                uint128 tokensOwed1
            )
        {
            MockPosition memory position = _positions[tokenId];
            if (position.owner == address(0)) revert UnknownPosition(tokenId);
            return (
                0,
                address(0),
                position.token0,
                position.token1,
                position.fee,
                position.tickLower,
                position.tickUpper,
                position.liquidity,
                0,
                0,
                position.tokensOwed0,
                position.tokensOwed1
            );
        }

        function _sort(address tokenA, address tokenB)
            private
            pure
            returns (address token0, address token1)
        {
            if (tokenA == address(0) || tokenA == tokenB) revert InvalidPoolTokens();
            (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        }

        function _poolKey(address token0, address token1, uint24 fee)
            private
            pure
            returns (bytes32)
        {
            return keccak256(abi.encode(token0, token1, fee));
        }
    }
