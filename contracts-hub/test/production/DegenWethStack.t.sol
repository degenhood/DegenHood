// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Vm} from "forge-std/Vm.sol";

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {IDegenV3LpLocker} from "../../src/interfaces/IDegenV3LpLocker.sol";
import {DegenToken} from "../../src/production/ProductionDegenToken.sol";
import {DegenWethFeeLocker} from "../../src/production/ProductionDegenWethFeeLocker.sol";
import {DegenWethHook} from "../../src/production/ProductionDegenWethHook.sol";
import {DegenWethLpLocker} from "../../src/production/ProductionDegenWethLpLocker.sol";
import {
    DegenWethModule,
    IDegenWethModule
} from "../../src/production/ProductionDegenWethModule.sol";
import {
    DomainId,
    LaunchContext,
    LaunchResult,
    TemplateId,
    Version
} from "../../src/production/ProductionLaunchTypes.sol";
import {BuybackVaultBindingMock} from "../helpers/BuybackVaultBindingMock.sol";
import {DegenHubV4Fixture} from "../helpers/DegenHubV4Fixture.sol";

contract DegenWethModuleCreator {
    function deploy(
        address kernel,
        DomainId domainId,
        bytes32 configHash,
        address hook,
        address lpLocker
    ) external returns (DegenWethModule) {
        return new DegenWethModule(kernel, domainId, configHash, hook, lpLocker);
    }
}

contract DegenWethLpCreator {
    function deploy(
        address module,
        address hook,
        address weth,
        address tokenReserve,
        address feeLocker,
        address positionManager
    ) external returns (DegenWethLpLocker) {
        return new DegenWethLpLocker(module, hook, weth, tokenReserve, feeLocker, positionManager);
    }
}

contract DegenWethFeeCreator {
    function deploy(address weth, address lpLocker, address hook)
        external
        returns (DegenWethFeeLocker)
    {
        return new DegenWethFeeLocker(weth, lpLocker, hook);
    }
}

