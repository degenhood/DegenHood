// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title DEGEN_V3 hook interface
/// @notice Global protocol WETH delivery and isolated per-creator fee checkpointing.
interface IDegenV3Hook {
    /// @notice Public compatibility view reconstructed from the hook's packed two-slot record.
    struct PoolConfig {
        /// @notice Launched token paired with WETH.
        address token;
        /// @notice Current creator quote-fee destination.
        address beneficiary;
        /// @notice Immutable LP locker allowed to update the beneficiary.
        address beneficiaryController;
        /// @notice True when the module has registered the pool key.
        bool registered;
        /// @notice True after PoolManager completes pool initialization.
        bool initialized;
        /// @notice Timestamp at which pool initialization completed.
        uint64 initializedAt;
    }

    /// @notice Raised when a signed swap delta cannot be represented as an unsigned fee basis.
    /// @param amount Unsigned magnitude that exceeded the supported signed range.
    error FeeAmountOverflow(uint256 amount);
    /// @notice Raised when construction receives a required zero-address dependency.
    error InvalidAddress();
    /// @notice Raised when pool registration or update specifies a zero creator beneficiary.
    error InvalidBeneficiary();
    /// @notice Raised when registration does not name the immutable LP locker as controller.
    error InvalidBeneficiaryController();
    /// @notice Raised when the buyback vault does not match the required quote/pool binding.
    error InvalidBuybackVault();
    /// @notice Raised when the fee locker is not bound to this hook and its LP locker.
    error InvalidFeeLocker();
    /// @notice Raised when PoolManager initializes a registered pool at the wrong starting price.
    error InvalidInitialPrice();
    /// @notice Raised when registration supplies a zero or structurally unsupported token.
    error InvalidToken();
    /// @notice Raised when token and WETH currency ordering is inconsistent with the curve.
    error InvalidTokenOrder();
    /// @notice Raised when pool registration is called by any account other than the module.
    error OnlyModule();
    /// @notice Raised when beneficiary rotation is called by any account other than the LP locker.
    error OnlyBeneficiaryController();
    /// @notice Raised when a quote-specified swap reaches its price limit before full settlement.
    /// @param expectedQuote Pool-side WETH that the requested swap must consume or produce.
    /// @param realizedQuote Pool-side WETH actually consumed or produced before the limit bound.
    error PartialFillUnsupported(uint256 expectedQuote, uint256 realizedQuote);
    /// @notice Raised when PoolManager initializes the same registered pool more than once.
    error PoolAlreadyInitialized();
    /// @notice Raised when the module registers a token or pool that already has a record.
    error PoolAlreadyRegistered();
    /// @notice Raised when a swap or fee operation targets a registered but uninitialized pool.
    error PoolNotInitialized();
    /// @notice Raised when a pool-scoped operation targets an unknown pool identifier.
    error PoolNotRegistered();
    /// @notice Raised when PoolManager invokes the unlock callback outside an authorized sweep.
    error UnauthorizedUnlock();
    /// @notice Raised when the fee locker credits a creator amount different from the hook request.
    /// @param expected Quote amount requested for creator storage.
    /// @param received Quote amount reported by the fee locker.
    error UnexpectedLockerReceipt(uint256 expected, uint256 received);

