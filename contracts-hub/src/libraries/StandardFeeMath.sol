// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {StandardLaunchConstants} from "./StandardLaunchConstants.sol";

/// @notice Full-precision STANDARD_V1 hook fee arithmetic.
library StandardFeeMath {
    error InvalidRate(uint256 rate);
    error InvalidHookRate(uint256 rate);
    error InvalidTimestamp(uint256 timestamp, uint256 initializedAt);
    error InvalidRealizedFee(uint256 realizedFee, uint256 minimumFee, uint256 maximumFee);

    struct FeeSplit {
        uint256 totalHookFee;
        uint256 permanentFee;
        uint256 temporaryFee;
        uint256 beneficiaryTemporary;
        uint256 protocolTemporary;
        uint256 roundingDust;
        uint256 protocolCredit;
    }

    function feeFromGross(uint256 gross, uint256 rate) internal pure returns (uint256) {
        _validateRate(rate);
        return Math.mulDiv(gross, rate, StandardLaunchConstants.RATE_DENOMINATOR);
    }

    function grossFromNet(uint256 net, uint256 rate) internal pure returns (uint256) {
        _validateRate(rate);
        return Math.mulDiv(
            net,
            StandardLaunchConstants.RATE_DENOMINATOR,
            StandardLaunchConstants.RATE_DENOMINATOR - rate,
            Math.Rounding.Ceil
        );
    }

    function temporaryRate(uint256 initializedAt, uint256 timestamp)
        internal
        pure
        returns (uint256)
    {
        if (timestamp < initializedAt) {
            revert InvalidTimestamp(timestamp, initializedAt);
        }
        uint256 elapsed = timestamp - initializedAt;
        if (elapsed >= StandardLaunchConstants.LAUNCH_FEE_DURATION) return 0;
        uint256 remaining = StandardLaunchConstants.LAUNCH_FEE_DURATION - elapsed;
        return Math.mulDiv(
            StandardLaunchConstants.MAXIMUM_TEMPORARY_HOOK_RATE,
            remaining * remaining,
            StandardLaunchConstants.LAUNCH_FEE_DURATION
                * StandardLaunchConstants.LAUNCH_FEE_DURATION
        );
    }

    function totalHookRate(uint256 initializedAt, uint256 timestamp)
        internal
        pure
        returns (uint256)
    {
        return StandardLaunchConstants.PERMANENT_HOOK_RATE + temporaryRate(initializedAt, timestamp);
    }

    function splitHookFee(uint256 grossWeth, uint256 totalRate)
        internal
        pure
        returns (FeeSplit memory)
    {
        _validateHookRate(totalRate);
        uint256 realizedFee = feeFromGross(grossWeth, totalRate);
        return _splitRealizedHookFee(grossWeth, realizedFee, realizedFee);
    }

    function splitRealizedHookFee(uint256 grossWeth, uint256 totalRate, uint256 realizedFee)
        internal
        pure
        returns (FeeSplit memory)
    {
        _validateHookRate(totalRate);
        uint256 minimumFee = feeFromGross(grossWeth, totalRate);
        uint256 maximumFee = Math.mulDiv(
            grossWeth, totalRate, StandardLaunchConstants.RATE_DENOMINATOR, Math.Rounding.Ceil
        );
        if (realizedFee < minimumFee || realizedFee > maximumFee) {
            revert InvalidRealizedFee(realizedFee, minimumFee, maximumFee);
        }
        return _splitRealizedHookFee(grossWeth, realizedFee, minimumFee);
    }

    function _splitRealizedHookFee(uint256 grossWeth, uint256 realizedFee, uint256 minimumFee)
        private
        pure
        returns (FeeSplit memory split)
    {
        split.totalHookFee = realizedFee;
        split.permanentFee = feeFromGross(grossWeth, StandardLaunchConstants.PERMANENT_HOOK_RATE);
        split.temporaryFee = minimumFee - split.permanentFee;
        split.beneficiaryTemporary = split.temporaryFee / 2;
        split.protocolTemporary = split.temporaryFee - split.beneficiaryTemporary;
        split.roundingDust = realizedFee - minimumFee;
        split.protocolCredit = split.permanentFee + split.protocolTemporary + split.roundingDust;
    }

    function _validateRate(uint256 rate) private pure {
        if (rate >= StandardLaunchConstants.RATE_DENOMINATOR) revert InvalidRate(rate);
    }

    function _validateHookRate(uint256 rate) private pure {
        if (
            rate < StandardLaunchConstants.PERMANENT_HOOK_RATE
                || rate >= StandardLaunchConstants.RATE_DENOMINATOR
        ) {
            revert InvalidHookRate(rate);
        }
    }
}
