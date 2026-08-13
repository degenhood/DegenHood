// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IDegenV1FeeLocker
/// @notice Fully-backed WETH credits with immutable depositors and fixed-recipient delivery.
interface IDegenV1FeeLocker {
    error InvalidWeth();
    error InvalidDepositor();
    error DuplicateDepositor();
    error InvalidBeneficiary();
    error ZeroAmount();
    error ZeroReceived();
    error UnauthorizedDepositor(address caller);

    event FeesStored(
        address indexed depositor,
        address indexed beneficiary,
        address indexed weth,
        uint256 requestedAmount,
        uint256 receivedAmount,
        uint256 newBalance
    );
    event FeesClaimed(
        address indexed caller, address indexed beneficiary, address indexed weth, uint256 amount
    );

    function WETH() external view returns (address);
    function LP_LOCKER() external view returns (address);
    function HOOK() external view returns (address);
    function allowedDepositors(address depositor) external view returns (bool);
    function feesToClaim(address beneficiary) external view returns (uint256);
    function totalLiability() external view returns (uint256);
    function storeFees(address beneficiary, uint256 amount) external returns (uint256 received);
    function claimFor(address beneficiary) external returns (uint256 amount);
}
