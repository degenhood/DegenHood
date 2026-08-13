// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {HoodFeeFlusher} from "../src/HoodFeeFlusher.sol";

contract MockLpLocker {
    bool public shouldRevert;
    uint256 public calls;

    function setRevert(bool v) external {
        shouldRevert = v;
    }

    function collectRewards(address) external returns (uint256, uint256) {
        if (shouldRevert) revert("no position");
        ++calls;
        return (0, 1 ether);
    }
}

contract MockFeeLocker {
    bool public shouldRevert;
    uint256 public calls;

    function setRevert(bool v) external {
        shouldRevert = v;
    }

    function claimFor(address) external returns (uint256) {
        if (shouldRevert) revert("nothing");
        ++calls;
        return 1 ether;
    }
}

contract MockForwarder {
    bool public shouldRevert;
    uint256 public calls;

    function setRevert(bool v) external {
        shouldRevert = v;
    }

    function forward() external {
        if (shouldRevert) revert("empty");
        ++calls;
    }
}

contract HoodFeeFlusherTest is Test {
    HoodFeeFlusher flusher;
    MockLpLocker lp;
    MockFeeLocker fee;
    MockForwarder fwd;
    address token = makeAddr("degen");
    address anyone = makeAddr("anyone");

    event Flushed(address indexed caller, bool harvested, bool claimed, bool routed);

    function setUp() public {
        lp = new MockLpLocker();
        fee = new MockFeeLocker();
        fwd = new MockForwarder();
        flusher = new HoodFeeFlusher(address(lp), address(fee), address(fwd), token);
    }

    function test_one_call_runs_every_stage_for_anyone() public {
        vm.expectEmit(true, false, false, true);
        emit Flushed(anyone, true, true, true);
        vm.prank(anyone);
        (bool h, bool c, bool r) = flusher.flush();
        assertTrue(h && c && r);
        assertEq(lp.calls(), 1);
        assertEq(fee.calls(), 1);
        assertEq(fwd.calls(), 1);
    }

    function test_a_failing_stage_never_blocks_the_others() public {
        lp.setRevert(true); // nothing to harvest
        vm.prank(anyone);
        (bool h, bool c, bool r) = flusher.flush();
        assertFalse(h);
        assertTrue(c, "claim still ran");
        assertTrue(r, "route still ran");
    }

    function test_all_stages_idle_is_a_clean_noop() public {
        lp.setRevert(true);
        fee.setRevert(true);
        fwd.setRevert(true);
        vm.prank(anyone);
        (bool h, bool c, bool r) = flusher.flush();
        assertFalse(h || c || r);
    }

    function test_constructor_rejects_zero_wiring() public {
        vm.expectRevert(bytes("zero"));
        new HoodFeeFlusher(address(0), address(fee), address(fwd), token);
    }
}