    /// @notice Emitted when the module registers a token's canonical V3 pool before initialization.
    /// @param poolId Derived Uniswap v4 pool identifier.
    /// @param token Launched token paired by the pool.
    /// @param weth Immutable WETH quote token.
    /// @param beneficiaryController Immutable LP locker allowed to rotate the beneficiary.
    event PoolRegistered(
        PoolId indexed poolId,
        address indexed token,
        address indexed weth,
        address beneficiaryController
    );
    /// @notice Emitted after PoolManager initializes a registered pool at the reviewed price.
    /// @param poolId Initialized Uniswap v4 pool identifier.
    /// @param initializedAt Timestamp used as the launch-fee decay origin.
    /// @param lpFee Dynamic LP fee set at initialization.
    event PoolInitialized(PoolId indexed poolId, uint64 initializedAt, uint24 lpFee);
    /// @notice Emitted after the LP locker checkpoints and changes a pool's creator beneficiary.
    /// @param poolId Pool whose creator destination changed.
    /// @param token Launched token associated with the pool.
    /// @param previousBeneficiary Destination credited before the update.
    /// @param newBeneficiary Destination receiving future creator fees.
    event BeneficiaryUpdated(
        PoolId indexed poolId,
        address indexed token,
        address indexed previousBeneficiary,
        address newBeneficiary
    );
    /// @notice Emitted whenever hook quote fees accrue from a swap.
    /// @param poolId Pool in which the swap occurred.
    /// @param beneficiary Creator destination credited by the temporary fee share.
    /// @param grossWethBasis Gross WETH-denominated fee basis before hook fees.
    /// @param totalRate Total hook rate in parts per million for this swap.
    /// @param totalFee Total hook fee charged.
    /// @param permanentFee Permanent protocol hook-fee component.
    /// @param temporaryFee Decaying launch-surcharge component.
    /// @param beneficiaryTemporary Temporary fee credited to the creator.
    /// @param treasuryCredit Quote credited to the pending treasury bucket.
    /// @param buybackCredit Quote credited to the pending buyback bucket.
    /// @param roundingDust Integer division remainder assigned by fee policy.
    /// @param cumulativeAmount Lifetime hook quote fees accrued for the pool.
    event WethHookFeeAccrued(
        PoolId indexed poolId,
        address indexed beneficiary,
        uint256 grossWethBasis,
        uint256 totalRate,
        uint256 totalFee,
        uint256 permanentFee,
        uint256 temporaryFee,
        uint256 beneficiaryTemporary,
        uint256 treasuryCredit,
        uint256 buybackCredit,
        uint256 roundingDust,
        uint256 cumulativeAmount
    );
    /// @notice Emitted after pending protocol quote buckets are delivered successfully.
    /// @param triggeringPoolId Zero for the global permissionless flush path.
    /// @param caller Account that initiated the enclosing operation.
    /// @param treasuryAmount Quote delivered to the immutable treasury.
    /// @param buybackAmount Quote delivered to the immutable buyback vault.
    /// @param cumulativeTreasurySwept Lifetime treasury quote delivered by the hook.
    /// @param cumulativeBuybackSwept Lifetime buyback quote delivered by the hook.
    /// @param automatic Retained for ABI stability and always false in V3.
    event ProtocolWethSwept(
        PoolId indexed triggeringPoolId,
        address indexed caller,
        uint256 treasuryAmount,
        uint256 buybackAmount,
        uint256 cumulativeTreasurySwept,
        uint256 cumulativeBuybackSwept,
        bool automatic
    );
    /// @notice Emitted after one pool's pending creator quote fees are stored for its beneficiary.
    /// @param poolId Pool whose creator fees were flushed.
    /// @param beneficiary Destination credited by the fee locker.
    /// @param caller Account that initiated the permissionless flush.
    /// @param beneficiaryStored Quote amount stored for the beneficiary.
    event BeneficiaryWethFlushed(
        PoolId indexed poolId,
        address indexed beneficiary,
        address indexed caller,
        uint256 beneficiaryStored
    );
    /// @notice Emitted after a permissionless pool flush attempts every protocol and creator bucket.
    /// @param poolId Pool whose accounting was flushed.
    /// @param beneficiary Creator destination supplied by the bound locker.
    /// @param caller Account that initiated the permissionless flush.
    /// @param treasuryPaid Treasury quote delivered during the call.
    /// @param buybackPaid Buyback quote delivered during the call.
    /// @param beneficiaryStored Creator quote stored during the call.
    event PoolFeesFlushed(
        PoolId indexed poolId,
        address indexed beneficiary,
        address indexed caller,
        uint256 treasuryPaid,
        uint256 buybackPaid,
        uint256 beneficiaryStored
    );

