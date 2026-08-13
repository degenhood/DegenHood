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
import {DegenV1FeeLocker} from "../../src/degen/DegenV1FeeLocker.sol";
import {DegenV3Hook} from "../../src/launchhub-v3/DegenV3Hook.sol";
import {DegenV3LpLocker} from "../../src/launchhub-v3/DegenV3LpLocker.sol";
import {DegenV3Module} from "../../src/launchhub-v3/DegenV3Module.sol";
import {DegenHoodTokenV5} from "../../src/token/DegenHoodTokenV5.sol";
import {BuybackVaultBindingMock} from "./BuybackVaultBindingMock.sol";
import {DegenHubV4Fixture} from "./DegenHubV4Fixture.sol";

contract DegenV3ModuleCreator {
    function deploy(
        address kernel,
        DomainId domainId,
        bytes32 configHash,
        address hook,
        address lpLocker
    ) external returns (DegenV3Module) {
        return new DegenV3Module(kernel, domainId, configHash, hook, lpLocker);
    }
}

contract DegenV3LpCreator {
    function deploy(
        address module,
        address hook,
        address weth,
        address tokenReserve,
        address feeLocker,
        address positionManager
    ) external returns (DegenV3LpLocker) {
        return new DegenV3LpLocker(module, hook, weth, tokenReserve, feeLocker, positionManager);
    }
}

contract DegenV3FeeCreator {
    function deploy(address weth, address lpLocker, address hook)
        external
        returns (DegenV1FeeLocker)
    {
        return new DegenV1FeeLocker(weth, lpLocker, hook);
    }
}

abstract contract DegenV3StackFixture is DegenHubV4Fixture {
    struct DeploymentGraph {
        DegenV3ModuleCreator moduleCreator;
        DegenV3LpCreator lpCreator;
        DegenV3FeeCreator feeCreator;
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
    bytes32 internal constant CONFIG_HASH = keccak256("degen-v3-config");
    bytes32 internal constant EMPTY_SCHEMA_HASH = keccak256("EMPTY");

    DomainId internal domain;
    DegenV3Module internal module;
    DegenV3Hook internal hook;
    DegenV3LpLocker internal lpLocker;
    DegenV1FeeLocker internal feeLocker;
    DegenHoodTokenV5 internal token;
    address internal weth;
    address internal treasury;
    address internal buybackVault;
    address internal tokenReserve;
    address internal beneficiary;
    address internal feeAdmin;

    function _setUpDegenV3Stack() internal {
        _setUpV4Infrastructure();
        _setUpV4PositionManager();
        weth = Currency.unwrap(currency1);
        treasury = makeAddr("operatingTreasury");
        tokenReserve = makeAddr("tokenReserve");
        beneficiary = makeAddr("beneficiary");
        feeAdmin = makeAddr("feeAdmin");
        domain = DomainId.wrap(keccak256("degenhood-domain"));

        DeploymentGraph memory graph;
        graph.moduleCreator = new DegenV3ModuleCreator();
        graph.predictedModule = vm.computeCreateAddress(
            address(graph.moduleCreator), vm.getNonce(address(graph.moduleCreator))
        );
        graph.lpCreator = new DegenV3LpCreator();
        graph.predictedLp = vm.computeCreateAddress(
            address(graph.lpCreator), vm.getNonce(address(graph.lpCreator))
        );
        graph.feeCreator = new DegenV3FeeCreator();
        graph.predictedFee = vm.computeCreateAddress(
            address(graph.feeCreator), vm.getNonce(address(graph.feeCreator))
        );

        graph.implementation = new DegenHoodTokenV5();
        (graph.tokenSalt, graph.predictedToken) = _mineTokenBelow(graph.implementation, weth);
        buybackVault = address(new BuybackVaultBindingMock(manager, graph.predictedToken, weth));
        bytes memory hookArgs = abi.encode(
            manager, graph.predictedModule, weth, treasury, buybackVault, graph.predictedFee
        );
        (graph.expectedHook, graph.hookSalt) =
            HookMiner.find(address(this), _hookFlags(), type(DegenV3Hook).creationCode, hookArgs);

        feeLocker = graph.feeCreator.deploy(weth, graph.predictedLp, graph.expectedHook);
        hook = new DegenV3Hook{salt: graph.hookSalt}(
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
            currency1: Currency.wrap(weth),
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
