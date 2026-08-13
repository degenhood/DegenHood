// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DegenSpyV1FeeLocker} from "../degen-spy/DegenSpyV1FeeLocker.sol";

/// @title Degen SPY creator-fee locker
/// @notice Versionless production identity for the reviewed immutable-depositor SPY locker.
contract DegenSpyFeeLocker is DegenSpyV1FeeLocker {
    constructor(address spy, address lpLocker, address hook)
        DegenSpyV1FeeLocker(spy, lpLocker, hook)
    {}
}