    /// @notice Registers the canonical pool key and initial creator routing for a launched token.
    /// @param token Launched token address.
    /// @param beneficiary Initial creator quote-fee destination.
    /// @param beneficiaryController LP locker allowed to rotate that destination.
    /// @return key Canonical WETH pool key to initialize and provision.
    function registerPool(address token, address beneficiary, address beneficiaryController)
        external
        returns (PoolKey memory key);
    /// @notice Changes a registered pool's creator destination through its immutable controller.
    /// @param token Launched token whose beneficiary changes.
    /// @param newBeneficiary Nonzero destination for future creator fees.
    function updateBeneficiary(address token, address newBeneficiary) external;
    /// @notice Permissionlessly delivers all pending protocol quote buckets.
    /// @return treasuryPaid Quote delivered to the treasury.
    /// @return buybackPaid Quote delivered to the buyback vault.
    function flushProtocolFees() external returns (uint256 treasuryPaid, uint256 buybackPaid);
    /// @notice Permissionlessly delivers pending protocol and creator quote fees for one pool.
    /// @param poolId Registered pool to flush.
    /// @param beneficiary Expected current creator destination, supplied by the bound locker.
    /// @return treasuryPaid Quote delivered to the treasury.
    /// @return buybackPaid Quote delivered to the buyback vault.
    /// @return beneficiaryStored Quote stored for the creator.
    function flushPoolFees(PoolId poolId, address beneficiary)
        external
        returns (uint256 treasuryPaid, uint256 buybackPaid, uint256 beneficiaryStored);
    /// @notice Returns lifetime hook quote fees accrued for a pool.
    /// @param poolId Pool to query.
    /// @return amount Lifetime WETH fee amount.
    function totalWethFeesAccrued(PoolId poolId) external view returns (uint256 amount);
    /// @notice Returns lifetime treasury quote credits attributed to a pool.
    /// @param poolId Pool to query.
    /// @return amount Lifetime treasury WETH amount.
    function totalTreasuryWethAccrued(PoolId poolId) external view returns (uint256 amount);
    /// @notice Returns lifetime buyback quote credits attributed to a pool.
    /// @param poolId Pool to query.
    /// @return amount Lifetime buyback WETH amount.
    function totalBuybackWethAccrued(PoolId poolId) external view returns (uint256 amount);
    /// @notice Returns treasury WETH awaiting delivery across all pools.
    /// @return amount Pending treasury WETH amount.
    function pendingTreasuryWeth() external view returns (uint256 amount);
    /// @notice Returns buyback WETH awaiting delivery across all pools.
    /// @return amount Pending buyback WETH amount.
    function pendingBuybackWeth() external view returns (uint256 amount);
    /// @notice Returns lifetime treasury WETH delivered by this hook.
    /// @return amount Cumulative swept treasury amount.
    function totalTreasuryWethSwept() external view returns (uint256 amount);
    /// @notice Returns lifetime buyback WETH delivered by this hook.
    /// @return amount Cumulative swept buyback amount.
    function totalBuybackWethSwept() external view returns (uint256 amount);
    /// @notice Returns one beneficiary's pending creator quote balance for a pool.
    /// @param poolId Pool to query.
    /// @param beneficiary Creator destination to query.
    /// @return amount Pending creator WETH amount.
    function pendingBeneficiaryWeth(PoolId poolId, address beneficiary)
        external
        view
        returns (uint256 amount);
    /// @notice Returns total creator quote awaiting storage for a pool.
    /// @param poolId Pool to query.
    /// @return amount Pending creator WETH across beneficiaries.
    function pendingBeneficiaryTotalWeth(PoolId poolId) external view returns (uint256 amount);
    /// @notice Reconstructs the stable six-field pool tuple from packed storage and immutables.
    /// @param poolId Pool to query.
    /// @return config Compatibility configuration returned to lockers and indexers.
    function getPoolConfig(PoolId poolId) external view returns (PoolConfig memory config);
    /// @notice Returns the registered pool identifier for a launched token.
    /// @param token Launched token to query.
    /// @return poolId Registered pool identifier, or zero when unknown.
    function poolIdForToken(address token) external view returns (PoolId poolId);
}
