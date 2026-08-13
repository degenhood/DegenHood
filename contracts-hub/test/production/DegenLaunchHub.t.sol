// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {DegenHoodTokenDeployer} from "../../src/deployers/DegenHoodTokenDeployer.sol";
import {DegenLaunchHub} from "../../src/production/ProductionDegenLaunchHub.sol";
import {
    ActivatedTemplate,
    DomainId,
    GenesisDomain,
    GenesisTemplate,
    LaunchContext,
    LaunchRecord,
    LaunchRequest,
    LaunchResult,
    TemplateId,
    TemplateStatus,
    Version
} from "../../src/production/ProductionLaunchTypes.sol";

contract ProductionModuleFixture {
    address public immutable kernel;
    DomainId public immutable domainId;
    bytes32 public immutable configHash;

    constructor(address kernel_, DomainId domainId_, bytes32 configHash_) {
        kernel = kernel_;
        domainId = domainId_;
        configHash = configHash_;
    }

    function configure(LaunchContext calldata context) external view returns (LaunchResult memory) {
        require(msg.sender == kernel, "ONLY_KERNEL");
        return LaunchResult({
            poolId: keccak256(abi.encode(context.token)),
            positionId: uint256(uint160(context.token)),
            configEcho: configHash
        });
    }
}

contract DegenLaunchHubCreateFixture {
    function deploy(
        address admitter,
        address haltAuthority,
        GenesisDomain memory genesis,
        GenesisTemplate[2] memory templates
    ) external returns (DegenLaunchHub) {
        return new DegenLaunchHub(admitter, haltAuthority, genesis, templates);
    }
}

contract DegenLaunchHubTest is Test {
    bytes32 private constant WETH_CONFIG = keccak256("degen-production-weth");
    bytes32 private constant SPY_CONFIG = keccak256("degen-production-spy");

    DegenLaunchHub private hub;
    DegenHoodTokenDeployer private tokenDeployer;
    DomainId private domain;
    address private registrar;
    address private guardian;
    address private haltAuthority;
    address private launcher;
    address private wethModule;

    function setUp() public {
        registrar = makeAddr("registrar");
        guardian = makeAddr("guardian");
        haltAuthority = makeAddr("haltAuthority");
        launcher = makeAddr("launcher");
        DegenLaunchHubCreateFixture creator = new DegenLaunchHubCreateFixture();
        address predicted = vm.computeCreateAddress(address(creator), vm.getNonce(address(creator)));
        domain =
            DomainId.wrap(keccak256(abi.encode(registrar, guardian, uint256(0), block.chainid)));
        GenesisDomain memory genesis = GenesisDomain({
            id: domain,
            registrar: registrar,
            guardian: guardian,
            metadataHash: keccak256("degen-production-genesis")
        });
        ProductionModuleFixture weth = new ProductionModuleFixture(predicted, domain, WETH_CONFIG);
        ProductionModuleFixture spy = new ProductionModuleFixture(predicted, domain, SPY_CONFIG);
        wethModule = address(weth);
        tokenDeployer = new DegenHoodTokenDeployer(predicted);
        bytes32 creationHash = tokenDeployer.creationCodeHash();
        GenesisTemplate[2] memory templates;
        templates[0] = GenesisTemplate({
            id: TemplateId.wrap(1),
            version: Version.wrap(1),
            config: _config(address(weth), creationHash, WETH_CONFIG)
        });
        templates[1] = GenesisTemplate({
            id: TemplateId.wrap(2),
            version: Version.wrap(1),
            config: _config(address(spy), creationHash, SPY_CONFIG)
        });
        hub = creator.deploy(makeAddr("admitter"), haltAuthority, genesis, templates);
        assertEq(address(hub), predicted);
    }

    function testIdentityAndExactGenesisNamespace() public view {
        assertEq(hub.KERNEL_VERSION(), keccak256("DegenLaunchHub/1.0.0"));
        assertEq(
            hub.DOMAIN_SEPARATOR(),
            keccak256(
                abi.encode(
                    keccak256(
                        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                    ),
                    keccak256("DegenLaunchHub"),
                    keccak256("1"),
                    block.chainid,
                    address(hub)
                )
            )
        );
        assertEq(TemplateId.unwrap(hub.DEGEN_WETH()), 1);
        assertEq(TemplateId.unwrap(hub.DEGEN_SPY()), 2);
        assertEq(
            uint8(hub.templateStatus(domain, TemplateId.wrap(1), Version.wrap(1))),
            uint8(TemplateStatus.ACTIVATED)
        );
        assertEq(
            uint8(hub.templateStatus(domain, TemplateId.wrap(2), Version.wrap(1))),
            uint8(TemplateStatus.ACTIVATED)
        );
        assertEq(
            uint8(hub.templateStatus(domain, TemplateId.wrap(3), Version.wrap(1))),
            uint8(TemplateStatus.NONE)
        );
    }

    function testImmediateZeroValueLaunchRecordsCleanProvenance() public {
        LaunchRequest memory request = _request();
        vm.prank(launcher);
        LaunchRecord memory record = hub.launch(request);

        assertEq(record.token, request.predictedToken);
        assertEq(record.module, wethModule);
        assertEq(TemplateId.unwrap(record.templateId), 1);
        assertEq(Version.unwrap(record.version), 1);
        assertEq(record.kernelVersion, keccak256("DegenLaunchHub/1.0.0"));
        assertEq(hub.launchCount(), 1);
    }

    function testLaunchIsNonpayableAndEmergencyHaltIsOneWay() public {
        LaunchRequest memory request = _request();
        vm.deal(launcher, 1 ether);
        vm.prank(launcher);
        (bool paid,) = address(hub).call{value: 1}(abi.encodeCall(DegenLaunchHub.launch, (request)));
        assertFalse(paid);

        vm.prank(haltAuthority);
        hub.emergencyHalt();
        vm.prank(launcher);
        vm.expectRevert(DegenLaunchHub.KernelHalted.selector);
        hub.launch(request);
    }

    function _request() private returns (LaunchRequest memory request) {
        request = LaunchRequest({
            domainId: domain,
            templateId: TemplateId.wrap(1),
            version: Version.wrap(1),
            launcher: launcher,
            tokenAdmin: makeAddr("tokenAdmin"),
            feeAdmin: makeAddr("feeAdmin"),
            beneficiary: makeAddr("beneficiary"),
            userSalt: keccak256("clean-launch"),
            name: "Degen Token",
            symbol: "DEGEN",
            contractURI: "ipfs://contract",
            imageURI: "ipfs://image",
            predictedToken: address(0),
            launchData: bytes("")
        });
        bytes32 commitment = hub.launchCommitment(request);
        request.predictedToken = tokenDeployer.predict(
            commitment,
            DegenHoodTokenDeployer.TokenArgs({
                name: request.name,
                symbol: request.symbol,
                module: wethModule,
                tokenAdmin: request.tokenAdmin,
                contractURI: request.contractURI,
                imageURI: request.imageURI
            })
        );
    }

    function _config(address module, bytes32 creationHash, bytes32 configHash)
        private
        view
        returns (ActivatedTemplate memory)
    {
        return ActivatedTemplate({
            module: module,
            tokenDeployer: address(tokenDeployer),
            moduleCodeHash: module.codehash,
            deployerCodeHash: address(tokenDeployer).codehash,
            creationCodeHash: creationHash,
            inputSchemaHash: keccak256("EMPTY"),
            maxLaunchDataLen: 0,
            configHash: configHash,
            manifestHash: keccak256(abi.encode(configHash, "manifest"))
        });
    }
}
