// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILaunchFeeClaimer} from "./ILaunchFeeClaimer.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IDegenSpyV2LpLocker is ILaunchFeeClaimer {
    struct PositionConfig {
        PoolKey poolKey;
        uint256[6] positionIds;
        address beneficiary;
        address feeAdmin;
        uint256 poolSupply;
        uint256 tokenPrincipal;
        uint256 lockedTokenDust;
        bool placed;
    }

    error OnlyModule();
    error OnlyFeeAdmin();
    error InvalidAddress();
    error InvalidFeeLocker();
    error InvalidBeneficiary();
    error InvalidFeeAdmin();
    error InvalidPoolKey();
    error InvalidPoolSupply();
    error PositionAlreadyPlaced();
    error PositionNotFound();
    error UnsupportedTokenBehavior();
    error InvalidPositionReceipt();

    event LiquidityPlaced(
        address indexed token,
        uint256 indexed firstPositionId,
        address indexed beneficiary,
        address feeAdmin,
        uint256 poolSupply,
        uint256 tokenPrincipal,
        uint256 lockedTokenDust
    );
    event FeesCollected(
        address indexed token,
        address indexed beneficiary,
        uint256 tokenFees,
        uint256 tokenReserveAmount,
        uint256 tokenBurnAmount,
        uint256 rawSpyFees
    );
    event BeneficiaryUpdated(
        address indexed token,
        address indexed previousBeneficiary,
        address indexed newBeneficiary,
        address feeAdmin
    );
    event FeeAdminUpdated(
        address indexed token, address indexed previousFeeAdmin, address indexed newFeeAdmin
    );

    function placeLiquidity(
        PoolKey calldata poolKey,
        address token,
        uint256 poolSupply,
        address beneficiary,
        address feeAdmin
    ) external returns (uint256);
    function collectRewards(address token) external returns (uint256, uint256);
    function updateBeneficiary(address token, address newBeneficiary) external;
    function updateFeeAdmin(address token, address newFeeAdmin) external;
    function positionForToken(address token) external view returns (PositionConfig memory);
}
