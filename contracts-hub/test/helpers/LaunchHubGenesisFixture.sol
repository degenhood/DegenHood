// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {
    ActivatedTemplate,
    DomainId,
    GenesisDomain,
    GenesisTemplate,
    LaunchContext,
    LaunchHub,
    LaunchResult,
    TemplateId,
    Version
} from "../../src/LaunchHub.sol";
import {DegenHoodTokenDeployer} from "../../src/deployers/DegenHoodTokenDeployer.sol";

contract GenesisModuleFixture {
    address public immutable kernel;
    DomainId public immutable domainId;
    bytes32 public immutable configHash;

    constructor(address kernel_, DomainId domainId_, bytes32 configHash_) {
        kernel = kernel_;
        domainId = domainId_;
        configHash = configHash_;
    }

    function configure(LaunchContext calldata context)
        external
        view
        returns (LaunchResult memory result)
    {
        require(msg.sender == kernel, "ONLY_KERNEL");
        result = LaunchResult({
            poolId: keccak256(abi.encode(context.token)),
            positionId: uint256(uint160(context.token)),
            configEcho: configHash
        });
    }
}

contract LaunchHubCreateFixture {
    function deploy(
        address domainAdmitter,
        address haltAuthority,
        GenesisDomain memory genesis,
        GenesisTemplate[3] memory templates
    ) external returns (LaunchHub hub) {
        hub = new LaunchHub(domainAdmitter, haltAuthority, genesis, templates);
    }
}

abstract contract LaunchHubGenesisFixture is Test {
    bytes32 internal constant DEGEN_V4_CONFIG_HASH = keccak256("degen-v1-uniswap-v4-config");
    bytes32 internal constant DEGEN_V3_CONFIG_HASH = keccak256("degen-v1-uniswap-v3-config");
    bytes32 internal constant DEGEN_SPY_V4_CONFIG_HASH =
        keccak256("degen-v1-spy-uniswap-v4-config");
    bytes32 internal constant DEGEN_V4_MANIFEST_HASH = keccak256("degen-v1-uniswap-v4-manifest");
    bytes32 internal constant DEGEN_V3_MANIFEST_HASH = keccak256("degen-v1-uniswap-v3-manifest");
    bytes32 internal constant DEGEN_SPY_V4_MANIFEST_HASH =
        keccak256("degen-v1-spy-uniswap-v4-manifest");

    struct GenesisFixture {
        LaunchHub hub;
        LaunchHubCreateFixture creator;
        DomainId domainId;
        GenesisDomain domain;
        GenesisTemplate[3] templates;
        address predictedHub;
    }

    function _deployGenesisHub(
        address domainAdmitter,
        address haltAuthority,
        address registrar,
        address guardian
    ) internal returns (GenesisFixture memory fixture) {
        fixture = _prepareGenesis(domainAdmitter, haltAuthority, registrar, guardian);
        fixture.hub = fixture.creator
        .deploy(domainAdmitter, haltAuthority, fixture.domain, fixture.templates);
        assertEq(address(fixture.hub), fixture.predictedHub, "fixture prediction");
    }

    function _prepareGenesis(address, address, address registrar, address guardian)
        internal
        returns (GenesisFixture memory fixture)
    {
        fixture.creator = new LaunchHubCreateFixture();
        fixture.predictedHub = vm.computeCreateAddress(
            address(fixture.creator), vm.getNonce(address(fixture.creator))
        );
        fixture.domainId =
            DomainId.wrap(keccak256(abi.encode(registrar, guardian, uint256(0), block.chainid)));
        fixture.domain = GenesisDomain({
            id: fixture.domainId,
            registrar: registrar,
            guardian: guardian,
            metadataHash: keccak256("degenhood-genesis")
        });

        GenesisModuleFixture degenV4Module =
            new GenesisModuleFixture(fixture.predictedHub, fixture.domainId, DEGEN_V4_CONFIG_HASH);
        GenesisModuleFixture degenV3Module =
            new GenesisModuleFixture(fixture.predictedHub, fixture.domainId, DEGEN_V3_CONFIG_HASH);
        GenesisModuleFixture degenSpyV4Module = new GenesisModuleFixture(
            fixture.predictedHub, fixture.domainId, DEGEN_SPY_V4_CONFIG_HASH
        );
        DegenHoodTokenDeployer tokenDeployer = new DegenHoodTokenDeployer(fixture.predictedHub);
        bytes32 creationCodeHash = tokenDeployer.creationCodeHash();

        fixture.templates[0] = GenesisTemplate({
            id: TemplateId.wrap(2),
            version: Version.wrap(1),
            config: _templateConfig(
                address(degenV4Module),
                address(tokenDeployer),
                creationCodeHash,
                DEGEN_V4_CONFIG_HASH,
                DEGEN_V4_MANIFEST_HASH
            )
        });
        fixture.templates[1] = GenesisTemplate({
            id: TemplateId.wrap(3),
            version: Version.wrap(1),
            config: _templateConfig(
                address(degenV3Module),
                address(tokenDeployer),
                creationCodeHash,
                DEGEN_V3_CONFIG_HASH,
                DEGEN_V3_MANIFEST_HASH
            )
        });
        fixture.templates[2] = GenesisTemplate({
            id: TemplateId.wrap(4),
            version: Version.wrap(1),
            config: _templateConfig(
                address(degenSpyV4Module),
                address(tokenDeployer),
                creationCodeHash,
                DEGEN_SPY_V4_CONFIG_HASH,
                DEGEN_SPY_V4_MANIFEST_HASH
            )
        });
    }

    function _templateConfig(
        address module,
        address tokenDeployer,
        bytes32 creationCodeHash,
        bytes32 configHash,
        bytes32 manifestHash
    ) private view returns (ActivatedTemplate memory) {
        return ActivatedTemplate({
            module: module,
            tokenDeployer: tokenDeployer,
            moduleCodeHash: module.codehash,
            deployerCodeHash: tokenDeployer.codehash,
            creationCodeHash: creationCodeHash,
            inputSchemaHash: keccak256("EMPTY"),
            maxLaunchDataLen: 0,
            configHash: configHash,
            manifestHash: manifestHash
        });
    }
}
