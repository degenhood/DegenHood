// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {CanonicalIpfsDigest} from "../libraries/CanonicalIpfsDigest.sol";
import {IDegenToken} from "./ProductionDegenTokenInterface.sol";
import {ITokenDeployer, TokenArgs} from "./ProductionLaunchTypes.sol";

interface IDegenTokenModuleBinding {
    function poolManager() external view returns (address);
    function positionManager() external view returns (address);
    function lpLocker() external view returns (address);
}

/// @title DegenTokenDeployer
/// @notice Kernel-only CREATE2 deployer for versionless ERC-1167 Degen Token clones.
contract DegenTokenDeployer is ITokenDeployer {
    error InvalidKernel();
    error InvalidImplementation();
    error UnauthorizedKernel(address caller);
    error InvalidCanonicalIpfsUri();
    error InvalidModuleBinding();

    address public immutable override kernel;
    address public immutable implementation;

    constructor(address kernel_, address implementation_) {
        if (kernel_ == address(0)) revert InvalidKernel();
        if (!_isLockedImplementation(implementation_)) revert InvalidImplementation();
        kernel = kernel_;
        implementation = implementation_;
    }

    function deploy(bytes32 salt, TokenArgs calldata args)
        external
        override
        returns (address token)
    {
        if (msg.sender != kernel) revert UnauthorizedKernel(msg.sender);
        bytes32 metadataDigest = CanonicalIpfsDigest.parse(args.contractURI);
        bytes32 imageDigest = CanonicalIpfsDigest.parse(args.imageURI);
        if (args.module.code.length == 0) revert InvalidModuleBinding();
        IDegenTokenModuleBinding moduleBinding = IDegenTokenModuleBinding(args.module);
        address poolManager = moduleBinding.poolManager();
        address positionManager = moduleBinding.positionManager();
        address lpLocker = moduleBinding.lpLocker();

        token = Clones.cloneDeterministic(implementation, salt);
        IDegenToken(token)
            .initialize(
                args.name,
                args.symbol,
                args.module,
                args.tokenAdmin,
                metadataDigest,
                imageDigest,
                poolManager,
                positionManager,
                lpLocker
            );
    }

    function predict(bytes32 salt, TokenArgs calldata args)
        external
        view
        override
        returns (address token)
    {
        CanonicalIpfsDigest.parse(args.contractURI);
        CanonicalIpfsDigest.parse(args.imageURI);
        token = Clones.predictDeterministicAddress(implementation, salt, address(this));
    }

    function creationCodeHash() external view override returns (bytes32) {
        return keccak256(_cloneCreationCode());
    }

    function _cloneCreationCode() private view returns (bytes memory) {
        return abi.encodePacked(
            hex"3d602d80600a3d3981f3",
            hex"363d3d373d3d3d363d73",
            implementation,
            hex"5af43d82803e903d91602b57fd5bf3"
        );
    }

    function _isLockedImplementation(address implementation_) private view returns (bool) {
        if (implementation_.code.length == 0) return false;
        (bool initialisedOk, bytes memory initialisedData) =
            implementation_.staticcall(abi.encodeCall(IDegenToken.initialised, ()));
        (bool frozenOk, bytes memory frozenData) =
            implementation_.staticcall(abi.encodeCall(IDegenToken.metadataFrozen, ()));
        return initialisedOk && initialisedData.length == 32 && abi.decode(initialisedData, (bool))
            && frozenOk && frozenData.length == 32 && abi.decode(frozenData, (bool));
    }
}
