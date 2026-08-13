// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DegenHoodFeeLocker} from "../../src/DegenHoodFeeLocker.sol";
import {DegenHoodV4Factory} from "../../src/DegenHoodV4Factory.sol";
import {DegenHoodV4Hook} from "../../src/DegenHoodV4Hook.sol";
import {DegenHoodV4LpLocker} from "../../src/DegenHoodV4LpLocker.sol";
import {IDegenHoodV4Factory} from "../../src/interfaces/IDegenHoodV4Factory.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {DegenV4Fixture} from "./DegenV4Fixture.sol";

abstract contract DegenV4LaunchFixture is DegenV4Fixture {
    uint160 internal constant DEGEN_VANITY_MASK = 0xFFF;
    uint160 internal constant DEGEN_VANITY_SUFFIX = 0xDE6;

    DegenHoodFeeLocker internal launchFeeLocker;
    DegenHoodV4Factory internal launchFactory;
    DegenHoodV4Hook internal launchHook;
    DegenHoodV4LpLocker internal launchLpLocker;
    address internal launchWeth;
    address internal launchTreasury;
    address internal launchTokenReserve;

    function _setUpLaunchSystem(address treasury, address reserve, address configurationOwner)
        internal
    {
        _setUpV4Infrastructure();
        _setUpV4PositionManager();
        launchWeth = Currency.unwrap(currency1);
        launchTreasury = treasury;
        launchTokenReserve = reserve;
        launchFeeLocker = new DegenHoodFeeLocker(configurationOwner, launchWeth);
        launchFactory = new DegenHoodV4Factory(
            address(manager), launchWeth, treasury, reserve, configurationOwner
        );
        (launchHook, launchLpLocker,) = _deployAndApproveLaunchTemplate(1, launchFeeLocker);
    }

    function _deployAndApproveLaunchTemplate(uint256 templateId, DegenHoodFeeLocker ledger)
        internal
        returns (
            DegenHoodV4Hook deployedHook,
            DegenHoodV4LpLocker deployedLocker,
            DegenHoodFeeLocker templateLedger
        )
    {
        templateLedger = ledger;
        bytes memory constructorArgs = abi.encode(
            manager, address(launchFactory), launchWeth, launchTreasury, address(templateLedger)
        );
        (address expected, bytes32 salt) = HookMiner.find(
            address(this), _launchHookFlags(), type(DegenHoodV4Hook).creationCode, constructorArgs
        );
        deployedHook = new DegenHoodV4Hook{salt: salt}(
            manager, address(launchFactory), launchWeth, launchTreasury, address(templateLedger)
        );
        assertEq(address(deployedHook), expected);

        deployedLocker = new DegenHoodV4LpLocker(
            address(launchFactory),
            address(deployedHook),
            launchWeth,
            launchTokenReserve,
            address(templateLedger),
            address(positionManager),
            address(permit2)
        );
        templateLedger.setDepositor(address(deployedHook), true);
        templateLedger.setDepositor(address(deployedLocker), true);
        launchFactory.approveTemplate(templateId, address(deployedHook), address(deployedLocker));
    }

    function _newTemplate(uint256 templateId)
        internal
        returns (
            DegenHoodV4Hook deployedHook,
            DegenHoodV4LpLocker deployedLocker,
            DegenHoodFeeLocker templateLedger
        )
    {
        templateLedger = new DegenHoodFeeLocker(address(this), launchWeth);
        return _deployAndApproveLaunchTemplate(templateId, templateLedger);
    }

    function _mineLaunchSalt(IDegenHoodV4Factory.LaunchRequest memory candidate)
        internal
        view
        returns (bytes32)
    {
        for (uint256 i; i < 200_000; ++i) {
            candidate.userSalt = bytes32(i);
            address predicted = launchFactory.predictTokenAddress(candidate);
            if (
                predicted < launchWeth
                    && uint160(predicted) & DEGEN_VANITY_MASK == DEGEN_VANITY_SUFFIX
            ) {
                return bytes32(i);
            }
        }
        revert("launch salt not found");
    }

    function _launchHookFlags() private pure returns (uint160) {
        return uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
    }
}
