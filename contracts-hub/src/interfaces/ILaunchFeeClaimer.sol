// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ILaunchFeeClaimer
/// @notice Common one-transaction fee-delivery surface for reviewed LaunchHub template lockers.
interface ILaunchFeeClaimer {
    event FeesDelivered(
        address indexed token,
        address indexed beneficiary,
        address indexed caller,
        uint256 lpTokenFees,
        uint256 lpWethStored,
        uint256 hookCreatorWethStored,
        uint256 beneficiaryWethDelivered
    );

    /// @notice Collects every available fee source for `token` and pays its recorded beneficiary.
    /// @dev Permissionless and destination-bound. The caller cannot select the recipient.
    function claimFees(address token) external returns (uint256 beneficiaryWethDelivered);
}
