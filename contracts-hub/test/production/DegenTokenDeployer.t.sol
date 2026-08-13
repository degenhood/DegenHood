// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {DegenToken} from "../../src/production/ProductionDegenToken.sol";
import {DegenTokenDeployer} from "../../src/production/ProductionDegenTokenDeployer.sol";
import {TokenArgs} from "../../src/production/ProductionLaunchTypes.sol";

contract DegenTokenModuleBindingMock {
    address public immutable poolManager;
    address public immutable positionManager;
    address public immutable lpLocker;

    constructor(address poolManager_, address positionManager_, address lpLocker_) {
        poolManager = poolManager_;
        positionManager = positionManager_;
        lpLocker = lpLocker_;
    }
}

contract DegenTokenDeployerTest is Test {
    string private constant METADATA_URI =
        "ipfs://f01701220aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    string private constant IMAGE_URI =
        "ipfs://f01701220bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    address private kernel;
    address private module;
    address private tokenAdmin;
    address private poolManager;
    address private positionManager;
    address private lpLocker;
    DegenToken private implementation;
    DegenTokenDeployer private deployer;

    function setUp() public {
        kernel = makeAddr("kernel");
        tokenAdmin = makeAddr("tokenAdmin");
        poolManager = makeAddr("poolManager");
        positionManager = makeAddr("positionManager");
        lpLocker = makeAddr("lpLocker");
        module = address(new DegenTokenModuleBindingMock(poolManager, positionManager, lpLocker));
        implementation = new DegenToken();
        deployer = new DegenTokenDeployer(kernel, address(implementation));
    }

    function testDeployMatchesPredictionAndInitializesClone() public {
        bytes32 salt = keccak256("launch");
        TokenArgs memory args = _args(METADATA_URI, IMAGE_URI);
        address predicted = deployer.predict(salt, args);

        vm.prank(kernel);
        address deployed = deployer.deploy(salt, args);
        DegenToken token = DegenToken(deployed);

        assertEq(deployed, predicted);
        assertEq(token.balanceOf(module), 100_000_000_000 ether);
        assertEq(token.tokenAdmin(), tokenAdmin);
        assertEq(token.poolManager(), poolManager);
        assertEq(token.positionManager(), positionManager);
        assertEq(token.launchModule(), module);
        assertEq(token.lpLocker(), lpLocker);
        assertEq(token.metadataDigest(), bytes32(uint256(type(uint256).max) / 0xff * 0xaa));
        assertEq(token.imageDigest(), bytes32(uint256(type(uint256).max) / 0xff * 0xbb));
        assertEq(token.contractURI(), METADATA_URI);
        assertEq(token.extraMetadata("image"), IMAGE_URI);
    }

    function testCloneBytecodeIdenticalAcrossLaunches() public {
        TokenArgs memory firstArgs = _args(METADATA_URI, IMAGE_URI);
        TokenArgs memory secondArgs = _args(METADATA_URI, IMAGE_URI);
        secondArgs.name = "Second";
        secondArgs.symbol = "TWO";
        vm.startPrank(kernel);
        address first = deployer.deploy(keccak256("first"), firstArgs);
        address second = deployer.deploy(keccak256("second"), secondArgs);
        vm.stopPrank();

        assertEq(first.code.length, 45);
        assertEq(first.codehash, second.codehash);
        assertEq(first.code, second.code);
    }

    function testPredictionDependsOnSaltNotInitializerArguments() public {
        bytes32 salt = keccak256("same-salt");
        TokenArgs memory firstArgs = _args(METADATA_URI, IMAGE_URI);
        TokenArgs memory secondArgs = _args("", "");
        secondArgs.name = "Different";
        secondArgs.symbol = "DIFF";
        secondArgs.module = makeAddr("differentModule");
        secondArgs.tokenAdmin = makeAddr("differentAdmin");

        assertEq(deployer.predict(salt, firstArgs), deployer.predict(salt, secondArgs));
    }

    function testMinedSaltYieldsDe6Suffix() public view {
        TokenArgs memory args = _args(METADATA_URI, IMAGE_URI);
        bool found;
        for (uint256 i; i < 20_000; ++i) {
            address predicted = deployer.predict(bytes32(i), args);
            if (uint160(predicted) & 0xfff == 0xde6) {
                assertEq(uint160(predicted) & 0xfff, 0xde6);
                found = true;
                break;
            }
        }
        assertTrue(found, "salt search exhausted");
    }

    function testOnlyKernelCanDeploy() public {
        address stranger = makeAddr("stranger");
        vm.expectRevert(
            abi.encodeWithSelector(DegenTokenDeployer.UnauthorizedKernel.selector, stranger)
        );
        vm.prank(stranger);
        deployer.deploy(keccak256("salt"), _args(METADATA_URI, IMAGE_URI));
    }

    function testRejectsModuleWithoutStructuralBindings() public {
        TokenArgs memory args = _args(METADATA_URI, IMAGE_URI);
        args.module = makeAddr("unboundModule");
        vm.expectRevert(DegenTokenDeployer.InvalidModuleBinding.selector);
        vm.prank(kernel);
        deployer.deploy(keccak256("unbound"), args);
    }

    function testConstructorRejectsInvalidKernelOrImplementation() public {
        vm.expectRevert(DegenTokenDeployer.InvalidKernel.selector);
        new DegenTokenDeployer(address(0), address(implementation));

        vm.expectRevert(DegenTokenDeployer.InvalidImplementation.selector);
        new DegenTokenDeployer(kernel, address(0));

        vm.expectRevert(DegenTokenDeployer.InvalidImplementation.selector);
        new DegenTokenDeployer(kernel, makeAddr("noCode"));
    }

    function testImplementationRemainsUninitializableThroughDeployer() public view {
        assertTrue(implementation.initialised());
        assertTrue(implementation.metadataFrozen());
        assertEq(implementation.totalSupply(), 0);
    }

    function testEmptyUrisInitializeZeroDigestsAndResolveEmpty() public {
        vm.prank(kernel);
        DegenToken token = DegenToken(deployer.deploy(keccak256("empty"), _args("", "")));
        assertEq(token.metadataDigest(), bytes32(0));
        assertEq(token.imageDigest(), bytes32(0));
        assertEq(token.contractURI(), "");
        assertEq(token.extraMetadata("image"), "");
    }

    function testRejectsArbitraryOrMalformedMetadataUris() public {
        _expectInvalidUri("https://example.com/metadata.json");
        _expectInvalidUri("ipfs://QmYwAPJzv5CZsnAzt8auVZRnGi2C19eVPnK7kCwYH7d8xo");
        _expectInvalidUri(
            "ipfs://f01551220aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        );
        _expectInvalidUri(
            "ipfs://f01701220AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        );
        _expectInvalidUri(
            "ipfs://f01701220aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaag"
        );
        _expectInvalidUri("ipfs://f01701220aa");
    }

    function testCreationCodeHashPinsImplementationBoundCloneCode() public view {
        bytes memory initCode = abi.encodePacked(
            hex"3d602d80600a3d3981f3",
            hex"363d3d373d3d3d363d73",
            address(implementation),
            hex"5af43d82803e903d91602b57fd5bf3"
        );
        assertEq(initCode.length, 55);
        assertEq(deployer.creationCodeHash(), keccak256(initCode));
    }

    function testReportsMeasuredCloneAndInitializeGas() public {
        uint256 gasBefore = gasleft();
        vm.prank(kernel);
        deployer.deploy(keccak256("gas"), _args(METADATA_URI, IMAGE_URI));
        emit log_named_uint("clone + initialize gas", gasBefore - gasleft());
    }

    function _expectInvalidUri(string memory uri) private {
        vm.expectRevert(DegenTokenDeployer.InvalidCanonicalIpfsUri.selector);
        vm.prank(kernel);
        deployer.deploy(keccak256(bytes(uri)), _args(uri, IMAGE_URI));
    }

    function _args(string memory metadataUri, string memory imageUri)
        private
        view
        returns (TokenArgs memory)
    {
        return TokenArgs({
            name: "Degen Test",
            symbol: "DTEST",
            module: module,
            tokenAdmin: tokenAdmin,
            contractURI: metadataUri,
            imageURI: imageUri
        });
    }
}
