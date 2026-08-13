// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DomainId, LaunchContext, LaunchResult} from "../LaunchHub.sol";

interface IDegenSpyV1Module {
    error OnlyKernel(address caller);
    error InvalidAddress();
    error InvalidChildBinding();
    error InvalidLaunchContext();
    error InvalidTokenBalance(uint256 expected, uint256 actual);
    error InvalidSpyIdentity(bytes32 observedUid);
    error InvalidSpyRegistry(address observedRegistry);
    error SpyTransfersPaused();
    error SpyAddressBlocked(address account);
    error TokenResidue(uint256 balance);

    event DegenSpyLaunchConfigured(
        address indexed token,
        bytes32 indexed poolId,
        uint256 indexed firstPositionId,
        address beneficiary,
        address feeAdmin,
        uint256 launchUiMultiplier
    );

    function configure(LaunchContext calldata context) external returns (LaunchResult memory result);
    function kernel() external view returns (address);
    function domainId() external view returns (DomainId);
    function configHash() external view returns (bytes32);
    function launchUiMultiplier(address token) external view returns (uint256);
}
