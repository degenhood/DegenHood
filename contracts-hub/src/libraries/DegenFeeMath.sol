// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {DegenLaunchConstants} from "./DegenLaunchConstants.sol";

/// @title DegenFeeMath
/// @notice Full-precision DEGEN_V1 hook-fee arithmetic shared by quote and settlement paths.
library DegenFeeMath {
    error InvalidRate(uint256 rate);
    error InvalidHookRate(uint256 rate);
    error InvalidTimestamp(uint256 timestamp, uint256 initializedAt);
    error InvalidRealizedFee(uint256 realizedFee, uint256 minimumFee, uint256 maximumFee);

    struct FeeSplit {
        uint256 totalHookFee;
        uint256 permanentFee;
        uint256 temporaryFee;
        uint256 beneficiaryTemporary;
        uint256 treasuryTemporary;
        uint256 permanentTreasury;
        uint256 buybackCredit;
        uint256 roundingDust;
        uint256 treasuryCredit;
    }

    function feeFromGross(uint256 gross, uint256 rate) internal pure returns (uint256) {
        _validateRate(rate);
        return Math.mulDiv(gross, rate, DegenLaunchConstants.RATE_DENOMINATOR);
    }

    function grossFromNet(uint256 net, uint256 rate) internal pure returns (uint256) {
        _validateRate(rate);
        return Math.mulDiv(
            net,
            DegenLaunchConstants.RATE_DENOMINATOR,
            DegenLaunchConstants.RATE_DENOMINATOR - rate,
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
        if (elapsed >= DegenLaunchConstants.LAUNCH_FEE_DURATION) return 0;

        uint256 remaining = DegenLaunchConstants.LAUNCH_FEE_DURATION - elapsed;
        return Math.mulDiv(
            DegenLaunchConstants.MAXIMUM_TEMPORARY_HOOK_RATE,
            remaining * remaining,
            DegenLaunchConstants.LAUNCH_FEE_DURATION * DegenLaunchConstants.LAUNCH_FEE_DURATION
        );
    }

    function totalHookRate(uint256 initializedAt, uint256 timestamp)
        internal
        pure
        returns (uint256)
    {
        return DegenLaunchConstants.PERMANENT_HOOK_RATE + temporaryRate(initializedAt, timestamp);
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

    /// @notice Splits the fee actually realized by an exact-output gross-up.
    /// @dev Gross-up can realize one wei above floor(gross * rate). That rounding wei is credited
    ///      to the treasury, keeping the permanent buyback identity and WETH conservation exact.
    function splitRealizedHookFee(uint256 grossWeth, uint256 totalRate, uint256 realizedFee)
        internal
        pure
        returns (FeeSplit memory)
    {
        _validateHookRate(totalRate);
        uint256 minimumFee = feeFromGross(grossWeth, totalRate);
        uint256 maximumFee = Math.mulDiv(
            grossWeth, totalRate, DegenLaunchConstants.RATE_DENOMINATOR, Math.Rounding.Ceil
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
        split.permanentFee = feeFromGross(grossWeth, DegenLaunchConstants.PERMANENT_HOOK_RATE);
        split.temporaryFee = minimumFee - split.permanentFee;
        split.beneficiaryTemporary = split.temporaryFee / 2;
        split.treasuryTemporary = split.temporaryFee - split.beneficiaryTemporary;

        split.permanentTreasury =
            feeFromGross(grossWeth, DegenLaunchConstants.PERMANENT_TREASURY_RATE);
        split.buybackCredit = split.permanentFee - split.permanentTreasury;
        split.roundingDust = realizedFee - minimumFee;
        split.treasuryCredit =
            split.permanentTreasury + split.treasuryTemporary + split.roundingDust;
    }

    function _validateRate(uint256 rate) private pure {
        if (rate >= DegenLaunchConstants.RATE_DENOMINATOR) revert InvalidRate(rate);
    }

    function _validateHookRate(uint256 rate) private pure {
        if (
            rate < DegenLaunchConstants.PERMANENT_HOOK_RATE
                || rate >= DegenLaunchConstants.RATE_DENOMINATOR
        ) {
            revert InvalidHookRate(rate);
        }
    }
}
