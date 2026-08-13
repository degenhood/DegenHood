// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DomainId, LaunchContext, LaunchResult} from "../LaunchHub.sol";

interface IStandardV1Module {
    error OnlyKernel(address caller);
    error InvalidAddress();
    error InvalidChildBinding();
    error InvalidLaunchContext();
    error InvalidTokenBalance(uint256 expected, uint256 actual);
    error TokenResidue(uint256 balance);

    event StandardLaunchConfigured(
        address indexed token,
        bytes32 indexed poolId,
        uint256 indexed positionId,
        address beneficiary,
        address feeAdmin
    );

    function configure(LaunchContext calldata context) external returns (LaunchResult memory result);
    function kernel() external view returns (address);
    function domainId() external view returns (DomainId);
    function configHash() external view returns (bytes32);
}
