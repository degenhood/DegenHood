// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {
    ActivatedTemplate,
    DomainId,
    GenesisDomain,
    GenesisTemplate,
    LaunchContext,
    LaunchHubV2,
    LaunchResult,
    TemplateId,
    Version
} from "../../src/LaunchHubV2.sol";
import {DegenHoodTokenDeployer} from "../../src/deployers/DegenHoodTokenDeployer.sol";

contract GenesisV2ModuleFixture {
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

contract LaunchHubV2CreateFixture {
    function deploy(
        address domainAdmitter,
        address haltAuthority,
        GenesisDomain memory genesis,
        GenesisTemplate[2] memory templates
    ) external returns (LaunchHubV2 hub) {
        hub = new LaunchHubV2(domainAdmitter, haltAuthority, genesis, templates);
    }
}

abstract contract LaunchHubV2GenesisFixture is Test {
    bytes32 internal constant DEGEN_V2_CONFIG_HASH = keccak256("degen-v2-uniswap-v4-config");
    bytes32 internal constant DEGEN_SPY_V2_CONFIG_HASH =
        keccak256("degen-spy-v2-uniswap-v4-config");
    bytes32 internal constant DEGEN_V2_MANIFEST_HASH = keccak256("degen-v2-uniswap-v4-manifest");
    bytes32 internal constant DEGEN_SPY_V2_MANIFEST_HASH =
        keccak256("degen-spy-v2-uniswap-v4-manifest");

    struct GenesisV2Fixture {
        LaunchHubV2 hub;
        LaunchHubV2CreateFixture creator;
        DomainId domainId;
        GenesisDomain domain;
        GenesisTemplate[2] templates;
        address predictedHub;
    }

    function _deployGenesisV2Hub(
        address domainAdmitter,
        address haltAuthority,
        address registrar,
        address guardian
    ) internal returns (GenesisV2Fixture memory fixture) {
        fixture = _prepareGenesisV2(registrar, guardian);
        fixture.hub = fixture.creator
        .deploy(domainAdmitter, haltAuthority, fixture.domain, fixture.templates);
        assertEq(address(fixture.hub), fixture.predictedHub, "v2 fixture prediction");
    }

    function _prepareGenesisV2(address registrar, address guardian)
        internal
        returns (GenesisV2Fixture memory fixture)
    {
        fixture.creator = new LaunchHubV2CreateFixture();
        fixture.predictedHub = vm.computeCreateAddress(
            address(fixture.creator), vm.getNonce(address(fixture.creator))
        );
        fixture.domainId =
            DomainId.wrap(keccak256(abi.encode(registrar, guardian, uint256(0), block.chainid)));
        fixture.domain = GenesisDomain({
            id: fixture.domainId,
            registrar: registrar,
            guardian: guardian,
            metadataHash: keccak256("degenhood-v2-genesis")
        });

        GenesisV2ModuleFixture weth = new GenesisV2ModuleFixture(
            fixture.predictedHub, fixture.domainId, DEGEN_V2_CONFIG_HASH
        );
        GenesisV2ModuleFixture spy = new GenesisV2ModuleFixture(
            fixture.predictedHub, fixture.domainId, DEGEN_SPY_V2_CONFIG_HASH
        );
        DegenHoodTokenDeployer tokenDeployer = new DegenHoodTokenDeployer(fixture.predictedHub);
        bytes32 creationCodeHash = tokenDeployer.creationCodeHash();

        fixture.templates[0] = GenesisTemplate({
            id: TemplateId.wrap(2),
            version: Version.wrap(2),
            config: _templateConfig(
                address(weth),
                address(tokenDeployer),
                creationCodeHash,
                DEGEN_V2_CONFIG_HASH,
                DEGEN_V2_MANIFEST_HASH
            )
        });
        fixture.templates[1] = GenesisTemplate({
            id: TemplateId.wrap(4),
            version: Version.wrap(2),
            config: _templateConfig(
                address(spy),
                address(tokenDeployer),
                creationCodeHash,
                DEGEN_SPY_V2_CONFIG_HASH,
                DEGEN_SPY_V2_MANIFEST_HASH
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
