// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Vm} from "forge-std/Vm.sol";

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {IDegenSpyV3LpLocker} from "../../src/interfaces/IDegenSpyV3LpLocker.sol";
import {DegenSpyV3LaunchConstants} from "../../src/libraries/DegenSpyV3LaunchConstants.sol";
import {DegenSpyFeeLocker} from "../../src/production/ProductionDegenSpyFeeLocker.sol";
import {DegenSpyHook} from "../../src/production/ProductionDegenSpyHook.sol";
import {DegenSpyLpLocker} from "../../src/production/ProductionDegenSpyLpLocker.sol";
import {DegenSpyModule, IDegenSpyModule} from "../../src/production/ProductionDegenSpyModule.sol";
import {DegenToken} from "../../src/production/ProductionDegenToken.sol";
import {
    DomainId,
    LaunchContext,
    LaunchResult,
    TemplateId,
    Version
} from "../../src/production/ProductionLaunchTypes.sol";
import {DegenHubV4Fixture} from "../helpers/DegenHubV4Fixture.sol";
import {DegenSpyBuybackVaultBindingMock} from "../helpers/DegenSpyBuybackVaultBindingMock.sol";

contract ProductionSpyRegistryMock {
    bool public paused;
    mapping(address account => bool blocked) public isBlocked;

    function setBlocked(address account, bool value) external {
        isBlocked[account] = value;
    }
}

contract DegenSpyModuleCreator {
    function deploy(
        address kernel,
        DomainId domainId,
        bytes32 configHash,
        address hook,
        address lpLocker
    ) external returns (DegenSpyModule) {
        return new DegenSpyModule(kernel, domainId, configHash, hook, lpLocker);
    }
}

contract DegenSpyLpCreator {
    function deploy(
        address module,
        address hook,
        address spy,
        address tokenReserve,
        address feeLocker,
        address positionManager
    ) external returns (DegenSpyLpLocker) {
        return new DegenSpyLpLocker(module, hook, spy, tokenReserve, feeLocker, positionManager);
    }
}

contract DegenSpyFeeCreator {
    function deploy(address spy, address lpLocker, address hook)
        external
        returns (DegenSpyFeeLocker)
    {
        return new DegenSpyFeeLocker(spy, lpLocker, hook);
    }
}

