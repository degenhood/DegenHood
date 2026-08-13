// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DegenHoodTokenV4} from "../src/DegenHoodTokenV4.sol";
import {DegenHoodV4Hook} from "../src/DegenHoodV4Hook.sol";
import {DegenHoodV4LpLocker} from "../src/DegenHoodV4LpLocker.sol";
import {IDegenHoodV4Factory} from "../src/interfaces/IDegenHoodV4Factory.sol";
import {IDegenHoodV4Hook} from "../src/interfaces/IDegenHoodV4Hook.sol";
import {IDegenHoodV4LpLocker} from "../src/interfaces/IDegenHoodV4LpLocker.sol";
import {DegenV4LaunchFixture} from "./helpers/DegenV4LaunchFixture.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

contract DegenHoodV4IntegrationTest is DegenV4LaunchFixture {
    using StateLibrary for IPoolManager;

    address private launcher = makeAddr("integrationLauncher");
    address private tokenAdmin = makeAddr("integrationTokenAdmin");
    address private nextTokenAdmin = makeAddr("integrationNextTokenAdmin");
    address private feeAdmin = makeAddr("integrationFeeAdmin");
    address private beneficiary = makeAddr("integrationBeneficiary");
    address private nextBeneficiary = makeAddr("integrationNextBeneficiary");
    address private treasury = makeAddr("integrationTreasury");
    address private reserve = makeAddr("integrationReserve");
    address private keeper = makeAddr("integrationKeeper");

    IDegenHoodV4Factory.LaunchRecord private record;
    DegenHoodTokenV4 private token;

    function setUp() public {
        _setUpLaunchSystem(treasury, reserve, address(this));
        vm.warp(10_000);
        IDegenHoodV4Factory.LaunchRequest memory request = IDegenHoodV4Factory.LaunchRequest({
            name: "Integration Token",
            symbol: "INT",
            contractURI: "ipfs://integration-contract",
            imageURI: "ipfs://integration-image",
            launcher: launcher,
            tokenAdmin: tokenAdmin,
            feeAdmin: feeAdmin,
            beneficiary: beneficiary,
            templateId: 1,
            userSalt: bytes32(0)
        });
        request.userSalt = _mineLaunchSalt(request);
        vm.prank(launcher);
        record = launchFactory.launch(request);
        token = DegenHoodTokenV4(record.token);
        token.approve(address(swapRouter), type(uint256).max);
    }

    function test_endToEnd_allModesRolesClaimsAndFutureTemplateIsolation() public {
        _exerciseAllFourModes();
        assertEq(launchHook.getPoolConfig(record.poolId).initializedAt, 10_000);

        vm.warp(10_030);
        _exerciseAllFourModes();
        assertGt(launchHook.totalWethFeesAccrued(record.poolId), 0);

        vm.prank(keeper);
        launchLpLocker.collectRewards(record.token);
        vm.prank(keeper);
        launchHook.flushPoolFees(record.poolId, beneficiary);
        uint256 firstOldCredit = launchFeeLocker.feesToClaim(beneficiary);
        assertGt(firstOldCredit, 0);
        assertGt(IERC20(record.token).balanceOf(reserve), 0);
        assertGt(IERC20(record.token).balanceOf(launchLpLocker.BURN_SINK()), 0);
        assertGt(IERC20(launchWeth).balanceOf(treasury), 0);

        swap(record.poolKey, false, -int256(1e12), "");
        vm.prank(feeAdmin);
        launchLpLocker.updateBeneficiary(record.token, nextBeneficiary);
        uint256 finalOldCredit = launchFeeLocker.feesToClaim(beneficiary);
        assertGt(finalOldCredit, firstOldCredit);
        assertEq(launchLpLocker.positionForToken(record.token).beneficiary, nextBeneficiary);
        assertEq(launchHook.getPoolConfig(record.poolId).beneficiary, nextBeneficiary);

        swap(record.poolKey, false, -int256(1e12), "");
        vm.prank(keeper);
        launchLpLocker.collectRewards(record.token);
        vm.prank(keeper);
        launchHook.flushPoolFees(record.poolId, nextBeneficiary);
        uint256 newCredit = launchFeeLocker.feesToClaim(nextBeneficiary);
        assertGt(newCredit, 0);

        vm.prank(keeper);
        launchFeeLocker.claimFor(beneficiary);
        vm.prank(keeper);
        launchFeeLocker.claimFor(nextBeneficiary);
        assertEq(IERC20(launchWeth).balanceOf(beneficiary), finalOldCredit);
        assertEq(IERC20(launchWeth).balanceOf(nextBeneficiary), newCredit);
        assertEq(launchFeeLocker.feesToClaim(beneficiary), 0);
        assertEq(launchFeeLocker.feesToClaim(nextBeneficiary), 0);

        vm.prank(tokenAdmin);
        token.updateMetadata("ipfs://updated", "ipfs://updated-image");
        vm.prank(tokenAdmin);
        token.transferTokenAdmin(nextTokenAdmin);
        vm.prank(nextTokenAdmin);
        token.updateMetadata("ipfs://next-admin", "ipfs://next-admin-image");
        assertEq(token.tokenAdmin(), nextTokenAdmin);
        assertEq(token.contractURI(), "ipfs://next-admin");

        (uint160 priceBefore, int24 tickBefore,, uint24 lpFeeBefore) =
            manager.getSlot0(record.poolId);
        IDegenHoodV4Hook.PoolConfig memory hookBefore = launchHook.getPoolConfig(record.poolId);
        IDegenHoodV4LpLocker.PositionConfig memory positionBefore =
            launchLpLocker.positionForToken(record.token);
        (DegenHoodV4Hook futureHook, DegenHoodV4LpLocker futureLocker,) = _newTemplate(2);

        (uint160 priceAfter, int24 tickAfter,, uint24 lpFeeAfter) = manager.getSlot0(record.poolId);
        IDegenHoodV4Hook.PoolConfig memory hookAfter = launchHook.getPoolConfig(record.poolId);
        IDegenHoodV4LpLocker.PositionConfig memory positionAfter =
            launchLpLocker.positionForToken(record.token);
        assertTrue(address(futureHook) != address(launchHook));
        assertTrue(address(futureLocker) != address(launchLpLocker));
        assertEq(priceAfter, priceBefore);
        assertEq(tickAfter, tickBefore);
        assertEq(lpFeeAfter, lpFeeBefore);
        assertEq(hookAfter.initializedAt, hookBefore.initializedAt);
        assertEq(hookAfter.beneficiary, hookBefore.beneficiary);
        assertEq(positionAfter.positionId, positionBefore.positionId);
        assertEq(positionAfter.beneficiary, positionBefore.beneficiary);
        assertEq(
            IERC721(address(positionManager)).ownerOf(positionAfter.positionId),
            address(launchLpLocker)
        );
    }

    function _exerciseAllFourModes() private {
        BalanceDelta exactInputBuy = swap(record.poolKey, false, -int256(1e12), "");
        BalanceDelta exactOutputBuy = swap(record.poolKey, false, int256(1e16), "");
        assertGt(exactInputBuy.amount0(), 0);
        assertLt(exactInputBuy.amount1(), 0);
        assertEq(exactOutputBuy.amount0(), int128(int256(1e16)));

        BalanceDelta exactInputSell = swap(record.poolKey, true, -int256(1e16), "");
        BalanceDelta exactOutputSell = swap(record.poolKey, true, int256(1e6), "");
        assertLt(exactInputSell.amount0(), 0);
        assertGt(exactInputSell.amount1(), 0);
        assertEq(exactOutputSell.amount1(), int128(int256(1e6)));
    }
}
