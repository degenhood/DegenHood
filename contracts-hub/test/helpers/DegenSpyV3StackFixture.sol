// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {DomainId} from "../../src/LaunchHub.sol";
import {DegenSpyV1FeeLocker} from "../../src/degen-spy/DegenSpyV1FeeLocker.sol";
import {DegenSpyV3Hook} from "../../src/launchhub-spy-v3/DegenSpyV3Hook.sol";
import {DegenSpyV3LpLocker} from "../../src/launchhub-spy-v3/DegenSpyV3LpLocker.sol";
import {DegenSpyV3Module} from "../../src/launchhub-spy-v3/DegenSpyV3Module.sol";
import {DegenSpyV3LaunchConstants} from "../../src/libraries/DegenSpyV3LaunchConstants.sol";
import {DegenHoodTokenV5} from "../../src/token/DegenHoodTokenV5.sol";
import {DegenHubV4Fixture} from "./DegenHubV4Fixture.sol";
import {DegenSpyBuybackVaultBindingMock} from "./DegenSpyBuybackVaultBindingMock.sol";

contract SpyV3RegistryMock {
    bool public paused;
    mapping(address account => bool blocked) public isBlocked;

    function setBlocked(address account, bool value) external {
        isBlocked[account] = value;
    }
}

contract DegenSpyV3ModuleCreator {
    function deploy(
        address kernel,
        DomainId domainId,
        bytes32 configHash,
        address hook,
        address lpLocker
    ) external returns (DegenSpyV3Module) {
        return new DegenSpyV3Module(kernel, domainId, configHash, hook, lpLocker);
    }
}

contract DegenSpyV3LpCreator {
    function deploy(
        address module,
        address hook,
        address spy,
        address tokenReserve,
        address feeLocker,
        address positionManager
    ) external returns (DegenSpyV3LpLocker) {
        return new DegenSpyV3LpLocker(module, hook, spy, tokenReserve, feeLocker, positionManager);
    }
}

contract DegenSpyV3FeeCreator {
    function deploy(address spy, address lpLocker, address hook)
        external
        returns (DegenSpyV1FeeLocker)
    {
        return new DegenSpyV1FeeLocker(spy, lpLocker, hook);
    }
}

abstract contract DegenSpyV3StackFixture is DegenHubV4Fixture {
    struct DeploymentGraph {
        DegenSpyV3ModuleCreator moduleCreator;
        DegenSpyV3LpCreator lpCreator;
        DegenSpyV3FeeCreator feeCreator;
        DegenHoodTokenV5 implementation;
        address predictedModule;
        address predictedLp;
        address predictedFee;
        address predictedToken;
        address expectedHook;
        bytes32 tokenSalt;
        bytes32 hookSalt;
    }

    uint256 internal constant POOL_SUPPLY = 100_000_000_000 ether;
    bytes32 internal constant CONFIG_HASH = keccak256("degen-spy-v3-config");
    bytes32 internal constant EMPTY_SCHEMA_HASH = keccak256("EMPTY");

    DomainId internal domain;
    DegenSpyV3Module internal module;
    DegenSpyV3Hook internal hook;
    DegenSpyV3LpLocker internal lpLocker;
    DegenSpyV1FeeLocker internal feeLocker;
    DegenHoodTokenV5 internal token;
    address internal spy;
    address internal treasury;
    address internal buybackVault;
    address internal tokenReserve;
    address internal beneficiary;
    address internal feeAdmin;
    SpyV3RegistryMock internal registry;

    function _setUpDegenSpyV3Stack() internal {
        _setUpV4Infrastructure();
        _setUpV4PositionManager();
        spy = Currency.unwrap(currency1);
        registry = new SpyV3RegistryMock();
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
        graph.moduleCreator = new DegenSpyV3ModuleCreator();
        graph.predictedModule = vm.computeCreateAddress(
            address(graph.moduleCreator), vm.getNonce(address(graph.moduleCreator))
        );
        graph.lpCreator = new DegenSpyV3LpCreator();
        graph.predictedLp = vm.computeCreateAddress(
            address(graph.lpCreator), vm.getNonce(address(graph.lpCreator))
        );
        graph.feeCreator = new DegenSpyV3FeeCreator();
        graph.predictedFee = vm.computeCreateAddress(
            address(graph.feeCreator), vm.getNonce(address(graph.feeCreator))
        );

        graph.implementation = new DegenHoodTokenV5();
        (graph.tokenSalt, graph.predictedToken) = _mineTokenBelow(graph.implementation, spy);
        buybackVault = address(
            new DegenSpyBuybackVaultBindingMock(address(manager), graph.predictedToken, spy)
        );
        bytes memory hookArgs = abi.encode(
            manager, graph.predictedModule, spy, treasury, buybackVault, graph.predictedFee
        );
        (graph.expectedHook, graph.hookSalt) = HookMiner.find(
            address(this), _hookFlags(), type(DegenSpyV3Hook).creationCode, hookArgs
        );

        feeLocker = graph.feeCreator.deploy(spy, graph.predictedLp, graph.expectedHook);
        hook = new DegenSpyV3Hook{salt: graph.hookSalt}(
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

        token = DegenHoodTokenV5(
            Clones.cloneDeterministic(address(graph.implementation), graph.tokenSalt)
        );
        token.initialize(
            "LaunchHub V3 Test",
            "LHV3",
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

    function _mineTokenBelow(DegenHoodTokenV5 implementation, address quote)
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
