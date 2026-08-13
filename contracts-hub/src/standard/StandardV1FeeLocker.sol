// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DegenV1FeeLocker} from "../degen/DegenV1FeeLocker.sol";

/// @notice STANDARD_V1 instance type for the shared immutable fee-locker behavior.
contract StandardV1FeeLocker is DegenV1FeeLocker {
    constructor(address weth, address lpLocker, address hook)
        DegenV1FeeLocker(weth, lpLocker, hook)
    {}
}
