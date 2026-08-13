// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

contract DegenSpyBuybackVaultBindingMock {
    address public immutable v3Factory;
    address public immutable degen;
    address public immutable spy;

    constructor(address v3Factory_, address degen_, address spy_) {
        v3Factory = v3Factory_;
        degen = degen_;
        spy = spy_;
    }

    function poolFee() external pure returns (uint24) {
        return 10_000;
    }

    function tickSpacing() external pure returns (int24) {
        return 200;
    }

    function burnSink() external pure returns (address) {
        return 0x000000000000000000000000000000000000dEaD;
    }
}
