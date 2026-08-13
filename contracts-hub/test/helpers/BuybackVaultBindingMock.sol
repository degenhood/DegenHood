// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

contract BuybackVaultBindingMock {
    IPoolManager public immutable poolManager;
    address public immutable degen;
    address public immutable weth;
    PoolId public immutable poolId;

    constructor(IPoolManager poolManager_, address degen_, address weth_) {
        poolManager = poolManager_;
        degen = degen_;
        weth = weth_;
        poolId = PoolId.wrap(keccak256(abi.encode(poolManager_, degen_, weth_)));
    }

    function burnSink() external pure returns (address) {
        return 0x000000000000000000000000000000000000dEaD;
    }
}
