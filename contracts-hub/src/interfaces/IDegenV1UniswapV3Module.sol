// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DomainId, LaunchContext, LaunchResult} from "../LaunchHub.sol";

interface IDegenV1UniswapV3Module {
    error OnlyKernel(address caller);
    error InvalidAddress();
    error InvalidChildBinding();
    error InvalidLaunchContext();
    error InvalidTokenBalance(uint256 expected, uint256 actual);
    error InvalidPoolState();
    error NonzeroProtocolFee(uint8 feeProtocol);
    error TokenResidue(uint256 balance);

    event DegenUniswapV3LaunchConfigured(
        address indexed token,
        address indexed pool,
        uint256 indexed firstPositionId,
        address beneficiary,
        address feeAdmin
    );

    function configure(LaunchContext calldata context) external returns (LaunchResult memory result);
    function kernel() external view returns (address);
    function domainId() external view returns (DomainId);
    function configHash() external view returns (bytes32);
}
