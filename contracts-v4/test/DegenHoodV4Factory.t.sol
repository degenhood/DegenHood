// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DegenHoodFeeLocker} from "../src/DegenHoodFeeLocker.sol";
import {DegenHoodTokenV4} from "../src/DegenHoodTokenV4.sol";
import {DegenHoodV4Factory} from "../src/DegenHoodV4Factory.sol";
import {DegenHoodV4Hook} from "../src/DegenHoodV4Hook.sol";
import {DegenHoodV4LpLocker} from "../src/DegenHoodV4LpLocker.sol";
import {IDegenHoodV4Factory} from "../src/interfaces/IDegenHoodV4Factory.sol";
import {IDegenHoodV4Hook} from "../src/interfaces/IDegenHoodV4Hook.sol";
import {IDegenHoodV4LpLocker} from "../src/interfaces/IDegenHoodV4LpLocker.sol";
import {DegenV4Fixture} from "./helpers/DegenV4Fixture.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

contract DegenHoodV4FactoryTest is DegenV4Fixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 private constant TEMPLATE_ID = 1;
    uint256 private constant SECOND_TEMPLATE_ID = 2;
    uint256 private constant STANDARD_SUPPLY = 100_000_000_000 ether;
    uint160 private constant VANITY_MASK = 0xFFF;
    uint160 private constant VANITY_SUFFIX = 0xDE6;
    int24 private constant INITIAL_TICK = -230_400;

    DegenHoodFeeLocker private feeLocker;
    DegenHoodV4Factory private factory;
    DegenHoodV4Hook private hook;
    DegenHoodV4LpLocker private lpLocker;
    address private weth;
    address private launcher = makeAddr("factoryLauncher");
    address private tokenAdmin = makeAddr("factoryTokenAdmin");
    address private feeAdmin = makeAddr("factoryFeeAdmin");
    address private beneficiary = makeAddr("factoryBeneficiary");
    address private operatingTreasury = makeAddr("factoryOperatingTreasury");
    address private tokenReserve = makeAddr("factoryTokenReserve");
    address private stranger = makeAddr("factoryStranger");

    IDegenHoodV4Factory.LaunchRequest private request;

    function setUp() public {
        _setUpV4Infrastructure();
        _setUpV4PositionManager();
        weth = Currency.unwrap(currency1);
        feeLocker = new DegenHoodFeeLocker(address(this), weth);
        factory = new DegenHoodV4Factory(
            address(manager), weth, operatingTreasury, tokenReserve, address(this)
        );
        (hook, lpLocker) = _deployAndApproveTemplate(TEMPLATE_ID);

        request = IDegenHoodV4Factory.LaunchRequest({
            name: "Degen Launch",
            symbol: "DLG",
            contractURI: "ipfs://contract-metadata",
            imageURI: "ipfs://token-image",
            launcher: launcher,
            tokenAdmin: tokenAdmin,
            feeAdmin: feeAdmin,
            beneficiary: beneficiary,
            templateId: TEMPLATE_ID,
            userSalt: bytes32(0)
        });
        request.userSalt = _mineSalt(request);
    }

    function test_launch_atomicallyBindsRolesPoolAndPermanentLiquidity() public {
        address predicted = factory.predictTokenAddress(request);
        vm.prank(launcher);
        IDegenHoodV4Factory.LaunchRecord memory record = factory.launch(request);

        assertEq(record.launchId, 1);
        assertEq(record.token, predicted);
        assertEq(record.launcher, launcher);
        assertEq(record.tokenAdmin, tokenAdmin);
        assertEq(record.feeAdmin, feeAdmin);
        assertEq(record.beneficiary, beneficiary);
        assertEq(record.operatingTreasury, operatingTreasury);
        assertEq(record.tokenReserve, tokenReserve);
        assertEq(record.templateId, TEMPLATE_ID);
        assertEq(record.hook, address(hook));
        assertEq(record.lpLocker, address(lpLocker));
        assertEq(record.feeLocker, address(feeLocker));
        assertEq(record.factoryVersion, factory.FACTORY_VERSION());
        assertEq(record.hookCodeHash, address(hook).codehash);
        assertEq(record.lockerCodeHash, address(lpLocker).codehash);

        DegenHoodTokenV4 token = DegenHoodTokenV4(record.token);
        assertEq(token.totalSupply(), STANDARD_SUPPLY);
        assertEq(token.tokenAdmin(), tokenAdmin);
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(Currency.unwrap(record.poolKey.currency0), record.token);
        assertEq(Currency.unwrap(record.poolKey.currency1), weth);
        assertEq(PoolId.unwrap(record.poolId), PoolId.unwrap(record.poolKey.toId()));
        assertEq(record.poolKey.tickSpacing, 200);
        assertEq(record.supply, STANDARD_SUPPLY);
        assertEq(record.lpFee, 7000);
        assertEq(record.permanentHookRate, 5000);
        assertEq(record.maximumTemporaryHookRate, 795_000);
        assertEq(record.launchFeeDuration, 30 seconds);
        assertEq(record.initialTick, -230_400);
        assertEq(record.upperTick, -120_000);
        assertEq(record.tickSpacing, 200);
        assertEq(factory.WETH(), weth);
        assertEq(factory.OPERATING_TREASURY(), operatingTreasury);
        assertEq(factory.TOKEN_RESERVE(), tokenReserve);

        IDegenHoodV4Hook.PoolConfig memory hookConfig = hook.getPoolConfig(record.poolId);
        IDegenHoodV4LpLocker.PositionConfig memory position =
            lpLocker.positionForToken(record.token);
        (uint160 sqrtPriceX96, int24 tick,, uint24 lpFee) = manager.getSlot0(record.poolId);
        assertEq(hookConfig.token, record.token);
        assertEq(hookConfig.beneficiary, beneficiary);
        assertEq(hookConfig.beneficiaryController, address(lpLocker));
        assertTrue(hookConfig.initialized);
        assertEq(position.beneficiary, beneficiary);
        assertEq(position.feeAdmin, feeAdmin);
        assertEq(position.poolSupply, STANDARD_SUPPLY);
        assertEq(position.positionId, record.positionId);
        assertEq(IERC721(address(positionManager)).ownerOf(record.positionId), address(lpLocker));
        assertEq(sqrtPriceX96, TickMath.getSqrtPriceAtTick(INITIAL_TICK));
        assertEq(tick, INITIAL_TICK);
        assertEq(lpFee, 7000);
    }

    function test_launch_requiresLauncherAndEveryPerTokenRole() public {
        vm.prank(stranger);
        vm.expectRevert(IDegenHoodV4Factory.UnauthorizedLauncher.selector);
        factory.launch(request);

        IDegenHoodV4Factory.LaunchRequest memory invalid = request;
        invalid.launcher = address(0);
        vm.expectRevert(IDegenHoodV4Factory.InvalidLauncher.selector);
        factory.launch(invalid);

        invalid = request;
        invalid.tokenAdmin = address(0);
        vm.prank(launcher);
        vm.expectRevert(IDegenHoodV4Factory.InvalidTokenAdmin.selector);
        factory.launch(invalid);

        invalid = request;
        invalid.feeAdmin = address(0);
        vm.prank(launcher);
        vm.expectRevert(IDegenHoodV4Factory.InvalidFeeAdmin.selector);
        factory.launch(invalid);

        invalid = request;
        invalid.beneficiary = address(0);
        vm.prank(launcher);
        vm.expectRevert(IDegenHoodV4Factory.InvalidBeneficiary.selector);
        factory.launch(invalid);

        invalid = request;
        invalid.name = "";
        vm.prank(launcher);
        vm.expectRevert(IDegenHoodV4Factory.EmptyNameOrSymbol.selector);
        factory.launch(invalid);
    }

    function test_constructorRejectsMissingOrCommingledGlobalRoles() public {
        vm.expectRevert(IDegenHoodV4Factory.InvalidAddress.selector);
        new DegenHoodV4Factory(address(0), weth, operatingTreasury, tokenReserve, address(this));

        vm.expectRevert(IDegenHoodV4Factory.InvalidAddress.selector);
        new DegenHoodV4Factory(
            address(manager), address(0), operatingTreasury, tokenReserve, address(this)
        );

        vm.expectRevert(IDegenHoodV4Factory.InvalidAddress.selector);
        new DegenHoodV4Factory(address(manager), weth, address(0), tokenReserve, address(this));

        vm.expectRevert(IDegenHoodV4Factory.InvalidAddress.selector);
        new DegenHoodV4Factory(address(manager), weth, operatingTreasury, address(0), address(this));

        vm.expectRevert(IDegenHoodV4Factory.InvalidAddress.selector);
        new DegenHoodV4Factory(
            address(manager), weth, operatingTreasury, operatingTreasury, address(this)
        );

        vm.expectRevert(IDegenHoodV4Factory.InvalidAddress.selector);
        new DegenHoodV4Factory(
            address(manager), weth, operatingTreasury, tokenReserve, operatingTreasury
        );
    }

    function test_configurationOwnershipHandoffCannotComingleWithAssetCustody() public {
        vm.expectRevert(IDegenHoodV4Factory.InvalidAddress.selector);
        factory.transferOwnership(operatingTreasury);

        vm.expectRevert(IDegenHoodV4Factory.InvalidAddress.selector);
        factory.transferOwnership(tokenReserve);

        factory.transferOwnership(stranger);
        assertEq(factory.owner(), stranger);
    }

    function test_launch_rejectsUnknownDeprecatedAndGloballyDeprecatedPaths() public {
        IDegenHoodV4Factory.LaunchRequest memory invalid = request;
        invalid.templateId = 999;
        vm.prank(launcher);
        vm.expectRevert(IDegenHoodV4Factory.TemplateNotApproved.selector);
        factory.launch(invalid);

        factory.deprecateTemplate(TEMPLATE_ID);
        vm.prank(launcher);
        vm.expectRevert(IDegenHoodV4Factory.TemplateDeprecated.selector);
        factory.launch(request);

        factory.deprecateFactory();
        vm.prank(launcher);
        vm.expectRevert(IDegenHoodV4Factory.FactoryDeprecated.selector);
        factory.launch(request);
    }

    function test_launch_enforcesVanityOrderingAndOneUseCommitment() public {
        assertEq(uint160(factory.predictTokenAddress(request)) & VANITY_MASK, VANITY_SUFFIX);
        assertLt(uint256(uint160(factory.predictTokenAddress(request))), uint256(uint160(weth)));

        vm.prank(launcher);
        factory.launch(request);

        vm.prank(launcher);
        vm.expectRevert(IDegenHoodV4Factory.LaunchAlreadyUsed.selector);
        factory.launch(request);
    }

    function test_launch_invalidSaltLeavesNoTokenPoolOrLaunchState() public {
        IDegenHoodV4Factory.LaunchRequest memory invalid = request;
        invalid.userSalt = _findSalt(false, true);
        address nonVanityPrediction = factory.predictTokenAddress(invalid);

        vm.prank(launcher);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDegenHoodV4Factory.VanitySuffixMismatch.selector, nonVanityPrediction
            )
        );
        factory.launch(invalid);
        assertEq(nonVanityPrediction.code.length, 0);
        assertEq(factory.launchCount(), 0);

        invalid.userSalt = _findSalt(true, false);
        address wrongOrderPrediction = factory.predictTokenAddress(invalid);
        vm.prank(launcher);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDegenHoodV4Factory.TokenMustSortBeforeWeth.selector, wrongOrderPrediction, weth
            )
        );
        factory.launch(invalid);
        assertEq(wrongOrderPrediction.code.length, 0);
        assertEq(factory.launchCount(), 0);
    }

    function test_templateApprovalRejectsUnauthorizedMalformedOrMutablePairs() public {
        vm.prank(stranger);
        vm.expectRevert();
        factory.approveTemplate(99, address(hook), address(lpLocker));

        vm.expectRevert(IDegenHoodV4Factory.InvalidTemplate.selector);
        factory.approveTemplate(0, address(hook), address(lpLocker));

        vm.expectRevert(IDegenHoodV4Factory.InvalidTemplate.selector);
        factory.approveTemplate(99, stranger, address(lpLocker));

        vm.expectRevert(IDegenHoodV4Factory.InvalidTemplate.selector);
        factory.approveTemplate(98, address(hook), address(lpLocker));

        (DegenHoodV4Hook secondHook, DegenHoodV4LpLocker secondLocker) =
            _deployAndApproveTemplate(SECOND_TEMPLATE_ID);
        assertTrue(address(secondHook) != address(hook));
        assertTrue(address(secondLocker) != address(lpLocker));
        vm.expectRevert(IDegenHoodV4Factory.InvalidTemplate.selector);
        factory.approveTemplate(99, address(hook), address(secondLocker));

        vm.expectRevert(IDegenHoodV4Factory.TemplateAlreadyExists.selector);
        factory.approveTemplate(TEMPLATE_ID, address(secondHook), address(secondLocker));

        vm.etch(address(hook), hex"00");
        vm.prank(launcher);
        vm.expectRevert(IDegenHoodV4Factory.TemplateCodeChanged.selector);
        factory.launch(request);
    }

    function test_templateRequiresBothFeeDepositorsAtLaunch() public {
        feeLocker.setDepositor(address(lpLocker), false);

        vm.prank(launcher);
        vm.expectRevert(IDegenHoodV4Factory.InvalidTemplate.selector);
        factory.launch(request);
    }

    function test_launch_hasNoArbitraryExtensionOrModuleSurface() public {
        bytes memory data = abi.encodeWithSignature(
            "launch((string,string,string,string,address,address,address,address,uint256,bytes32),bytes)",
            request,
            bytes("arbitrary-module-payload")
        );
        vm.prank(launcher);
        (bool success,) = address(factory).call(data);
        assertFalse(success);
        assertEq(factory.launchCount(), 0);
    }

    function test_predictionBindsEveryRoleTemplateMetadataAndSalt() public view {
        address baseline = factory.predictTokenAddress(request);
        IDegenHoodV4Factory.LaunchRequest memory changed = request;

        changed.launcher = stranger;
        assertTrue(factory.predictTokenAddress(changed) != baseline);
        changed = request;
        changed.tokenAdmin = stranger;
        assertTrue(factory.predictTokenAddress(changed) != baseline);
        changed = request;
        changed.feeAdmin = stranger;
        assertTrue(factory.predictTokenAddress(changed) != baseline);
        changed = request;
        changed.beneficiary = stranger;
        assertTrue(factory.predictTokenAddress(changed) != baseline);
        changed = request;
        changed.templateId = SECOND_TEMPLATE_ID;
        assertTrue(factory.predictTokenAddress(changed) != baseline);
        changed = request;
        changed.contractURI = "ipfs://different-metadata";
        assertTrue(factory.predictTokenAddress(changed) != baseline);
        changed = request;
        changed.userSalt = bytes32(uint256(request.userSalt) + 1);
        assertTrue(factory.predictTokenAddress(changed) != baseline);
    }

    function test_predictionMempoolRoleSubstitutionCannotProduceMinedAddress() public {
        address minedAddress = factory.predictTokenAddress(request);
        IDegenHoodV4Factory.LaunchRequest memory substituted = request;
        substituted.beneficiary = stranger;
        assertTrue(factory.predictTokenAddress(substituted) != minedAddress);

        vm.prank(stranger);
        vm.expectRevert(IDegenHoodV4Factory.UnauthorizedLauncher.selector);
        factory.launch(request);
    }

    function testFuzz_predictionCommitmentChangesWithUserSalt(bytes32 first, bytes32 second)
        public
        view
    {
        vm.assume(first != second);
        IDegenHoodV4Factory.LaunchRequest memory firstRequest = request;
        IDegenHoodV4Factory.LaunchRequest memory secondRequest = request;
        firstRequest.userSalt = first;
        secondRequest.userSalt = second;
        assertTrue(
            factory.launchCommitment(firstRequest) != factory.launchCommitment(secondRequest)
        );
    }

    function test_versioningNewTemplateAffectsFutureLaunchesOnly() public {
        vm.prank(launcher);
        IDegenHoodV4Factory.LaunchRecord memory firstRecord = factory.launch(request);
        IDegenHoodV4Hook.PoolConfig memory firstConfigBefore =
            hook.getPoolConfig(firstRecord.poolId);

        (DegenHoodV4Hook secondHook, DegenHoodV4LpLocker secondLocker) =
            _deployAndApproveTemplate(SECOND_TEMPLATE_ID);
        IDegenHoodV4Factory.LaunchRequest memory secondRequest = request;
        secondRequest.name = "Second Launch";
        secondRequest.symbol = "DLG2";
        secondRequest.templateId = SECOND_TEMPLATE_ID;
        secondRequest.userSalt = _mineSalt(secondRequest);
        vm.prank(launcher);
        IDegenHoodV4Factory.LaunchRecord memory secondRecord = factory.launch(secondRequest);

        assertTrue(firstRecord.token != secondRecord.token);
        assertEq(firstRecord.hook, address(hook));
        assertEq(firstRecord.lpLocker, address(lpLocker));
        assertEq(secondRecord.hook, address(secondHook));
        assertEq(secondRecord.lpLocker, address(secondLocker));
        assertEq(firstRecord.templateId, TEMPLATE_ID);
        assertEq(secondRecord.templateId, SECOND_TEMPLATE_ID);

        factory.deprecateTemplate(TEMPLATE_ID);
        IDegenHoodV4Factory.LaunchRecord memory storedFirst =
            factory.launchRecord(firstRecord.token);
        IDegenHoodV4Hook.PoolConfig memory firstConfigAfter = hook.getPoolConfig(firstRecord.poolId);
        assertEq(storedFirst.hook, firstRecord.hook);
        assertEq(storedFirst.lpLocker, firstRecord.lpLocker);
        assertEq(firstConfigAfter.beneficiary, firstConfigBefore.beneficiary);
        assertEq(firstConfigAfter.initializedAt, firstConfigBefore.initializedAt);
        swap(firstRecord.poolKey, false, -int256(1e12), "");

        IDegenHoodV4Factory.LaunchRequest memory blocked = request;
        blocked.name = "Blocked Old Template";
        blocked.userSalt = bytes32(uint256(request.userSalt) + 1);
        vm.prank(launcher);
        vm.expectRevert(IDegenHoodV4Factory.TemplateDeprecated.selector);
        factory.launch(blocked);
    }

    function _deployAndApproveTemplate(uint256 templateId)
        private
        returns (DegenHoodV4Hook deployedHook, DegenHoodV4LpLocker deployedLocker)
    {
        bytes memory constructorArgs = abi.encode(
            manager, address(factory), weth, operatingTreasury, address(feeLocker)
        );
        (address expected, bytes32 salt) = HookMiner.find(
            address(this), _hookFlags(), type(DegenHoodV4Hook).creationCode, constructorArgs
        );
        deployedHook = new DegenHoodV4Hook{salt: salt}(
            manager, address(factory), weth, operatingTreasury, address(feeLocker)
        );
        assertEq(address(deployedHook), expected);

        deployedLocker = new DegenHoodV4LpLocker(
            address(factory),
            address(deployedHook),
            weth,
            tokenReserve,
            address(feeLocker),
            address(positionManager),
            address(permit2)
        );
        feeLocker.setDepositor(address(deployedHook), true);
        feeLocker.setDepositor(address(deployedLocker), true);
        factory.approveTemplate(templateId, address(deployedHook), address(deployedLocker));
    }

    function _mineSalt(IDegenHoodV4Factory.LaunchRequest memory candidate)
        private
        view
        returns (bytes32)
    {
        for (uint256 i; i < 200_000; ++i) {
            candidate.userSalt = bytes32(i);
            address predicted = factory.predictTokenAddress(candidate);
            if (predicted < weth && uint160(predicted) & VANITY_MASK == VANITY_SUFFIX) {
                return bytes32(i);
            }
        }
        revert("salt not found");
    }

    function _findSalt(bool requireWrongOrder, bool requireNonVanity)
        private
        view
        returns (bytes32)
    {
        IDegenHoodV4Factory.LaunchRequest memory candidate = request;
        for (uint256 i; i < 200_000; ++i) {
            candidate.userSalt = bytes32(i);
            address predicted = factory.predictTokenAddress(candidate);
            bool wrongOrder = predicted >= weth;
            bool nonVanity = uint160(predicted) & VANITY_MASK != VANITY_SUFFIX;
            if (wrongOrder == requireWrongOrder && nonVanity == requireNonVanity) {
                return bytes32(i);
            }
        }
        revert("invalid salt not found");
    }

    function _hookFlags() private pure returns (uint160) {
        return uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
    }
}
