// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Test} from "forge-std/Test.sol";
import {Permit2} from "permit2/src/Permit2.sol";

/// @notice Separate compilation root for the pinned Permit2 creation artifact.
contract DegenPermit2ArtifactTest is Test {
    function testPinnedPermit2CreationCodeIsAvailable() public pure {
        assertGt(type(Permit2).creationCode.length, 0);
    }
}
