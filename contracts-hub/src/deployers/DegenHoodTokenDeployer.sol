// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DegenHoodTokenV4} from "../token/DegenHoodTokenV4.sol";

/// @title DegenHoodTokenDeployer
/// @notice Immutable, kernel-only CREATE2 deployer for the fixed DegenHood token implementation.
contract DegenHoodTokenDeployer {
    struct TokenArgs {
        string name;
        string symbol;
        address module;
        address tokenAdmin;
        string contractURI;
        string imageURI;
    }

    error InvalidKernel();
    error UnauthorizedKernel(address caller);

    address public immutable kernel;

    constructor(address kernel_) {
        if (kernel_ == address(0)) revert InvalidKernel();
        kernel = kernel_;
    }

    function deploy(bytes32 salt, TokenArgs calldata args) external returns (address token) {
        if (msg.sender != kernel) revert UnauthorizedKernel(msg.sender);

        token = address(
            new DegenHoodTokenV4{salt: salt}(
                args.name,
                args.symbol,
                args.module,
                args.tokenAdmin,
                args.contractURI,
                args.imageURI
            )
        );
    }

    function predict(bytes32 salt, TokenArgs calldata args) external view returns (address) {
        bytes32 initCodeHash = _initCodeHash(args);
        return address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash))
                )
            )
        );
    }

    function creationCodeHash() external pure returns (bytes32) {
        return keccak256(type(DegenHoodTokenV4).creationCode);
    }

    function _initCodeHash(TokenArgs calldata args) private pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                type(DegenHoodTokenV4).creationCode,
                abi.encode(
                    args.name,
                    args.symbol,
                    args.module,
                    args.tokenAdmin,
                    args.contractURI,
                    args.imageURI
                )
            )
        );
    }
}
