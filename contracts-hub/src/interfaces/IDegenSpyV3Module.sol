// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DomainId, LaunchContext, LaunchResult} from "../LaunchHub.sol";

interface IDegenSpyV3Module {
    error OnlyKernel(address caller);
    error InvalidAddress();
    error InvalidChildBinding();
    error InvalidLaunchContext();
    error InvalidTokenBalance(uint256 expected, uint256 actual);
    error InvalidSpyIdentity(bytes32 observedUid);
    error InvalidSpyRegistry(address observedRegistry);
    error SpyTransfersPaused();
    error SpyAddressBlocked(address account);
    error UnsupportedTokenBehavior();
    error TokenResidue(uint256 balance);
    error InvalidPositionReceipt();

    event DegenSpyLaunchConfigured(
        address indexed token,
        bytes32 indexed poolId,
        uint256 indexed firstPositionId,
        address beneficiary,
        address feeAdmin,
        uint256 launchUiMultiplier,
        uint16 maxWalletBps,
        uint16 maxTxBps,
        uint8 restrictionClock,
        uint40 restrictionStartTime,
        uint40 flatEndTime,
        uint40 rampEndTime
    );

    function configure(LaunchContext calldata context) external returns (LaunchResult memory);
    function launchUiMultiplier(address token) external view returns (uint256);
}
