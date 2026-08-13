// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {ILaunchFeeClaimer} from "./ILaunchFeeClaimer.sol";

interface IDegenV3LpLocker is ILaunchFeeClaimer {
    /// @notice Permanent position and payout configuration for one launched token.
    struct PositionConfig {
        /// @notice Immutable Uniswap v4 pool key shared by all ten positions.
        PoolKey poolKey;
        /// @notice Ten position NFTs held permanently by this locker.
        uint256[10] positionIds;
        /// @notice Current destination for creator quote fees.
        address beneficiary;
        /// @notice Account allowed to rotate beneficiary and fee-admin destinations.
        address feeAdmin;
        /// @notice Fixed token supply assigned to the launch pool.
        uint256 poolSupply;
        /// @notice Token principal represented by the minted liquidity.
        uint256 tokenPrincipal;
        /// @notice Integer-liquidity token dust permanently held by the locker.
        uint256 lockedTokenDust;
        /// @notice True after the module registers all position receipts once.
        bool placed;
    }

    /// @notice Raised when a caller other than the immutable launch module registers positions.
    error OnlyModule();
    /// @notice Raised when a caller other than the recorded fee admin changes a payout role.
    error OnlyFeeAdmin();
    /// @notice Raised when construction or registration receives a required zero address.
    error InvalidAddress();
    /// @notice Raised when the fee locker is not immutably bound to this locker and its hook.
    error InvalidFeeLocker();
    /// @notice Raised when a zero beneficiary is supplied or stored for a registered token.
    error InvalidBeneficiary();
    /// @notice Raised when a zero fee administrator is supplied for a registered token.
    error InvalidFeeAdmin();
    /// @notice Raised when the pool currencies, fee, tick spacing, or hook differ from policy.
    error InvalidPoolKey();
    /// @notice Raised when the declared pool supply differs from the fixed V3 launch supply.
    error InvalidPoolSupply();
    /// @notice Raised when the module attempts to register a token more than once.
    error PositionAlreadyPlaced();
    /// @notice Raised when fee collection or role rotation targets an unregistered token.
    error PositionNotFound();
    /// @notice Raised when the launched token fails required transfer or burn behavior.
    error UnsupportedTokenBehavior();
    /// @notice Raised when any receipt has the wrong owner, pool, ticks, or curve-derived liquidity.
    error InvalidPositionReceipt();

    /// @notice Emitted after all ten verified position NFTs and any rounding dust are locked.
    /// @param token Launched token associated with the positions.
    /// @param firstPositionId First token ID in the contiguous ten-receipt set.
    /// @param beneficiary Initial creator quote-fee destination.
    /// @param feeAdmin Initial account allowed to rotate creator payout roles.
    /// @param poolSupply Fixed supply allocated to the launch pool.
    /// @param tokenPrincipal Token amount represented by curve-derived liquidity.
    /// @param lockedTokenDust Token rounding dust held permanently by the locker.
    event LiquidityPlaced(
        address indexed token,
        uint256 indexed firstPositionId,
        address indexed beneficiary,
        address feeAdmin,
        uint256 poolSupply,
        uint256 tokenPrincipal,
        uint256 lockedTokenDust
    );
    /// @notice Emitted after permissionless collection routes token and quote fees.
    /// @param token Launched token whose positions were collected.
    /// @param beneficiary Creator quote-fee destination at collection time.
    /// @param tokenFees Total token-side LP fees collected.
    /// @param tokenReserveAmount Token fees sent to the immutable reserve.
    /// @param tokenBurnAmount Token fees burned from total supply.
    /// @param wethFees Quote fees deposited for the creator.
    event FeesCollected(
        address indexed token,
        address indexed beneficiary,
        uint256 tokenFees,
        uint256 tokenReserveAmount,
        uint256 tokenBurnAmount,
        uint256 wethFees
    );
    /// @notice Emitted after the fee admin checkpoints and changes a creator beneficiary.
    /// @param token Launched token whose payout destination changed.
    /// @param previousBeneficiary Destination paid through the update checkpoint.
    /// @param newBeneficiary Destination receiving future creator fees.
    /// @param feeAdmin Account that authorized the update.
    event BeneficiaryUpdated(
        address indexed token,
        address indexed previousBeneficiary,
        address indexed newBeneficiary,
        address feeAdmin
    );
    /// @notice Emitted when a token's fee-administration role is transferred.
    /// @param token Launched token whose fee admin changed.
    /// @param previousFeeAdmin Account that authorized the transfer.
    /// @param newFeeAdmin Account authorized for future role changes.
    event FeeAdminUpdated(
        address indexed token, address indexed previousFeeAdmin, address indexed newFeeAdmin
    );

    /// @notice Verifies and permanently records all ten position receipts for one launched token.
    /// @param poolKey Reviewed Uniswap v4 key shared by the receipts.
    /// @param token Launched token address.
    /// @param positionIds Ten position NFT identifiers in curve order.
    /// @param poolSupply Fixed token supply allocated to the pool.
    /// @param beneficiary Initial creator quote-fee destination.
    /// @param feeAdmin Initial account allowed to rotate creator payout roles.
    /// @return firstPositionId First token ID in the verified contiguous receipt set.
    function registerPositions(
        PoolKey calldata poolKey,
        address token,
        uint256[10] calldata positionIds,
        uint256 poolSupply,
        address beneficiary,
        address feeAdmin
    ) external returns (uint256 firstPositionId);
    /// @notice Permissionlessly collects all positions and routes token and creator quote fees.
    /// @param token Registered launched token.
    /// @return tokenFees Total token-side fees collected before the 80/20 route.
    /// @return wethFees Total creator quote fees deposited into the fee locker.
    function collectRewards(address token) external returns (uint256 tokenFees, uint256 wethFees);
    /// @notice Checkpoints accrued creator fees and changes their future destination.
    /// @param token Registered launched token.
    /// @param newBeneficiary Nonzero destination for future creator fees.
    function updateBeneficiary(address token, address newBeneficiary) external;
    /// @notice Transfers the authority to rotate creator payout destinations.
    /// @param token Registered launched token.
    /// @param newFeeAdmin Nonzero account receiving the role.
    function updateFeeAdmin(address token, address newFeeAdmin) external;
    /// @notice Returns the permanent position and payout configuration for a launched token.
    /// @param token Launched token to query.
    /// @return config Recorded position configuration; `placed` is false when not registered.
    function positionForToken(address token) external view returns (PositionConfig memory config);
}