abstract contract DegenWethStackFixture is DegenHubV4Fixture {
    struct DeploymentGraph {
        DegenWethModuleCreator moduleCreator;
        DegenWethLpCreator lpCreator;
        DegenWethFeeCreator feeCreator;
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
    bytes32 internal constant CONFIG_HASH = keccak256("degen-production-weth-config");
    bytes32 internal constant EMPTY_SCHEMA_HASH = keccak256("EMPTY");

    DomainId internal domain;
    DegenWethModule internal module;
    DegenWethHook internal hook;
    DegenWethLpLocker internal lpLocker;
    DegenWethFeeLocker internal feeLocker;
    DegenToken internal token;
    address internal weth;
    address internal treasury;
    address internal buybackVault;
    address internal tokenReserve;
    address internal beneficiary;
    address internal feeAdmin;

    function _setUpDegenWethStack() internal {
        _setUpV4Infrastructure();
        _setUpV4PositionManager();
        weth = Currency.unwrap(currency1);
        treasury = makeAddr("operatingTreasury");
        tokenReserve = makeAddr("tokenReserve");
        beneficiary = makeAddr("beneficiary");
        feeAdmin = makeAddr("feeAdmin");
        domain = DomainId.wrap(keccak256("degenhood-domain"));

        DeploymentGraph memory graph;
        graph.moduleCreator = new DegenWethModuleCreator();
        graph.predictedModule = vm.computeCreateAddress(
            address(graph.moduleCreator), vm.getNonce(address(graph.moduleCreator))
        );
        graph.lpCreator = new DegenWethLpCreator();
        graph.predictedLp = vm.computeCreateAddress(
            address(graph.lpCreator), vm.getNonce(address(graph.lpCreator))
        );
        graph.feeCreator = new DegenWethFeeCreator();
        graph.predictedFee = vm.computeCreateAddress(
            address(graph.feeCreator), vm.getNonce(address(graph.feeCreator))
        );

        graph.implementation = new DegenToken();
        (graph.tokenSalt, graph.predictedToken) = _mineTokenBelow(graph.implementation, weth);
        buybackVault = address(new BuybackVaultBindingMock(manager, graph.predictedToken, weth));
        bytes memory hookArgs = abi.encode(
            manager, graph.predictedModule, weth, treasury, buybackVault, graph.predictedFee
        );
        (graph.expectedHook, graph.hookSalt) =
            HookMiner.find(address(this), _hookFlags(), type(DegenWethHook).creationCode, hookArgs);

        feeLocker = graph.feeCreator.deploy(weth, graph.predictedLp, graph.expectedHook);
        hook = new DegenWethHook{salt: graph.hookSalt}(
            manager, graph.predictedModule, weth, treasury, buybackVault, address(feeLocker)
        );
        lpLocker = graph.lpCreator
            .deploy(
                graph.predictedModule,
                address(hook),
                weth,
                tokenReserve,
                address(feeLocker),
                address(positionManager)
            );
        module = graph.moduleCreator
            .deploy(address(this), domain, CONFIG_HASH, address(hook), address(lpLocker));

        token =
            DegenToken(Clones.cloneDeterministic(address(graph.implementation), graph.tokenSalt));
        token.initialize(
            "Degen WETH Production Test",
            "DWETH",
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
            currency1: Currency.wrap(weth),
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

contract DegenWethStackTest is DegenWethStackFixture {
    using PoolIdLibrary for PoolKey;

    function setUp() public {
        _setUpDegenWethStack();
    }

    function testIdentityTenPositionsZeroApprovalsAndTimestampEvidence() public {
        assertEq(TemplateId.unwrap(module.TEMPLATE_ID()), 1);
        assertEq(Version.unwrap(module.VERSION()), 1);

        vm.recordLogs();
        LaunchResult memory result = module.configure(_context());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        IDegenV3LpLocker.PositionConfig memory config = lpLocker.positionForToken(address(token));
        PoolId launchedPool = hook.poolIdForToken(address(token));

        assertEq(result.poolId, PoolId.unwrap(launchedPool));
        assertEq(result.configEcho, CONFIG_HASH);
        assertEq(config.poolSupply, POOL_SUPPLY);
        assertEq(config.tokenPrincipal + config.lockedTokenDust, POOL_SUPPLY);
        assertTrue(config.placed);
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
        assertEq(token.allowance(address(module), address(positionManager)), 0);
        assertEq(token.allowance(address(module), address(permit2)), 0);
        assertEq(token.flatEndTime(), token.restrictionStartTime() + 60);
        assertEq(token.rampEndTime(), token.restrictionStartTime() + 120);
    }

    function testRejectsWrongIdentityAndAlteredNonzeroLiquidityReceipt() public {
        LaunchContext memory context = _context();
        context.templateId = TemplateId.wrap(2);
        vm.expectRevert(IDegenWethModule.InvalidLaunchContext.selector);
        module.configure(context);

        context.templateId = TemplateId.wrap(1);
        context.version = Version.wrap(2);
        vm.expectRevert(IDegenWethModule.InvalidLaunchContext.selector);
        module.configure(context);

        context.version = Version.wrap(1);
        vm.mockCall(
            address(positionManager),
            abi.encodeWithSignature("getPositionLiquidity(uint256)"),
            abi.encode(uint128(1))
        );
        vm.expectRevert(IDegenV3LpLocker.InvalidPositionReceipt.selector);
        module.configure(context);
    }

    function testAllSwapQuadrantsAccrueUntilPermissionlessClaimsAndGlobalFlush() public {
        module.configure(_context());
        key = _poolKey();
        poolId = key.toId();
        vm.warp(token.rampEndTime());
        token.approve(address(swapRouter), type(uint256).max);

        _swap(false, -int256(1e15));
        _swap(false, int256(1e15));
        uint256 acquired = token.balanceOf(address(this));
        assertGt(acquired, 1e16);
        _swap(true, -int256(1e16));
        _swap(true, int256(1e6));

        uint256 pendingTreasury = hook.pendingTreasuryWeth();
        uint256 pendingBuyback = hook.pendingBuybackWeth();
        assertGt(pendingTreasury, 0);
        assertGt(pendingBuyback, 0);
        assertEq(IERC20(weth).balanceOf(treasury), 0);
        assertEq(IERC20(weth).balanceOf(buybackVault), 0);

        uint256 beneficiaryBefore = IERC20(weth).balanceOf(beneficiary);
        vm.prank(makeAddr("creatorClaimCaller"));
        lpLocker.claimFees(address(token));
        assertGt(IERC20(weth).balanceOf(beneficiary), beneficiaryBefore);
        assertEq(hook.pendingTreasuryWeth(), pendingTreasury);
        assertEq(hook.pendingBuybackWeth(), pendingBuyback);

        vm.prank(makeAddr("globalFlushCaller"));
        (uint256 treasuryPaid, uint256 buybackPaid) = hook.flushProtocolFees();
        assertEq(treasuryPaid, pendingTreasury);
        assertEq(buybackPaid, pendingBuyback);
        assertEq(IERC20(weth).balanceOf(treasury), pendingTreasury);
        assertEq(IERC20(weth).balanceOf(buybackVault), pendingBuyback);
    }

    function testBindingExactInputPartialFillRevertsWithoutAccrual() public {
        module.configure(_context());
        key = _poolKey();
        poolId = key.toId();
        vm.warp(token.rampEndTime());

        uint160 bindingLimit = TickMath.getSqrtPriceAtTick(module.INITIAL_TICK() + 200);
        vm.expectRevert();
        _swap(false, -int256(1 ether), bindingLimit);
        assertEq(hook.pendingTreasuryWeth(), 0);
        assertEq(hook.pendingBuybackWeth(), 0);
        assertEq(hook.pendingBeneficiaryTotalWeth(poolId), 0);
    }

    function _context() internal view returns (LaunchContext memory) {
        return LaunchContext({
            domainId: domain,
            templateId: TemplateId.wrap(1),
            version: Version.wrap(1),
            commitment: keccak256("production-weth-launch"),
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