abstract contract DegenSpyStackFixture is DegenHubV4Fixture {
    struct DeploymentGraph {
        DegenSpyModuleCreator moduleCreator;
        DegenSpyLpCreator lpCreator;
        DegenSpyFeeCreator feeCreator;
        DegenToken implementation;
        address predictedModule;
        address predictedLp;
        address predictedFee;
        address predictedToken;
        address expectedHook;
        bytes32 tokenSalt;
        bytes32 hookSalt;
    }

    uint256 internal constant POOL_SUPPLY = 100_000_000_000 ether;
    bytes32 internal constant CONFIG_HASH = keccak256("degen-production-spy-config");
    bytes32 internal constant EMPTY_SCHEMA_HASH = keccak256("EMPTY");

    DomainId internal domain;
    DegenSpyModule internal module;
    DegenSpyHook internal hook;
    DegenSpyLpLocker internal lpLocker;
    DegenSpyFeeLocker internal feeLocker;
    DegenToken internal token;
    address internal spy;
    address internal treasury;
    address internal buybackVault;
    address internal tokenReserve;
    address internal beneficiary;
    address internal feeAdmin;
    ProductionSpyRegistryMock internal registry;

    function _setUpDegenSpyStack() internal {
        _setUpV4Infrastructure();
        _setUpV4PositionManager();
        spy = Currency.unwrap(currency1);
        registry = new ProductionSpyRegistryMock();
        vm.mockCall(
            spy, abi.encodeWithSignature("uid()"), abi.encode(DegenSpyV3LaunchConstants.SPY_UID)
        );
        vm.mockCall(
            spy,
            abi.encodeWithSignature("ACCESS_CONTROLLED_REGISTRY()"),
            abi.encode(address(registry))
        );
        vm.mockCall(spy, abi.encodeWithSignature("paused()"), abi.encode(false));
        vm.mockCall(spy, abi.encodeWithSignature("uiMultiplier()"), abi.encode(1 ether));
        treasury = makeAddr("operatingTreasury");
        tokenReserve = makeAddr("tokenReserve");
        beneficiary = makeAddr("beneficiary");
        feeAdmin = makeAddr("feeAdmin");
        domain = DomainId.wrap(keccak256("degenhood-domain"));

        DeploymentGraph memory graph;
        graph.moduleCreator = new DegenSpyModuleCreator();
        graph.predictedModule = vm.computeCreateAddress(
            address(graph.moduleCreator), vm.getNonce(address(graph.moduleCreator))
        );
        graph.lpCreator = new DegenSpyLpCreator();
        graph.predictedLp = vm.computeCreateAddress(
            address(graph.lpCreator), vm.getNonce(address(graph.lpCreator))
        );
        graph.feeCreator = new DegenSpyFeeCreator();
        graph.predictedFee = vm.computeCreateAddress(
            address(graph.feeCreator), vm.getNonce(address(graph.feeCreator))
        );

        graph.implementation = new DegenToken();
        (graph.tokenSalt, graph.predictedToken) = _mineTokenBelow(graph.implementation, spy);
        buybackVault = address(
            new DegenSpyBuybackVaultBindingMock(address(manager), graph.predictedToken, spy)
        );
        bytes memory hookArgs = abi.encode(
            manager, graph.predictedModule, spy, treasury, buybackVault, graph.predictedFee
        );
        (graph.expectedHook, graph.hookSalt) =
            HookMiner.find(address(this), _hookFlags(), type(DegenSpyHook).creationCode, hookArgs);

        feeLocker = graph.feeCreator.deploy(spy, graph.predictedLp, graph.expectedHook);
        hook = new DegenSpyHook{salt: graph.hookSalt}(
            manager, graph.predictedModule, spy, treasury, buybackVault, address(feeLocker)
        );
        lpLocker = graph.lpCreator
            .deploy(
                graph.predictedModule,
                address(hook),
                spy,
                tokenReserve,
                address(feeLocker),
                address(positionManager)
            );
        module = graph.moduleCreator
            .deploy(address(this), domain, CONFIG_HASH, address(hook), address(lpLocker));

        token =
            DegenToken(Clones.cloneDeterministic(address(graph.implementation), graph.tokenSalt));
        token.initialize(
            "Degen SPY Production Test",
            "DSPY",
            address(module),
            makeAddr("tokenAdmin"),
            bytes32(uint256(1)),
            bytes32(uint256(2)),
            address(manager),
            address(positionManager),
            address(lpLocker)
        );

        assertEq(address(module), graph.predictedModule);
        assertEq(address(lpLocker), graph.predictedLp);
        assertEq(address(hook), graph.expectedHook);
        assertEq(address(token), graph.predictedToken);
    }

    function _poolKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(token)),
            currency1: Currency.wrap(spy),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 200,
            hooks: hook
        });
    }

    function _mineTokenBelow(DegenToken implementation, address quote)
        private
        view
        returns (bytes32 salt, address predicted)
    {
        for (uint256 i; i < 100_000; ++i) {
            salt = bytes32(i);
            predicted =
                Clones.predictDeterministicAddress(address(implementation), salt, address(this));
            if (predicted < quote) return (salt, predicted);
        }
        revert("NO_TOKEN_BELOW_QUOTE");
    }

    function _hookFlags() private pure returns (uint160) {
        return uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
    }
}

