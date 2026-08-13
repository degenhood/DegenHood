// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

contract DegenV3HookBindingMock {
    address public immutable module;
    address public immutable poolManager;
    address public immutable feeLocker;

    constructor(address module_, address poolManager_, address feeLocker_) {
        module = module_;
        poolManager = poolManager_;
        feeLocker = feeLocker_;
    }
}

contract DegenV3LockerBindingMock {
    address public immutable module;
    address public immutable hook;
    address public immutable feeLocker;
    address public immutable positionManager;
    address public immutable tokenReserve;

    constructor(
        address module_,
        address hook_,
        address feeLocker_,
        address positionManager_,
        address tokenReserve_
    ) {
        module = module_;
        hook = hook_;
        feeLocker = feeLocker_;
        positionManager = positionManager_;
        tokenReserve = tokenReserve_;
    }
}

contract DegenSpyV3HookBindingMock {
    address public immutable module;
    address public immutable poolManager;
    address public immutable feeLocker;
    address public immutable spy;

    constructor(address module_, address poolManager_, address feeLocker_, address spy_) {
        module = module_;
        poolManager = poolManager_;
        feeLocker = feeLocker_;
        spy = spy_;
    }
}

contract DegenSpyV3LockerBindingMock {
    address public immutable module;
    address public immutable hook;
    address public immutable feeLocker;
    address public immutable positionManager;
    address public immutable tokenReserve;
    address public immutable spy;

    constructor(
        address module_,
        address hook_,
        address feeLocker_,
        address positionManager_,
        address tokenReserve_,
        address spy_
    ) {
        module = module_;
        hook = hook_;
        feeLocker = feeLocker_;
        positionManager = positionManager_;
        tokenReserve = tokenReserve_;
        spy = spy_;
    }
}
