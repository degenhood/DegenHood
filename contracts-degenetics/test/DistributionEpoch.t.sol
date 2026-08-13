// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DegenhoodDegens} from "../src/DegenhoodDegens.sol";
import {FSMockDegen, FSMockSpy, FSMockEntropy, FSMockPrice} from "./FeeSourceEvents.t.sol";

/// Distribution epoch (spec §8 amendment): the holder share stacks in an on-chain
/// pool until mint-out AND at least one activated Degen, then flushes pro-rata and
/// distribution turns continuous. Zero-weight windows always defer. The treasury
/// NEVER receives the holder share under any condition.
contract DistributionEpochTest is Test {
    uint256 constant BACKING = 66_666_666e18;
    FSMockDegen degen;
    FSMockSpy spy;
    FSMockEntropy entropy;
    FSMockPrice price;
    DegenhoodDegens degens;
    address treasury = makeAddr("treasury");
    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    event Withdrawn(address indexed to, uint256 ethAmt, uint256 spyAmt);

    function setUp() public {
        degen = new FSMockDegen();
        spy = new FSMockSpy();
        entropy = new FSMockEntropy();
        price = new FSMockPrice();
        degens = new DegenhoodDegens(address(degen), address(spy), address(price), address(entropy), treasury, admin);
        degen.mint(alice, 1100 * BACKING);
        degen.mint(bob, 100 * BACKING);
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
        vm.warp(block.timestamp + 12 hours + 1);
        vm.startPrank(alice);
        degen.approve(address(degens), type(uint256).max);
        degens.mintPhase1(500);
        vm.stopPrank();
        vm.prank(bob);
        degen.approve(address(degens), type(uint256).max);
    }

    function _mintOut(address who) internal {
        uint16 remaining = uint16(1000 - degens.minted());
        if (remaining == 0) return;
        vm.prank(who);
        degens.mintPhase2{value: 5 ether}(remaining, 1 ether);
    }

    function _holderCut(uint256 fee) internal pure returns (uint256) {
        return fee * 6666 / 10_000;
    }

    // ---- stacking before mint-out --------------------------------------

    function test_pre_mintout_holder_share_stacks_and_treasury_gets_none_of_it() public {
        uint256 treasuryBefore = treasury.balance;
        vm.prank(alice);
        degens.notifyLpFees{value: 1 ether}();
        uint256 h = _holderCut(1 ether);
        uint256 b = 1 ether * 1667 / 10_000;
        assertEq(degens.pendingHolderEthWei(), h, "holder share parked in the pool");
        assertEq(treasury.balance - treasuryBefore, 1 ether - h - b, "treasury got only its own cut");
        assertFalse(degens.distributionOpened());
    }

    function test_activation_before_mintout_does_not_open_or_flush() public {
        vm.prank(alice);
        degens.notifyEth{value: 1 ether}();
        vm.prank(alice);
        degens.activate(1, 0);
        assertFalse(degens.distributionOpened(), "mint-out not reached");
        assertEq(degens.pendingHolderEthWei(), 1 ether, "pool intact");
        assertEq(degens.pendingEth(1), 0, "nothing distributed yet");
    }

    // ---- opening the epoch ---------------------------------------------

    function test_mintout_with_weight_opens_and_flushes_pool() public {
        vm.prank(alice);
        degens.notifyEth{value: 1 ether}();
        vm.prank(alice);
        degens.activate(1, 0); // 1x weight before mint-out
        _mintOut(alice);
        assertTrue(degens.distributionOpened());
        assertEq(degens.pendingHolderEthWei(), 0, "pool flushed");
        // Sole activated Degen owns the whole pool: the 1 ETH notify plus the
        // holder cut of every phase-2 mint fee (modulo 1e18 accumulator dust).
        uint256 fee = 0.0001 ether * 500; // floor fee x 500 mints
        uint256 expected = 1 ether + _holderCut(fee);
        assertApproxEqAbs(degens.pendingEth(1), expected, 1e6, "flush credited to the activator");
    }

    function test_mintout_without_weight_keeps_stacking_until_first_activation() public {
        _mintOut(alice);
        assertFalse(degens.distributionOpened(), "no weight yet");
        vm.prank(alice);
        degens.notifyEth{value: 2 ether}();
        assertEq(degens.pendingHolderEthWei() > 2 ether, true, "notify + mint fees stacked");
        uint256 pool = degens.pendingHolderEthWei();
        vm.prank(alice);
        degens.activate(1, 0);
        assertTrue(degens.distributionOpened(), "first activation opened it");
        assertEq(degens.pendingHolderEthWei(), 0);
        assertApproxEqAbs(degens.pendingEth(1), pool, 1e6, "whole pool to the first activator");
    }

    // ---- zero-weight windows after opening ------------------------------

    function test_post_open_zero_weight_defers_then_flushes_on_reactivation() public {
        vm.prank(alice);
        degens.activate(1, 0);
        _mintOut(alice);
        assertTrue(degens.distributionOpened());
        // Deactivate the only weight by transferring the token.
        vm.prank(alice);
        degens.transferFrom(alice, bob, 1);
        assertEq(degens.totalWeight(), 0);
        vm.prank(alice);
        degens.notifyEth{value: 1 ether}();
        assertEq(degens.pendingHolderEthWei(), 1 ether, "deferred during the zero-weight window");
        vm.prank(bob);
        degens.activate(1, 0);
        assertEq(degens.pendingHolderEthWei(), 0, "reactivation flushed the pool");
        assertApproxEqAbs(degens.pendingEth(1), 1 ether, 1e6);
    }

    // ---- SPY lane mirrors the epoch --------------------------------------

    function test_spy_defers_pre_open_and_flushes_with_the_pool() public {
        spy.mint(alice, 10e18);
        vm.startPrank(alice);
        spy.approve(address(degens), 10e18);
        degens.notifySpy(10e18);
        vm.stopPrank();
        assertEq(degens.pendingHolderSpyWei(), 10e18, "SPY parked pre mint-out");
        vm.prank(alice);
        degens.activate(1, 0);
        _mintOut(alice);
        assertEq(degens.pendingHolderSpyWei(), 0, "SPY flushed with the epoch");
        assertApproxEqAbs(degens.pendingSpy(1), 10e18, 1e6);
    }

    // ---- claimMany: one tx for a whole bag --------------------------------

    function test_claimMany_credits_every_owned_token_once() public {
        vm.startPrank(alice);
        degens.activate(1, 0);
        degens.activate(2, 0);
        vm.stopPrank();
        _mintOut(alice);
        vm.prank(alice);
        degens.notifyEth{value: 2 ether}();
        uint256 p1 = degens.pendingEth(1);
        uint256 p2 = degens.pendingEth(2);
        assertGt(p1, 0);
        assertGt(p2, 0);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        vm.prank(alice);
        degens.claimMany(ids);
        assertEq(degens.owedEth(alice), p1 + p2, "both credited in one tx");
        assertEq(degens.pendingEth(1), 0);
        assertEq(degens.pendingEth(2), 0);
        // Not the owner of a listed id: whole batch reverts.
        vm.prank(bob);
        vm.expectRevert(DegenhoodDegens.NotOwner.selector);
        degens.claimMany(ids);
    }

    function test_final_mint_via_draw_triggers_the_epoch() public {
        vm.prank(alice);
        degens.activate(1, 0);
        // Mint to 999 directly, then let a vault draw pull the last fresh pack.
        uint16 remaining = uint16(999 - degens.minted());
        vm.prank(alice);
        degens.mintPhase2{value: 5 ether}(remaining, 1 ether);
        assertFalse(degens.distributionOpened(), "one fresh pack left");
        vm.prank(alice);
        uint256 drawId = degens.swapRandom{value: 1 ether}(1 ether);
        degens.finalizeDraw(drawId);
        assertEq(degens.minted(), 1000, "the draw minted the last fresh pack");
        assertTrue(degens.distributionOpened(), "draw-completed mint-out opened the epoch");
        assertEq(degens.pendingHolderEthWei(), 0, "pool flushed");
    }

    // ---- withdrawals are provable ----------------------------------------

    function test_withdraw_emits_withdrawn() public {
        vm.prank(alice);
        degens.activate(1, 0);
        _mintOut(alice);
        vm.prank(alice);
        degens.notifyEth{value: 1 ether}();
        vm.prank(alice);
        degens.claim(1);
        uint256 owed = degens.owedEth(alice);
        assertGt(owed, 0);
        vm.expectEmit(true, false, false, true);
        emit Withdrawn(alice, owed, 0);
        vm.prank(alice);
        degens.withdraw();
    }

    // ---- solvency is untouched by the epoch -------------------------------

    function test_epoch_never_touches_escrow() public {
        uint256 escrowBefore = degens.escrowBalance();
        vm.prank(alice);
        degens.notifyEth{value: 3 ether}();
        vm.prank(alice);
        degens.activate(1, 0);
        _mintOut(alice);
        // escrow grew ONLY by the 500 newly minted backings, never by epoch flows
        assertEq(degens.escrowBalance(), escrowBefore + 500 * BACKING);
    }
}
