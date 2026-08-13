// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IDegenSpyV1FeeLocker
/// @notice Fully-backed raw-SPY credits with immutable depositors and fixed-recipient delivery.
interface IDegenSpyV1FeeLocker {
    error InvalidSpy();
    error InvalidDepositor();
    error DuplicateDepositor();
    error InvalidBeneficiary();
    error ZeroAmount();
    error ZeroReceived();
    error UnauthorizedDepositor(address caller);

    event FeesStored(
        address indexed depositor,
        address indexed beneficiary,
        address indexed spy,
        uint256 requestedAmount,
        uint256 receivedAmount,
        uint256 newBalance
    );
    event FeesClaimed(
        address indexed caller, address indexed beneficiary, address indexed spy, uint256 amount
    );

    function SPY() external view returns (address);
    function LP_LOCKER() external view returns (address);
    function HOOK() external view returns (address);
    function allowedDepositors(address depositor) external view returns (bool);
    function feesToClaim(address beneficiary) external view returns (uint256);
    function totalLiability() external view returns (uint256);
    function storeFees(address beneficiary, uint256 amount) external returns (uint256 received);
    function claimFor(address beneficiary) external returns (uint256 amount);
}
