// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DegenHoodV4HookV2} from "../src/DegenHoodV4HookV2.sol";
import {DegenHoodV4LpLocker} from "../src/DegenHoodV4LpLocker.sol";
import {IDegenHoodV4Factory} from "../src/interfaces/IDegenHoodV4Factory.sol";
import {DegenV4LaunchFixture} from "./helpers/DegenV4LaunchFixture.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

contract DegenHoodV4IntegrationV2Test is DegenV4LaunchFixture {
    uint256 private constant TEMPLATE_V2 = 2;

    DegenHoodV4HookV2 private hookV2;
    DegenHoodV4LpLocker private lpLockerV2;

    address private treasury = makeAddr("v2IntegrationTreasury");
    address private reserve = makeAddr("v2IntegrationReserve");
    address private launcher = makeAddr("v2IntegrationLauncher");
    address private tokenAdmin = makeAddr("v2IntegrationTokenAdmin");
    address private feeAdminA = makeAddr("v2IntegrationFeeAdminA");
    address private feeAdminB = makeAddr("v2IntegrationFeeAdminB");
    address private beneficiaryA = makeAddr("v2IntegrationBeneficiaryA");
    address private beneficiaryB = makeAddr("v2IntegrationBeneficiaryB");
    address private keeper = makeAddr("v2IntegrationKeeper");

    IDegenHoodV4Factory.LaunchRecord private launchA;
    IDegenHoodV4Factory.LaunchRecord private launchB;

    function setUp() public {
        _setUpLaunchSystem(treasury, reserve, address(this));
        _deployAndApproveTemplateV2();

        vm.warp(10_000);
        launchA = _launch("V2 Integration A", "V2A", feeAdminA, beneficiaryA, keccak256("A"));
        launchB = _launch("V2 Integration B", "V2B", feeAdminB, beneficiaryB, keccak256("B"));
        IERC20(launchA.token).approve(address(swapRouter), type(uint256).max);
        IERC20(launchB.token).approve(address(swapRouter), type(uint256).max);
    }

    function test_template2LaunchesTwoTokensAndKeepsAutoSweepSeparateFromCreatorLpFees() public {
        assertEq(launchA.templateId, TEMPLATE_V2);
        assertEq(launchB.templateId, TEMPLATE_V2);
        assertEq(launchA.hook, address(hookV2));
        assertEq(launchA.lpLocker, address(lpLockerV2));
        assertTrue(PoolId.unwrap(launchA.poolId) != PoolId.unwrap(launchB.poolId));
        assertTrue(launchA.positionId != launchB.positionId);

        swap(launchA.poolKey, false, -int256(1e12), "");
        uint256 protocolA = hookV2.pendingProtocolWeth();
        uint256 creatorHookA = hookV2.pendingBeneficiaryWeth(launchA.poolId, beneficiaryA);
        uint256 treasuryBefore = IERC20(launchWeth).balanceOf(treasury);
        uint256 lockerLiabilityBefore = launchFeeLocker.totalLiability();

        swap(launchB.poolKey, false, -int256(2e12), "");
        uint256 protocolB = hookV2.pendingProtocolWeth();
        uint256 creatorHookB = hookV2.pendingBeneficiaryWeth(launchB.poolId, beneficiaryB);

        assertEq(IERC20(launchWeth).balanceOf(treasury) - treasuryBefore, protocolA);
        assertEq(launchFeeLocker.totalLiability(), lockerLiabilityBefore);
        assertEq(hookV2.pendingBeneficiaryWeth(launchA.poolId, beneficiaryA), creatorHookA);
        assertEq(hookV2.pendingBeneficiaryWeth(launchB.poolId, beneficiaryB), creatorHookB);

        vm.prank(keeper);
        (, uint256 collectedLpWethA) = lpLockerV2.collectRewards(launchA.token);
        assertGt(collectedLpWethA, 0);
        uint256 liabilityAfterLpCollection = launchFeeLocker.totalLiability();
        assertEq(launchFeeLocker.feesToClaim(beneficiaryA), collectedLpWethA);

        swap(launchA.poolKey, false, -int256(3e12), "");
        assertEq(IERC20(launchWeth).balanceOf(treasury) - treasuryBefore, protocolA + protocolB);
        assertEq(launchFeeLocker.totalLiability(), liabilityAfterLpCollection);
        assertEq(hookV2.pendingBeneficiaryWeth(launchB.poolId, beneficiaryB), creatorHookB);

        vm.prank(keeper);
        (uint256 protocolPaid, uint256 hookCreatorStored) =
            hookV2.flushPoolFees(launchA.poolId, beneficiaryA);
        assertEq(protocolPaid, 0);
        assertGt(hookCreatorStored, 0);
        assertEq(launchFeeLocker.feesToClaim(beneficiaryA), collectedLpWethA + hookCreatorStored);

        swap(launchA.poolKey, true, -int256(1e16), "");
        vm.prank(keeper);
        (uint256 collectedTokenFees,) = lpLockerV2.collectRewards(launchA.token);
        assertGt(collectedTokenFees, 0);
        assertGt(IERC20(launchA.token).balanceOf(reserve), 0);
        assertGt(IERC20(launchA.token).balanceOf(lpLockerV2.BURN_SINK()), 0);
        assertEq(IERC20(launchA.token).balanceOf(treasury), 0);
        assertEq(manager.balanceOf(address(hookV2), launchA.poolKey.currency0.toId()), 0);
        assertEq(manager.balanceOf(address(hookV2), launchB.poolKey.currency0.toId()), 0);
    }

    function _deployAndApproveTemplateV2() private {
        bytes memory constructorArgs = abi.encode(
            manager, address(launchFactory), launchWeth, treasury, address(launchFeeLocker)
        );
        (address expected, bytes32 salt) = HookMiner.find(
            address(this), _hookFlags(), type(DegenHoodV4HookV2).creationCode, constructorArgs
        );
        hookV2 = new DegenHoodV4HookV2{salt: salt}(
            manager, address(launchFactory), launchWeth, treasury, address(launchFeeLocker)
        );
        assertEq(address(hookV2), expected);

        lpLockerV2 = new DegenHoodV4LpLocker(
            address(launchFactory),
            address(hookV2),
            launchWeth,
            reserve,
            address(launchFeeLocker),
            address(positionManager),
            address(permit2)
        );
        launchFeeLocker.setDepositor(address(hookV2), true);
        launchFeeLocker.setDepositor(address(lpLockerV2), true);
        launchFactory.approveTemplate(TEMPLATE_V2, address(hookV2), address(lpLockerV2));
    }

    function _launch(
        string memory name,
        string memory symbol,
        address feeAdmin,
        address beneficiary,
        bytes32 seed
    ) private returns (IDegenHoodV4Factory.LaunchRecord memory record) {
        IDegenHoodV4Factory.LaunchRequest memory request =
            IDegenHoodV4Factory.LaunchRequest({
                name: name,
                symbol: symbol,
                contractURI: "ipfs://v2-contract",
                imageURI: "ipfs://v2-image",
                launcher: launcher,
                tokenAdmin: tokenAdmin,
                feeAdmin: feeAdmin,
                beneficiary: beneficiary,
                templateId: TEMPLATE_V2,
                userSalt: seed
            });
        request.userSalt = _mineLaunchSalt(request);
        vm.prank(launcher);
        record = launchFactory.launch(request);
    }

    function _hookFlags() private pure returns (uint160) {
        return uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
    }
}
