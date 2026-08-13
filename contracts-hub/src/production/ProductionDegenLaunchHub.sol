// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {
    ActivatedTemplate,
    Domain,
    DomainId,
    GenesisDomain,
    GenesisTemplate,
    ILaunchModule,
    ITokenDeployer,
    LaunchContext,
    LaunchRecord,
    LaunchRequest,
    LaunchResult,
    PendingProposal,
    TemplateId,
    TemplateProposal,
    TemplateStatus,
    TokenArgs,
    Version
} from "./ProductionLaunchTypes.sol";

/// @title DegenLaunchHub
/// @notice Fresh immutable two-template kernel for Degen Token launches.
contract DegenLaunchHub {
    using SignatureChecker for address;
    using SafeCast for uint256;

    bytes32 public constant KERNEL_VERSION = keccak256("DegenLaunchHub/1.0.0");
    bytes32 public constant EMPTY_SCHEMA_HASH = keccak256("EMPTY");
    uint256 public constant DOMAIN_ADMISSION_DELAY = 72 hours;
    TemplateId public constant DEGEN_WETH = TemplateId.wrap(1);
    TemplateId public constant DEGEN_SPY = TemplateId.wrap(2);
    bytes32 public constant ADMISSION_TYPEHASH = keccak256(
        "DomainAdmission(address registrar,address guardian,uint256 nonce,bytes32 metadataHash,uint256 expiry)"
    );

    bytes32 private constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant NAME_HASH = keccak256("DegenLaunchHub");
    bytes32 private constant VERSION_HASH = keccak256("1");

    error InvalidGlobalAuthority();
    error GlobalAuthorityOverlap(address authority);
    error InvalidGenesisAuthority(address authority);
    error DuplicateGenesisAuthority(address authority);
    error InvalidGenesisDomainId();
    error InvalidGenesisTemplateSet();
    error DuplicateGenesisModule();
    error InvalidGenesisVersion();
    error InvalidGenesisSchema();
    error InvalidGenesisChild();
    error GenesisModuleCodeMismatch();
    error GenesisDeployerCodeMismatch();
    error GenesisCreationCodeMismatch();
    error GenesisModuleDomainMismatch();
    error GenesisModuleConfigMismatch();
    error ChildKernelMismatch();
    error TemplateModuleKernelMismatch();
    error TemplateModuleDomainMismatch();
    error TemplateModuleConfigMismatch();
    error TemplateDeployerKernelMismatch();
    error UnauthorizedDomainAdmitter(address caller);
    error AdmissionExpired(uint256 expiry);
    error InvalidDomainAuthority(address authority);
    error SameDomainAuthority(address authority);
    error GlobalAuthorityRoleOverlap(address authority);
    error DomainAuthorityInUse(address authority);
    error BadRegistrarNonce(address registrar, uint256 expected, uint256 provided);
    error AdmissionDigestUsed(bytes32 digest);
    error InvalidRegistrarSignature(address registrar);
    error InvalidGuardianSignature(address guardian);
    error DomainAlreadyExists(bytes32 domainId);
    error UnknownDomain(bytes32 domainId);
    error UnauthorizedRegistrar(bytes32 domainId, address caller);
    error TemplateNotReproposable(bytes32 domainId, uint256 templateId, uint32 version);
    error TemplateNotProposed(bytes32 domainId, uint256 templateId, uint32 version);
    error TemplateProposalChanged();
    error TemplateProposalNonceChanged(uint64 expected, uint64 actual);
    error InvalidTemplateChild();
    error TemplateNotActive(bytes32 domainId, uint256 templateId, uint32 version);
    error Reentrancy();
    error KernelHalted();
    error DomainNotActive(bytes32 domainId, uint256 activeAt);
    error DomainPaused(bytes32 domainId);
    error InvalidLauncher();
    error UnauthorizedLauncher(address launcher, address caller);
    error InvalidTokenAdmin();
    error InvalidFeeAdmin();
    error InvalidBeneficiary();
    error InvalidPredictedToken();
    error InvalidDeployedToken(address token);
    error EmptyNameOrSymbol();
    error TemplateNotActivated(bytes32 domainId, uint256 templateId, uint32 version);
    error LaunchDataTooLong(uint256 supplied, uint256 maximum);
    error LaunchDataNotAllowed();
    error ModuleCodeChanged(address module);
    error DeployerCodeChanged(address tokenDeployer);
    error CreationCodeChanged(bytes32 expected, bytes32 actual);
    error LaunchAlreadyUsed(bytes32 commitment);
    error TokenAddressMismatch(address expected, address actual);
    error ConfigEchoMismatch(bytes32 expected, bytes32 actual);
    error DuplicateToken(address token);
    error UnauthorizedGuardian(bytes32 domainId, address caller);
    error UnauthorizedHaltAuthority(address caller);
    error AlreadyHalted();

    address public immutable DOMAIN_ADMITTER;
    address public immutable HALT_AUTHORITY;
    bytes32 public immutable DOMAIN_SEPARATOR;
    bytes32 public immutable genesisConfigHash;

    mapping(DomainId => Domain) private _domains;
    mapping(address => bool) public authorityUsed;
    mapping(bytes32 => bool) public usedAdmissionDigest;
    mapping(address => uint256) public registrarNonce;
    mapping(DomainId => mapping(TemplateId => mapping(Version => TemplateStatus))) private
        _templateStatus;
    mapping(DomainId => mapping(TemplateId => mapping(Version => PendingProposal))) private
        _pendingProposals;
    mapping(DomainId => mapping(TemplateId => mapping(Version => uint64))) private
        _templateProposalNonces;
    mapping(DomainId => mapping(TemplateId => mapping(Version => ActivatedTemplate))) private
        _activatedTemplates;
    mapping(bytes32 => bool) public usedCommitments;
    mapping(address => LaunchRecord) private _launchRecords;
    mapping(uint256 => address) public tokenByLaunch;

    bool public halted;
    uint256 public launchCount;
    uint256 private _lock = 1;

    event DomainAdmitted(
        DomainId indexed domainId,
        address indexed registrar,
        address indexed guardian,
        bytes32 metadataHash,
        uint64 activeAt
    );
    event TemplateProposed(
        DomainId indexed domainId,
        TemplateId indexed templateId,
        Version indexed version,
        uint64 proposalNonce,
        bytes32 proposalHash,
        address proposer,
        address module,
        address tokenDeployer,
        bytes32 moduleCodeHash,
        bytes32 deployerCodeHash,
        bytes32 creationCodeHash,
        bytes32 inputSchemaHash,
        uint32 maxLaunchDataLen,
        bytes32 configHash,
        bytes32 manifestHash
    );
    event TemplateProposalCancelled(
        DomainId indexed domainId,
        TemplateId indexed templateId,
        Version indexed version,
        uint64 proposalNonce,
        bytes32 proposalHash,
        address by
    );
    event TemplateActivated(
        DomainId indexed domainId,
        TemplateId indexed templateId,
        Version indexed version,
        uint64 proposalNonce,
        bytes32 proposalHash,
        address guardian,
        address module,
        address tokenDeployer,
        bytes32 creationCodeHash,
        bytes32 inputSchemaHash,
        bytes32 configHash,
        bytes32 manifestHash
    );
    event TemplateDeprecated(
        DomainId indexed domainId,
        TemplateId indexed templateId,
        Version indexed version,
        address by
    );
    event DomainPause(DomainId indexed domainId, bool paused);
    event Halted();
    event GenesisSealed(bytes32 genesisConfigHash);
    event Launched(
        uint256 indexed launchId,
        address indexed token,
        address indexed launcher,
        DomainId domainId,
        TemplateId templateId,
        Version version,
        address module,
        address tokenDeployer,
        bytes32 poolId,
        uint256 positionId,
        bytes32 configHash,
        bytes32 manifestHash,
        bytes32 metadataHash,
        bytes32 launchDataHash
    );

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(
        address domainAdmitter_,
        address haltAuthority_,
        GenesisDomain memory genesis,
        GenesisTemplate[2] memory templates
    ) {
        if (domainAdmitter_ == address(0) || haltAuthority_ == address(0)) {
            revert InvalidGlobalAuthority();
        }
        if (domainAdmitter_ == haltAuthority_) {
            revert GlobalAuthorityOverlap(domainAdmitter_);
        }

        DOMAIN_ADMITTER = domainAdmitter_;
        HALT_AUTHORITY = haltAuthority_;
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this)
            )
        );

        _installGenesisDomain(domainAdmitter_, haltAuthority_, genesis);
        if (
            TemplateId.unwrap(templates[0].id) != TemplateId.unwrap(DEGEN_WETH)
                || TemplateId.unwrap(templates[1].id) != TemplateId.unwrap(DEGEN_SPY)
        ) {
            revert InvalidGenesisTemplateSet();
        }
        if (templates[0].config.module == templates[1].config.module) {
            revert DuplicateGenesisModule();
        }
        _installGenesisTemplate(genesis.id, templates[0]);
        _installGenesisTemplate(genesis.id, templates[1]);

        bytes32 sealedHash =
            keccak256(abi.encode(domainAdmitter_, haltAuthority_, genesis, templates));
        genesisConfigHash = sealedHash;
        emit GenesisSealed(sealedHash);
    }

    function admitDomain(
        address registrar,
        address guardian,
        uint256 nonce,
        bytes32 domainMetadataHash,
        uint256 expiry,
        bytes calldata registrarSig,
        bytes calldata guardianSig
    ) external returns (DomainId id) {
        if (msg.sender != DOMAIN_ADMITTER) {
            revert UnauthorizedDomainAdmitter(msg.sender);
        }
        if (block.timestamp > expiry) revert AdmissionExpired(expiry);
        if (registrar == address(0)) revert InvalidDomainAuthority(registrar);
        if (guardian == address(0)) revert InvalidDomainAuthority(guardian);
        if (registrar == guardian) revert SameDomainAuthority(registrar);
        if (registrar == DOMAIN_ADMITTER || registrar == HALT_AUTHORITY) {
            revert GlobalAuthorityRoleOverlap(registrar);
        }
        if (guardian == DOMAIN_ADMITTER || guardian == HALT_AUTHORITY) {
            revert GlobalAuthorityRoleOverlap(guardian);
        }

        bytes32 digest = admissionDigest(registrar, guardian, nonce, domainMetadataHash, expiry);
        if (usedAdmissionDigest[digest]) revert AdmissionDigestUsed(digest);

        uint256 expectedNonce = registrarNonce[registrar];
        if (nonce != expectedNonce) {
            revert BadRegistrarNonce(registrar, expectedNonce, nonce);
        }
        if (authorityUsed[registrar]) revert DomainAuthorityInUse(registrar);
        if (authorityUsed[guardian]) revert DomainAuthorityInUse(guardian);
        if (!registrar.isValidSignatureNow(digest, registrarSig)) {
            revert InvalidRegistrarSignature(registrar);
        }
        if (!guardian.isValidSignatureNow(digest, guardianSig)) {
            revert InvalidGuardianSignature(guardian);
        }

        id = domainIdFor(registrar, guardian, nonce);
        if (_domains[id].exists) revert DomainAlreadyExists(DomainId.unwrap(id));

        uint64 activeAt = (block.timestamp + DOMAIN_ADMISSION_DELAY).toUint64();
        _domains[id] = Domain({
            registrar: registrar,
            guardian: guardian,
            metadataHash: domainMetadataHash,
            activeAt: activeAt,
            paused: false,
            exists: true
        });
        authorityUsed[registrar] = true;
        authorityUsed[guardian] = true;
        usedAdmissionDigest[digest] = true;
        registrarNonce[registrar] = nonce + 1;

        emit DomainAdmitted(id, registrar, guardian, domainMetadataHash, activeAt);
    }

    function admissionDigest(
        address registrar,
        address guardian,
        uint256 nonce,
        bytes32 domainMetadataHash,
        uint256 expiry
    ) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(ADMISSION_TYPEHASH, registrar, guardian, nonce, domainMetadataHash, expiry)
        );
        return keccak256(abi.encodePacked(bytes2(0x1901), DOMAIN_SEPARATOR, structHash));
    }

    function domainIdFor(address registrar, address guardian, uint256 nonce)
        public
        view
        returns (DomainId)
    {
        return DomainId.wrap(keccak256(abi.encode(registrar, guardian, nonce, block.chainid)));
    }

    function getDomain(DomainId id) external view returns (Domain memory) {
        return _domains[id];
    }

    function proposeTemplate(
        DomainId domainId,
        TemplateId templateId,
        Version version,
        TemplateProposal calldata proposal
    ) external returns (uint64 proposalNonce, bytes32 proposalHash) {
        _requireRegistrar(domainId);
        TemplateStatus status = _templateStatus[domainId][templateId][version];
        if (status != TemplateStatus.NONE && status != TemplateStatus.PROPOSED) {
            revert TemplateNotReproposable(
                DomainId.unwrap(domainId), TemplateId.unwrap(templateId), Version.unwrap(version)
            );
        }

        _validateTemplateProposal(domainId, proposal);
        proposalNonce = ++_templateProposalNonces[domainId][templateId][version];
        proposalHash = hashTemplateProposal(
            domainId, templateId, version, proposalNonce, msg.sender, proposal
        );
        _templateStatus[domainId][templateId][version] = TemplateStatus.PROPOSED;
        _pendingProposals[domainId][templateId][version] = PendingProposal({
            proposalHash: proposalHash, proposalNonce: proposalNonce, proposer: msg.sender
        });

        emit TemplateProposed(
            domainId,
            templateId,
            version,
            proposalNonce,
            proposalHash,
            msg.sender,
            proposal.module,
            proposal.tokenDeployer,
            proposal.moduleCodeHash,
            proposal.deployerCodeHash,
            proposal.creationCodeHash,
            proposal.inputSchemaHash,
            proposal.maxLaunchDataLen,
            proposal.configHash,
            proposal.manifestHash
        );
    }

    function approveTemplate(
        DomainId domainId,
        TemplateId templateId,
        Version version,
        uint64 expectedNonce,
        bytes32 expectedHash,
        TemplateProposal calldata proposal
    ) external {
        _requireGuardian(domainId);
        if (_templateStatus[domainId][templateId][version] != TemplateStatus.PROPOSED) {
            revert TemplateNotProposed(
                DomainId.unwrap(domainId), TemplateId.unwrap(templateId), Version.unwrap(version)
            );
        }

        PendingProposal memory pending = _pendingProposals[domainId][templateId][version];
        if (pending.proposalNonce != expectedNonce) {
            revert TemplateProposalNonceChanged(pending.proposalNonce, expectedNonce);
        }
        if (pending.proposer != _domains[domainId].registrar) revert TemplateProposalChanged();
        bytes32 derivedHash = hashTemplateProposal(
            domainId, templateId, version, expectedNonce, pending.proposer, proposal
        );
        if (pending.proposalHash != expectedHash || expectedHash != derivedHash) {
            revert TemplateProposalChanged();
        }
        _validateTemplateProposal(domainId, proposal);

        _templateStatus[domainId][templateId][version] = TemplateStatus.ACTIVATED;
        _activatedTemplates[domainId][templateId][version] = ActivatedTemplate({
            module: proposal.module,
            tokenDeployer: proposal.tokenDeployer,
            moduleCodeHash: proposal.moduleCodeHash,
            deployerCodeHash: proposal.deployerCodeHash,
            creationCodeHash: proposal.creationCodeHash,
            inputSchemaHash: proposal.inputSchemaHash,
            maxLaunchDataLen: proposal.maxLaunchDataLen,
            configHash: proposal.configHash,
            manifestHash: proposal.manifestHash
        });
        delete _pendingProposals[domainId][templateId][version];

        emit TemplateActivated(
            domainId,
            templateId,
            version,
            expectedNonce,
            expectedHash,
            msg.sender,
            proposal.module,
            proposal.tokenDeployer,
            proposal.creationCodeHash,
            proposal.inputSchemaHash,
            proposal.configHash,
            proposal.manifestHash
        );
    }

    function cancelTemplateProposal(
        DomainId domainId,
        TemplateId templateId,
        Version version,
        uint64 expectedNonce
    ) external {
        _requireRegistrarOrGuardian(domainId);
        if (_templateStatus[domainId][templateId][version] != TemplateStatus.PROPOSED) {
            revert TemplateNotProposed(
                DomainId.unwrap(domainId), TemplateId.unwrap(templateId), Version.unwrap(version)
            );
        }

        PendingProposal memory pending = _pendingProposals[domainId][templateId][version];
        if (pending.proposalNonce != expectedNonce) {
            revert TemplateProposalNonceChanged(pending.proposalNonce, expectedNonce);
        }
        _templateStatus[domainId][templateId][version] = TemplateStatus.NONE;
        delete _pendingProposals[domainId][templateId][version];
        emit TemplateProposalCancelled(
            domainId, templateId, version, pending.proposalNonce, pending.proposalHash, msg.sender
        );
    }

    function deprecateTemplate(DomainId domainId, TemplateId templateId, Version version) external {
        _requireRegistrarOrGuardian(domainId);
        if (_templateStatus[domainId][templateId][version] != TemplateStatus.ACTIVATED) {
            revert TemplateNotActive(
                DomainId.unwrap(domainId), TemplateId.unwrap(templateId), Version.unwrap(version)
            );
        }

        _templateStatus[domainId][templateId][version] = TemplateStatus.DEPRECATED;
        emit TemplateDeprecated(domainId, templateId, version, msg.sender);
    }

    function launch(LaunchRequest calldata request)
        external
        nonReentrant
        returns (LaunchRecord memory record)
    {
        if (halted) revert KernelHalted();

        Domain storage domain = _domains[request.domainId];
        if (!domain.exists) revert UnknownDomain(DomainId.unwrap(request.domainId));
        if (block.timestamp < domain.activeAt) {
            revert DomainNotActive(DomainId.unwrap(request.domainId), domain.activeAt);
        }
        if (domain.paused) revert DomainPaused(DomainId.unwrap(request.domainId));

        _validateLaunchRoles(request);

        if (
            _templateStatus[request.domainId][request.templateId][request.version]
                != TemplateStatus.ACTIVATED
        ) {
            revert TemplateNotActivated(
                DomainId.unwrap(request.domainId),
                TemplateId.unwrap(request.templateId),
                Version.unwrap(request.version)
            );
        }
        ActivatedTemplate memory template =
            _activatedTemplates[request.domainId][request.templateId][request.version];

        if (request.launchData.length > template.maxLaunchDataLen) {
            revert LaunchDataTooLong(request.launchData.length, template.maxLaunchDataLen);
        }
        if (template.inputSchemaHash == EMPTY_SCHEMA_HASH && request.launchData.length != 0) {
            revert LaunchDataNotAllowed();
        }

        if (template.module.codehash != template.moduleCodeHash) {
            revert ModuleCodeChanged(template.module);
        }
        if (template.tokenDeployer.codehash != template.deployerCodeHash) {
            revert DeployerCodeChanged(template.tokenDeployer);
        }
        bytes32 currentCreationCodeHash = ITokenDeployer(template.tokenDeployer).creationCodeHash();
        if (currentCreationCodeHash != template.creationCodeHash) {
            revert CreationCodeChanged(template.creationCodeHash, currentCreationCodeHash);
        }

        bytes32 commitment = launchCommitment(request);
        if (usedCommitments[commitment]) revert LaunchAlreadyUsed(commitment);
        usedCommitments[commitment] = true;

        address token = ITokenDeployer(template.tokenDeployer)
            .deploy(commitment, _tokenArgs(request, template.module));
        if (token != request.predictedToken) {
            revert TokenAddressMismatch(request.predictedToken, token);
        }
        if (token.code.length == 0) revert InvalidDeployedToken(token);

        LaunchResult memory result = ILaunchModule(template.module)
            .configure(_launchContext(request, template, commitment, token));
        if (result.configEcho != template.configHash) {
            revert ConfigEchoMismatch(template.configHash, result.configEcho);
        }
        if (_launchRecords[token].token != address(0)) revert DuplicateToken(token);

        uint256 launchId = ++launchCount;
        bytes32 launchMetadataHash = metadataHash(request);
        bytes32 launchDataHash = keccak256(request.launchData);
        record = LaunchRecord({
            launchId: launchId,
            token: token,
            launcher: request.launcher,
            tokenAdmin: request.tokenAdmin,
            feeAdmin: request.feeAdmin,
            beneficiary: request.beneficiary,
            domainId: request.domainId,
            templateId: request.templateId,
            version: request.version,
            module: template.module,
            tokenDeployer: template.tokenDeployer,
            poolId: result.poolId,
            positionId: result.positionId,
            configHash: template.configHash,
            manifestHash: template.manifestHash,
            metadataHash: launchMetadataHash,
            launchDataHash: launchDataHash,
            kernelVersion: KERNEL_VERSION
        });
        _launchRecords[token] = record;
        tokenByLaunch[launchId] = token;

        emit Launched(
            launchId,
            token,
            request.launcher,
            request.domainId,
            request.templateId,
            request.version,
            template.module,
            template.tokenDeployer,
            result.poolId,
            result.positionId,
            template.configHash,
            template.manifestHash,
            launchMetadataHash,
            launchDataHash
        );
    }

    function pauseDomain(DomainId domainId, bool paused) external {
        Domain storage domain = _domains[domainId];
        if (!domain.exists) revert UnknownDomain(DomainId.unwrap(domainId));
        if (msg.sender != domain.guardian) {
            revert UnauthorizedGuardian(DomainId.unwrap(domainId), msg.sender);
        }

        domain.paused = paused;
        emit DomainPause(domainId, paused);
    }

    function emergencyHalt() external {
        if (msg.sender != HALT_AUTHORITY) revert UnauthorizedHaltAuthority(msg.sender);
        if (halted) revert AlreadyHalted();

        halted = true;
        emit Halted();
    }

    function launchCommitment(LaunchRequest calldata request) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                request.domainId,
                request.templateId,
                request.version,
                request.launcher,
                request.tokenAdmin,
                request.feeAdmin,
                request.beneficiary,
                request.userSalt,
                metadataHash(request),
                keccak256(request.launchData)
            )
        );
    }

    function metadataHash(LaunchRequest calldata request) public pure returns (bytes32) {
        return
            keccak256(
                abi.encode(request.name, request.symbol, request.contractURI, request.imageURI)
            );
    }

    function launchRecord(address token) external view returns (LaunchRecord memory) {
        return _launchRecords[token];
    }

    function hashTemplateProposal(
        DomainId domainId,
        TemplateId templateId,
        Version version,
        uint64 proposalNonce,
        address proposer,
        TemplateProposal calldata proposal
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                block.chainid,
                address(this),
                domainId,
                templateId,
                version,
                proposalNonce,
                proposer,
                proposal
            )
        );
    }

    function templateStatus(DomainId domainId, TemplateId templateId, Version version)
        external
        view
        returns (TemplateStatus)
    {
        return _templateStatus[domainId][templateId][version];
    }

    function pendingProposal(DomainId domainId, TemplateId templateId, Version version)
        external
        view
        returns (PendingProposal memory)
    {
        return _pendingProposals[domainId][templateId][version];
    }

    function activatedTemplate(DomainId domainId, TemplateId templateId, Version version)
        external
        view
        returns (ActivatedTemplate memory)
    {
        return _activatedTemplates[domainId][templateId][version];
    }

    function _validateLaunchRoles(LaunchRequest calldata request) private view {
        if (request.launcher == address(0)) revert InvalidLauncher();
        if (msg.sender != request.launcher) {
            revert UnauthorizedLauncher(request.launcher, msg.sender);
        }
        if (request.tokenAdmin == address(0)) revert InvalidTokenAdmin();
        if (request.feeAdmin == address(0)) revert InvalidFeeAdmin();
        if (request.beneficiary == address(0)) revert InvalidBeneficiary();
        if (request.predictedToken == address(0)) revert InvalidPredictedToken();
        if (bytes(request.name).length == 0 || bytes(request.symbol).length == 0) {
            revert EmptyNameOrSymbol();
        }
    }

    function _tokenArgs(LaunchRequest calldata request, address module)
        private
        pure
        returns (TokenArgs memory)
    {
        return TokenArgs({
            name: request.name,
            symbol: request.symbol,
            module: module,
            tokenAdmin: request.tokenAdmin,
            contractURI: request.contractURI,
            imageURI: request.imageURI
        });
    }

    function _launchContext(
        LaunchRequest calldata request,
        ActivatedTemplate memory template,
        bytes32 commitment,
        address token
    ) private pure returns (LaunchContext memory) {
        return LaunchContext({
            domainId: request.domainId,
            templateId: request.templateId,
            version: request.version,
            commitment: commitment,
            token: token,
            launcher: request.launcher,
            tokenAdmin: request.tokenAdmin,
            feeAdmin: request.feeAdmin,
            beneficiary: request.beneficiary,
            metadataHash: metadataHash(request),
            inputSchemaHash: template.inputSchemaHash,
            launchData: request.launchData
        });
    }

    function _requireRegistrar(DomainId domainId) private view {
        Domain storage domain = _domains[domainId];
        if (!domain.exists) revert UnknownDomain(DomainId.unwrap(domainId));
        if (msg.sender != domain.registrar) {
            revert UnauthorizedRegistrar(DomainId.unwrap(domainId), msg.sender);
        }
    }

    function _requireGuardian(DomainId domainId) private view {
        Domain storage domain = _domains[domainId];
        if (!domain.exists) revert UnknownDomain(DomainId.unwrap(domainId));
        if (msg.sender != domain.guardian) {
            revert UnauthorizedGuardian(DomainId.unwrap(domainId), msg.sender);
        }
    }

    function _requireRegistrarOrGuardian(DomainId domainId) private view {
        Domain storage domain = _domains[domainId];
        if (!domain.exists) revert UnknownDomain(DomainId.unwrap(domainId));
        if (msg.sender != domain.registrar && msg.sender != domain.guardian) {
            revert UnauthorizedRegistrar(DomainId.unwrap(domainId), msg.sender);
        }
    }

    function _validateTemplateProposal(DomainId domainId, TemplateProposal calldata proposal)
        private
        view
    {
        if (
            proposal.module == address(0) || proposal.tokenDeployer == address(0)
                || proposal.module == proposal.tokenDeployer
                || proposal.module.codehash == bytes32(0)
                || proposal.tokenDeployer.codehash == bytes32(0)
        ) {
            revert InvalidTemplateChild();
        }
        if (proposal.module.codehash != proposal.moduleCodeHash) {
            revert ModuleCodeChanged(proposal.module);
        }
        if (proposal.tokenDeployer.codehash != proposal.deployerCodeHash) {
            revert DeployerCodeChanged(proposal.tokenDeployer);
        }
        ILaunchModule module = ILaunchModule(proposal.module);
        if (module.kernel() != address(this)) revert TemplateModuleKernelMismatch();
        if (DomainId.unwrap(module.domainId()) != DomainId.unwrap(domainId)) {
            revert TemplateModuleDomainMismatch();
        }
        if (module.configHash() != proposal.configHash) revert TemplateModuleConfigMismatch();
        if (ITokenDeployer(proposal.tokenDeployer).kernel() != address(this)) {
            revert TemplateDeployerKernelMismatch();
        }
        bytes32 actualCreationCodeHash = ITokenDeployer(proposal.tokenDeployer).creationCodeHash();
        if (actualCreationCodeHash != proposal.creationCodeHash) {
            revert CreationCodeChanged(proposal.creationCodeHash, actualCreationCodeHash);
        }
    }

    function _installGenesisDomain(
        address domainAdmitter_,
        address haltAuthority_,
        GenesisDomain memory genesis
    ) private {
        if (genesis.registrar == address(0)) {
            revert InvalidGenesisAuthority(genesis.registrar);
        }
        if (genesis.guardian == address(0)) revert InvalidGenesisAuthority(genesis.guardian);
        if (genesis.registrar == genesis.guardian) {
            revert DuplicateGenesisAuthority(genesis.registrar);
        }
        if (
            genesis.registrar == domainAdmitter_ || genesis.registrar == haltAuthority_
                || genesis.guardian == domainAdmitter_ || genesis.guardian == haltAuthority_
        ) {
            revert GlobalAuthorityRoleOverlap(genesis.registrar == domainAdmitter_
                    || genesis.registrar == haltAuthority_
                    ? genesis.registrar
                    : genesis.guardian);
        }

        DomainId derived = domainIdFor(genesis.registrar, genesis.guardian, 0);
        if (DomainId.unwrap(genesis.id) != DomainId.unwrap(derived)) {
            revert InvalidGenesisDomainId();
        }

        uint64 activeAt = block.timestamp.toUint64();
        _domains[derived] = Domain({
            registrar: genesis.registrar,
            guardian: genesis.guardian,
            metadataHash: genesis.metadataHash,
            activeAt: activeAt,
            paused: false,
            exists: true
        });
        authorityUsed[genesis.registrar] = true;
        authorityUsed[genesis.guardian] = true;
        emit DomainAdmitted(
            derived, genesis.registrar, genesis.guardian, genesis.metadataHash, activeAt
        );
    }

    function _installGenesisTemplate(DomainId domainId, GenesisTemplate memory genesis) private {
        if (Version.unwrap(genesis.version) != 1) revert InvalidGenesisVersion();
        ActivatedTemplate memory config = genesis.config;
        if (config.inputSchemaHash != EMPTY_SCHEMA_HASH || config.maxLaunchDataLen != 0) {
            revert InvalidGenesisSchema();
        }
        if (
            config.module == address(0) || config.tokenDeployer == address(0)
                || config.module == config.tokenDeployer
        ) {
            revert InvalidGenesisChild();
        }
        if (config.module.codehash != config.moduleCodeHash) revert GenesisModuleCodeMismatch();
        if (config.tokenDeployer.codehash != config.deployerCodeHash) {
            revert GenesisDeployerCodeMismatch();
        }
        if (ITokenDeployer(config.tokenDeployer).creationCodeHash() != config.creationCodeHash) {
            revert GenesisCreationCodeMismatch();
        }
        if (DomainId.unwrap(ILaunchModule(config.module).domainId()) != DomainId.unwrap(domainId)) {
            revert GenesisModuleDomainMismatch();
        }
        if (ILaunchModule(config.module).configHash() != config.configHash) {
            revert GenesisModuleConfigMismatch();
        }
        if (
            ILaunchModule(config.module).kernel() != address(this)
                || ITokenDeployer(config.tokenDeployer).kernel() != address(this)
        ) {
            revert ChildKernelMismatch();
        }

        _templateStatus[domainId][genesis.id][genesis.version] = TemplateStatus.ACTIVATED;
        _activatedTemplates[domainId][genesis.id][genesis.version] = config;
        emit TemplateActivated(
            domainId,
            genesis.id,
            genesis.version,
            0,
            bytes32(0),
            address(0),
            config.module,
            config.tokenDeployer,
            config.creationCodeHash,
            config.inputSchemaHash,
            config.configHash,
            config.manifestHash
        );
    }
}