contract DegenSpyStackTest is DegenSpyStackFixture {
    using PoolIdLibrary for PoolKey;

    function setUp() public {
        _setUpDegenSpyStack();
    }

    function testIdentitySpySurfaceTenPositionsAndTimestampEvidence() public {
        assertEq(TemplateId.unwrap(module.TEMPLATE_ID()), 2);
        assertEq(Version.unwrap(module.VERSION()), 1);

        vm.recordLogs();
        LaunchResult memory result = module.configure(_context());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        IDegenSpyV3LpLocker.PositionConfig memory config = lpLocker.positionForToken(address(token));
        PoolId launchedPool = hook.poolIdForToken(address(token));

        assertEq(result.poolId, PoolId.unwrap(launchedPool));
        assertEq(result.configEcho, CONFIG_HASH);
        assertEq(module.launchUiMultiplier(address(token)), 1 ether);
        assertEq(config.poolSupply, POOL_SUPPLY);
        assertEq(config.tokenPrincipal + config.lockedTokenDust, POOL_SUPPLY);
        for (uint256 i; i < 10; ++i) {
            assertEq(
                IERC721(address(positionManager)).ownerOf(config.positionIds[i]), address(lpLocker)
            );
            if (i != 0) assertEq(config.positionIds[i], config.positionIds[0] + i);
        }

        uint256 approvalEvents;
        bytes32 approvalTopic = keccak256("Approval(address,address,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(token) && logs[i].topics.length != 0
                    && logs[i].topics[0] == approvalTopic
            ) ++approvalEvents;
        }
        assertEq(approvalEvents, 0);
        assertEq(token.flatEndTime(), token.restrictionStartTime() + 60);
        assertEq(token.rampEndTime(), token.restrictionStartTime() + 120);
    }

    function testRejectsWrongIdentityBlockedBeneficiaryAndAlteredLiquidityReceipt() public {
        LaunchContext memory context = _context();
        context.templateId = TemplateId.wrap(1);
        vm.expectRevert(IDegenSpyModule.InvalidLaunchContext.selector);
        module.configure(context);

        context.templateId = TemplateId.wrap(2);
        registry.setBlocked(beneficiary, true);
        vm.expectRevert(
            abi.encodeWithSelector(IDegenSpyModule.SpyAddressBlocked.selector, beneficiary)
        );
        module.configure(context);
        registry.setBlocked(beneficiary, false);

        vm.mockCall(
            address(positionManager),
            abi.encodeWithSignature("getPositionLiquidity(uint256)"),
            abi.encode(uint128(1))
        );
        vm.expectRevert(IDegenSpyV3LpLocker.InvalidPositionReceipt.selector);
        module.configure(context);
    }

    function testQuoteCorrectSwapAccrualCreatorClaimAndGlobalFlush() public {
        module.configure(_context());
        key = _poolKey();
        poolId = key.toId();
        vm.warp(token.rampEndTime());
        token.approve(address(swapRouter), type(uint256).max);

        _swap(false, -int256(1e15));
        _swap(false, int256(1e15));
        assertGt(token.balanceOf(address(this)), 1e16);
        _swap(true, -int256(1e16));
        _swap(true, int256(1e6));

        uint256 pendingTreasury = hook.pendingTreasuryRawSpy();
        uint256 pendingBuyback = hook.pendingBuybackRawSpy();
        assertGt(pendingTreasury, 0);
        assertGt(pendingBuyback, 0);
        assertEq(IERC20(spy).balanceOf(treasury), 0);
        assertEq(IERC20(spy).balanceOf(buybackVault), 0);

        uint256 beneficiaryBefore = IERC20(spy).balanceOf(beneficiary);
        vm.prank(makeAddr("creatorClaimCaller"));
        lpLocker.claimFees(address(token));
        assertGt(IERC20(spy).balanceOf(beneficiary), beneficiaryBefore);
        assertEq(hook.pendingTreasuryRawSpy(), pendingTreasury);
        assertEq(hook.pendingBuybackRawSpy(), pendingBuyback);

        vm.prank(makeAddr("globalFlushCaller"));
        (uint256 treasuryPaid, uint256 buybackPaid) = hook.flushProtocolFees();
        assertEq(treasuryPaid, pendingTreasury);
        assertEq(buybackPaid, pendingBuyback);
        assertEq(IERC20(spy).balanceOf(treasury), pendingTreasury);
        assertEq(IERC20(spy).balanceOf(buybackVault), pendingBuyback);
    }

    function testBindingExactInputPartialFillRevertsWithoutAccrual() public {
        module.configure(_context());
        key = _poolKey();
        poolId = key.toId();
        vm.warp(token.rampEndTime());

        uint160 bindingLimit = TickMath.getSqrtPriceAtTick(module.INITIAL_TICK() + 200);
        vm.expectRevert();
        _swap(false, -int256(1 ether), bindingLimit);
        assertEq(hook.pendingTreasuryRawSpy(), 0);
        assertEq(hook.pendingBuybackRawSpy(), 0);
        assertEq(hook.pendingBeneficiaryTotalRawSpy(poolId), 0);
    }

    function _context() internal view returns (LaunchContext memory) {
        return LaunchContext({
            domainId: domain,
            templateId: TemplateId.wrap(2),
            version: Version.wrap(1),
            commitment: keccak256("production-spy-launch"),
            token: address(token),
            launcher: address(this),
            tokenAdmin: token.tokenAdmin(),
            feeAdmin: feeAdmin,
            beneficiary: beneficiary,
            metadataHash: keccak256("metadata"),
            inputSchemaHash: EMPTY_SCHEMA_HASH,
            launchData: bytes("")
        });
    }
}
