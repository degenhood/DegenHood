// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPriceSource, IV4StateView} from "./interfaces/IPriceSource.sol";

/// @notice Reads the DEGEN/WETH v4 pool's sqrtPrice directly from chain state.
/// No keeper, no push oracle, nothing to go stale. Immutable addresses.
contract V4PriceSource is IPriceSource {
    IV4StateView public immutable stateView;
    bytes32 public immutable poolId;

    constructor(address stateView_, bytes32 poolId_) {
        stateView = IV4StateView(stateView_);
        poolId = poolId_;
    }

    function sqrtPriceX96() external view returns (uint160 sp) {
        (sp,,,) = stateView.getSlot0(poolId);
        require(sp != 0, "pool uninitialized");
    }
}
