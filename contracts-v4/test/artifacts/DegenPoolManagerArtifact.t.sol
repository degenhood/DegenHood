// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Separate compilation root for the pinned PoolManager creation artifact.
contract DegenPoolManagerArtifactTest is Test {
    function testPinnedPoolManagerCreationCodeIsAvailable() public pure {
        assertGt(type(PoolManager).creationCode.length, 0);
        assertGt(type(PositionManager).creationCode.length, 0);
    }
}
