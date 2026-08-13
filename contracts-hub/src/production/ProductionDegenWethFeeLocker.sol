// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DegenV1FeeLocker} from "../degen/DegenV1FeeLocker.sol";

/// @title Degen WETH creator-fee locker
/// @notice Versionless production identity for the reviewed immutable-depositor WETH locker.
contract DegenWethFeeLocker is DegenV1FeeLocker {
    constructor(address weth, address lpLocker, address hook)
        DegenV1FeeLocker(weth, lpLocker, hook)
    {}
}
