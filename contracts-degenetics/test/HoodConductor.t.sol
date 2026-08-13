// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {HoodConductor} from "../src/HoodConductor.sol";

contract HoodConductorTest is Test {
    HoodConductor c;
    address operator = makeAddr("operator");
    address owner = makeAddr("owner");
    address rando = makeAddr("rando");
    bytes32 constant MASTER = keccak256("test-master-secret");

    function seedOf(uint256 i) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(MASTER, i));
    }

    function setUp() public {
        c = new HoodConductor(operator, owner);
        bytes32[] memory hashes = new bytes32[](10);
        for (uint256 i; i < 10; ++i) {
            hashes[i] = keccak256(abi.encodePacked(seedOf(i)));
        }
        vm.prank(operator);
        c.commit(hashes);
    }

    function test_keeperCycle() public {
        vm.prank(operator);
        c.reveal(seedOf(0));
        (,, uint64 target,) = c.rounds(0);
        assertEq(target, uint64(block.number) + c.TARGET_DELAY());
        vm.expectRevert(HoodConductor.NotReady.selector);
        c.snap();
        vm.roll(target + 1);
        c.snap();
        assertEq(c.currentRound(), 1);
        bytes32 w = c.entropyOf(1);
        assertTrue(w != bytes32(0));
    }

    function test_wordDependsOnFutureBlockhash() public {
        vm.prank(operator);
        c.reveal(seedOf(0));
        (,, uint64 target,) = c.rounds(0);
        vm.roll(target + 1);
        vm.setBlockhash(target, keccak256("history-A"));
        uint256 snapA = vm.snapshotState();
        c.snap();
        bytes32 wordA = c.entropyOf(1);
        vm.revertToState(snapA);
        vm.setBlockhash(target, keccak256("history-B"));
        c.snap();
        bytes32 wordB = c.entropyOf(1);
        assertTrue(wordA != wordB, "word must depend on target blockhash");
    }

    function test_badRevealRejected() public {
        vm.prank(operator);
        vm.expectRevert(HoodConductor.BadReveal.selector);
        c.reveal(keccak256("wrong seed"));
    }

    function test_onlyOperator() public {
        bytes32[] memory h = new bytes32[](1);
        h[0] = bytes32(uint256(1));
        vm.prank(rando);
        vm.expectRevert(HoodConductor.NotOperator.selector);
        c.commit(h);
        vm.prank(rando);
        vm.expectRevert(HoodConductor.NotOperator.selector);
        c.reveal(seedOf(0));
    }

    function test_rearmAfterMissedWindow() public {
        vm.prank(operator);
        c.reveal(seedOf(0));
        (,, uint64 target,) = c.rounds(0);
        vm.roll(target + 300);
        vm.expectRevert(HoodConductor.NotReady.selector);
        c.snap();
        vm.prank(rando);
        c.rearm();
        (,, uint64 newTarget,) = c.rounds(0);
        assertEq(newTarget, uint64(block.number) + c.TARGET_DELAY());
        vm.roll(newTarget + 1);
        vm.setBlockhash(newTarget, keccak256("later-history"));
        c.snap();
        assertEq(c.currentRound(), 1);
    }

    function test_sequentialReveals() public {
        vm.startPrank(operator);
        vm.expectRevert(HoodConductor.BadReveal.selector);
        c.reveal(seedOf(1));
        c.reveal(seedOf(0));
        vm.stopPrank();
    }

    function test_nextRoundAlwaysUnrevealed() public {
        assertEq(c.nextRound(), 1);
        vm.prank(operator);
        c.reveal(seedOf(0));
        assertEq(c.nextRound(), 2);
    }

    function test_gas_revealAndSnap() public {
        vm.prank(operator);
        uint256 g0 = gasleft();
        c.reveal(seedOf(0));
        uint256 revealGas = g0 - gasleft();
        (,, uint64 target,) = c.rounds(0);
        vm.roll(target + 1);
        g0 = gasleft();
        c.snap();
        uint256 snapGas = g0 - gasleft();
        emit log_named_uint("reveal gas", revealGas);
        emit log_named_uint("snap gas", snapGas);
        assertLt(revealGas + snapGas, 200_000, "keeper cycle should stay cheap");
    }

    function test_operator_rotation_owner_only_and_effective() public {
        c = new HoodConductor(operator, owner); // fresh instance - clean round state
        address next = makeAddr("next-keeper");
        vm.prank(operator); // the hot key cannot rotate itself
        vm.expectRevert(HoodConductor.NotOwner.selector);
        c.setOperator(next);
        vm.prank(owner);
        c.setOperator(next);
        assertEq(c.operator(), next);
        // Old key is dead, new key runs the loop.
        bytes32 seed = keccak256("s");
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = keccak256(abi.encodePacked(seed));
        vm.prank(operator);
        vm.expectRevert(HoodConductor.NotOperator.selector);
        c.commit(hashes);
        vm.startPrank(next);
        c.commit(hashes);
        c.reveal(seed);
        vm.stopPrank();
        assertEq(c.revealedCount(), 1);
    }
}
