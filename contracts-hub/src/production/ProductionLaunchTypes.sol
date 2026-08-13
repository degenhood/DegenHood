// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

type DomainId is bytes32;
type TemplateId is uint256;
type Version is uint32;

enum TemplateStatus {
    NONE,
    PROPOSED,
    ACTIVATED,
    DEPRECATED
}

struct Domain {
    address registrar;
    address guardian;
    bytes32 metadataHash;
    uint64 activeAt;
    bool paused;
    bool exists;
}

struct PendingProposal {
    bytes32 proposalHash;
    uint64 proposalNonce;
    address proposer;
}

struct TemplateProposal {
    address module;
    address tokenDeployer;
    bytes32 moduleCodeHash;
    bytes32 deployerCodeHash;
    bytes32 creationCodeHash;
    bytes32 inputSchemaHash;
    uint32 maxLaunchDataLen;
    bytes32 configHash;
    bytes32 manifestHash;
}

struct ActivatedTemplate {
    address module;
    address tokenDeployer;
    bytes32 moduleCodeHash;
    bytes32 deployerCodeHash;
    bytes32 creationCodeHash;
    bytes32 inputSchemaHash;
    uint32 maxLaunchDataLen;
    bytes32 configHash;
    bytes32 manifestHash;
}

struct GenesisDomain {
    DomainId id;
    address registrar;
    address guardian;
    bytes32 metadataHash;
}

struct GenesisTemplate {
    TemplateId id;
    Version version;
    ActivatedTemplate config;
}

struct TokenArgs {
    string name;
    string symbol;
    address module;
    address tokenAdmin;
    string contractURI;
    string imageURI;
}

struct LaunchRequest {
    DomainId domainId;
    TemplateId templateId;
    Version version;
    address launcher;
    address tokenAdmin;
    address feeAdmin;
    address beneficiary;
    bytes32 userSalt;
    string name;
    string symbol;
    string contractURI;
    string imageURI;
    address predictedToken;
    bytes launchData;
}

struct LaunchContext {
    DomainId domainId;
    TemplateId templateId;
    Version version;
    bytes32 commitment;
    address token;
    address launcher;
    address tokenAdmin;
    address feeAdmin;
    address beneficiary;
    bytes32 metadataHash;
    bytes32 inputSchemaHash;
    bytes launchData;
}

struct LaunchResult {
    bytes32 poolId;
    uint256 positionId;
    bytes32 configEcho;
}

struct LaunchRecord {
    uint256 launchId;
    address token;
    address launcher;
    address tokenAdmin;
    address feeAdmin;
    address beneficiary;
    DomainId domainId;
    TemplateId templateId;
    Version version;
    address module;
    address tokenDeployer;
    bytes32 poolId;
    uint256 positionId;
    bytes32 configHash;
    bytes32 manifestHash;
    bytes32 metadataHash;
    bytes32 launchDataHash;
    bytes32 kernelVersion;
}

interface ITokenDeployer {
    function deploy(bytes32 salt, TokenArgs calldata args) external returns (address token);
    function predict(bytes32 salt, TokenArgs calldata args) external view returns (address token);
    function creationCodeHash() external view returns (bytes32);
    function kernel() external view returns (address);
}

interface ILaunchModule {
    function configure(LaunchContext calldata context) external returns (LaunchResult memory result);
    function domainId() external view returns (DomainId);
    function configHash() external view returns (bytes32);
    function kernel() external view returns (address);
}
