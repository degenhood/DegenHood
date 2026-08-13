// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DomainId, LaunchContext, LaunchResult} from "../LaunchHub.sol";

interface IDegenV3Module {
    /// @notice Raised when `configure` is called by any account other than the bound kernel.
    /// @param caller Account that attempted configuration.
    error OnlyKernel(address caller);
    /// @notice Raised when construction receives a required zero-address dependency.
    error InvalidAddress();
    /// @notice Raised when the hook or locker does not point back to the expected V3 graph.
    error InvalidChildBinding();
    /// @notice Raised when template, version, schema, or launch arguments differ from this module.
    error InvalidLaunchContext();
    /// @notice Raised when the module does not hold the exact fixed launch supply before minting.
    /// @param expected Required token balance.
    /// @param actual Observed token balance.
    error InvalidTokenBalance(uint256 expected, uint256 actual);
    /// @notice Raised when a launched token fails the transfer/balance behavior required for settlement.
    error UnsupportedTokenBehavior();
    /// @notice Raised when token balance remains in the module after all positions are minted.
    /// @param balance Unexpected residue remaining in the module.
    error TokenResidue(uint256 balance);
    /// @notice Raised when a minted position's owner, pool, ticks, or liquidity differs from the curve.
    error InvalidPositionReceipt();

    /// @notice Emitted after the pool and all ten permanent positions are configured successfully.
    /// @param token Launched token address.
    /// @param poolId Uniswap v4 pool identifier.
    /// @param firstPositionId Token ID of the first contiguous position receipt.
    /// @param beneficiary Initial creator fee beneficiary.
    /// @param feeAdmin Account permitted to rotate creator fee destinations.
    /// @param maxWalletBps Flat-phase wallet cap in basis points of fixed supply.
    /// @param maxTxBps Flat-phase transaction cap in basis points of fixed supply.
    /// @param restrictionClock Clock discriminator for the schedule; `1` means unix timestamp.
    /// @param restrictionStartTime Timestamp at which the immutable cap schedule began.
    /// @param flatEndTime First timestamp of the linear cap-release phase.
    /// @param rampEndTime First timestamp at which both caps are fully unrestricted.
    event DegenLaunchConfigured(
        address indexed token,
        bytes32 indexed poolId,
        uint256 indexed firstPositionId,
        address beneficiary,
        address feeAdmin,
        uint16 maxWalletBps,
        uint16 maxTxBps,
        uint8 restrictionClock,
        uint40 restrictionStartTime,
        uint40 flatEndTime,
        uint40 rampEndTime
    );

    /// @notice Configures the one-sided ten-position pool for a kernel-created token.
    /// @param context Kernel-authenticated launch context.
    /// @return result Token, pool, fee claimer, and launch-specific result returned to the kernel.
    function configure(LaunchContext calldata context) external returns (LaunchResult memory result);
    /// @notice Returns the only kernel authorized to configure this module.
    /// @return kernel_ Bound LaunchHub kernel.
    function kernel() external view returns (address kernel_);
    /// @notice Returns the domain in which this module is registered.
    /// @return domainId_ Bound LaunchHub domain identifier.
    function domainId() external view returns (DomainId domainId_);
    /// @notice Returns the immutable configuration commitment admitted by the kernel.
    /// @return configHash_ Hash of the reviewed module graph and launch policy.
    function configHash() external view returns (bytes32 configHash_);
}
