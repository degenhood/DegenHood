// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {DegenFeeMath} from "../src/libraries/DegenFeeMath.sol";
import {DegenLaunchConstants} from "../src/libraries/DegenLaunchConstants.sol";

contract DegenFeeMathHarness {
    function feeFromGross(uint256 gross, uint256 rate) external pure returns (uint256) {
        return DegenFeeMath.feeFromGross(gross, rate);
    }

    function grossFromNet(uint256 net, uint256 rate) external pure returns (uint256) {
        return DegenFeeMath.grossFromNet(net, rate);
    }

    function temporaryRate(uint256 initializedAt, uint256 timestamp)
        external
        pure
        returns (uint256)
    {
        return DegenFeeMath.temporaryRate(initializedAt, timestamp);
    }

    function splitRealizedHookFee(uint256 gross, uint256 rate, uint256 realizedFee)
        external
        pure
        returns (DegenFeeMath.FeeSplit memory)
    {
        return DegenFeeMath.splitRealizedHookFee(gross, rate, realizedFee);
    }
}

contract DegenFeeMathTest is Test {
    DegenFeeMathHarness private harness;

    function setUp() public {
        harness = new DegenFeeMathHarness();
    }

    function testFeeFromGrossRoundsDown() public pure {
        assertEq(DegenFeeMath.feeFromGross(999, 5000), 4);
    }

    function testGrossFromNetRoundsUp() public pure {
        assertEq(DegenFeeMath.grossFromNet(1, 5000), 2);
        assertEq(DegenFeeMath.grossFromNet(995, 5000), 1000);
    }

    function testZeroAndOneWeiInputs() public pure {
        assertEq(DegenFeeMath.feeFromGross(0, 5000), 0);
        assertEq(DegenFeeMath.grossFromNet(0, 5000), 0);
        assertEq(DegenFeeMath.feeFromGross(1, 5000), 0);
        assertEq(DegenFeeMath.grossFromNet(1, 5000), 2);
    }

    function testRejectsRateAtOrAboveDenominator() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DegenFeeMath.InvalidRate.selector, DegenLaunchConstants.RATE_DENOMINATOR
            )
        );
        harness.feeFromGross(1 ether, DegenLaunchConstants.RATE_DENOMINATOR);

        vm.expectRevert(
            abi.encodeWithSelector(
                DegenFeeMath.InvalidRate.selector, DegenLaunchConstants.RATE_DENOMINATOR + 1
            )
        );
        harness.grossFromNet(1 ether, DegenLaunchConstants.RATE_DENOMINATOR + 1);
    }

    function testHandlesMaximumSignedSwapAmountWithoutIntermediateOverflow() public pure {
        uint256 maximumSignedAmount = uint256(uint128(type(int128).max));
        uint256 fee = DegenFeeMath.feeFromGross(maximumSignedAmount, 800_000);
        uint256 gross = DegenFeeMath.grossFromNet(maximumSignedAmount, 800_000);

        assertEq(fee, maximumSignedAmount * 4 / 5);
        assertEq(gross, maximumSignedAmount * 5);
    }

    function testPermanentHookThenLpFeeComposition() public pure {
        uint256 grossWeth = 1 ether;
        uint256 hookFee =
            DegenFeeMath.feeFromGross(grossWeth, DegenLaunchConstants.PERMANENT_HOOK_RATE);
        uint256 poolWeth = grossWeth - hookFee;
        uint256 lpFee = DegenFeeMath.feeFromGross(poolWeth, DegenLaunchConstants.LP_FEE_RATE);

        assertEq(hookFee, 0.005 ether);
        assertEq(lpFee, 0.006_965 ether);
        assertEq(poolWeth - lpFee, 0.988_035 ether);
        assertEq(grossWeth, hookFee + lpFee + (poolWeth - lpFee));
    }

    function testFuzzGrossUpConservesAndIsMinimal(uint128 rawNet, uint32 rawRate) public pure {
        uint256 net = uint256(rawNet);
        uint256 rate = uint256(rawRate) % 800_001;
        uint256 gross = DegenFeeMath.grossFromNet(net, rate);
        uint256 realizedFee = gross - net;
        uint256 expectedRoundedUpFee = (gross * rate + DegenLaunchConstants.RATE_DENOMINATOR - 1)
            / DegenLaunchConstants.RATE_DENOMINATOR;

        assertEq(realizedFee, expectedRoundedUpFee);
        assertEq(gross - realizedFee, net);

        if (gross != 0) {
            uint256 previousNet = (gross - 1) * (DegenLaunchConstants.RATE_DENOMINATOR - rate)
                / DegenLaunchConstants.RATE_DENOMINATOR;
            assertLt(previousNet, net);
        }
    }

    function testLaunchCurveExactBoundaries() public pure {
        uint256 initializedAt = 1000;
        uint256[11] memory elapsed = [uint256(0), 1, 3, 5, 10, 15, 20, 25, 29, 30, 31];
        uint256[11] memory expectedTemporary = [
            uint256(795_000), 742_883, 643_950, 552_083, 353_333, 198_750, 88_333, 22_083, 883, 0, 0
        ];

        for (uint256 i; i < elapsed.length; ++i) {
            uint256 temporary =
                DegenFeeMath.temporaryRate(initializedAt, initializedAt + elapsed[i]);
            assertEq(temporary, expectedTemporary[i]);
            assertEq(
                DegenFeeMath.totalHookRate(initializedAt, initializedAt + elapsed[i]),
                DegenLaunchConstants.PERMANENT_HOOK_RATE + expectedTemporary[i]
            );
        }
    }

    function testLaunchCurveStartsAtEightyPercentAndClampsAfterThirtySeconds() public pure {
        assertEq(DegenFeeMath.temporaryRate(100, 100), 795_000);
        assertEq(DegenFeeMath.totalHookRate(100, 100), 800_000);
        assertEq(DegenFeeMath.temporaryRate(100, 130), 0);
        assertEq(DegenFeeMath.totalHookRate(100, type(uint256).max), 5000);
    }

    function testLaunchCurveRejectsTimestampBeforeInitialization() public {
        vm.expectRevert(abi.encodeWithSelector(DegenFeeMath.InvalidTimestamp.selector, 99, 100));
        harness.temporaryRate(100, 99);
    }

    function testLaunchCurveIsMonotonic() public pure {
        uint256 previous = DegenFeeMath.temporaryRate(10_000, 10_000);
        for (uint256 elapsed = 1; elapsed <= 60; ++elapsed) {
            uint256 current = DegenFeeMath.temporaryRate(10_000, 10_000 + elapsed);
            assertLe(current, previous);
            previous = current;
        }
    }

    function testExactInputSplitUsesFloorAndTemporaryDustFavorsProtocol() public pure {
        DegenFeeMath.FeeSplit memory split = DegenFeeMath.splitHookFee(1_000_001, 800_000);

        assertEq(split.totalHookFee, 800_000);
        assertEq(split.permanentFee, 5000);
        assertEq(split.temporaryFee, 795_000);
        assertEq(split.beneficiaryTemporary, 397_500);
        assertEq(split.protocolTemporary, 397_500);
        assertEq(split.roundingDust, 0);
        assertEq(split.protocolCredit, 402_500);

        split = DegenFeeMath.splitHookFee(3, 800_000);
        assertEq(split.totalHookFee, 2);
        assertEq(split.temporaryFee, 2);
        assertEq(split.beneficiaryTemporary, 1);
        assertEq(split.protocolTemporary, 1);
    }

    function testExactOutputRoundingDustFavorsProtocol() public pure {
        uint256 net = 1;
        uint256 gross = DegenFeeMath.grossFromNet(net, 5000);
        DegenFeeMath.FeeSplit memory split =
            DegenFeeMath.splitRealizedHookFee(gross, 5000, gross - net);

        assertEq(gross, 2);
        assertEq(split.totalHookFee, 1);
        assertEq(split.permanentFee, 0);
        assertEq(split.temporaryFee, 0);
        assertEq(split.roundingDust, 1);
        assertEq(split.protocolCredit, 1);
        assertEq(split.beneficiaryTemporary, 0);
    }

    function testRejectsInconsistentRealizedFee() public {
        vm.expectRevert(abi.encodeWithSelector(DegenFeeMath.InvalidRealizedFee.selector, 6, 5, 5));
        harness.splitRealizedHookFee(1000, 5000, 6);
    }

    function testFuzzFeeAllocationConservesWeth(uint128 rawGross, uint8 rawElapsed) public pure {
        uint256 gross = uint256(rawGross);
        uint256 elapsed = uint256(rawElapsed);
        uint256 rate = DegenFeeMath.totalHookRate(1000, 1000 + elapsed);
        DegenFeeMath.FeeSplit memory split = DegenFeeMath.splitHookFee(gross, rate);
        uint256 poolWeth = gross - split.totalHookFee;

        assertEq(split.temporaryFee, split.beneficiaryTemporary + split.protocolTemporary);
        assertEq(split.totalHookFee, split.permanentFee + split.temporaryFee + split.roundingDust);
        assertEq(split.protocolCredit, split.permanentFee + split.protocolTemporary);
        assertEq(gross, poolWeth + split.beneficiaryTemporary + split.protocolCredit);
    }

    function testFuzzExactOutputAllocationConservesWeth(uint128 rawNet, uint8 rawElapsed)
        public
        pure
    {
        uint256 net = uint256(rawNet);
        uint256 elapsed = uint256(rawElapsed);
        uint256 rate = DegenFeeMath.totalHookRate(1000, 1000 + elapsed);
        uint256 gross = DegenFeeMath.grossFromNet(net, rate);
        DegenFeeMath.FeeSplit memory split =
            DegenFeeMath.splitRealizedHookFee(gross, rate, gross - net);

        assertEq(split.temporaryFee, split.beneficiaryTemporary + split.protocolTemporary);
        assertEq(split.totalHookFee, split.permanentFee + split.temporaryFee + split.roundingDust);
        assertEq(
            split.protocolCredit, split.permanentFee + split.protocolTemporary + split.roundingDust
        );
        assertEq(gross, net + split.beneficiaryTemporary + split.protocolCredit);
    }
}
