// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DegenhoodDegens} from "../src/DegenhoodDegens.sol";
import {IEntropySource} from "../src/interfaces/IEntropySource.sol";
import {IPriceSource} from "../src/interfaces/IPriceSource.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract EFMockDegen is ERC20("DegenHood", "DEGEN") {
    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

contract EFMockSpy is ERC20("SPY", "SPY") {
    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

contract EFMockEntropy is IEntropySource {
    uint64 public round = 100;

    function tick() external {
        ++round;
    }

    function currentRound() external view returns (uint64) {
        return round;
    }

    function nextRound() external view returns (uint64) {
        return round + 1;
    }

    function entropyOf(uint64 r) external pure returns (bytes32) {
        return keccak256(abi.encode("e", r));
    }
}

contract EFMockPrice is IPriceSource {
    uint160 public sp = uint160(1) << 48;

    function set(uint160 v) external {
        sp = v;
    }

    function sqrtPriceX96() external view returns (uint160) {
        return sp;
    }
}

/// Edge + fuzz coverage for the pre-deploy checklist: fee clamps and slippage under
/// arbitrary pool prices, exact router splits, redeem round-trips, duplicate-id
/// claim batches, and epoch value conservation under fuzzed weights.
contract EdgeFuzzTest is Test {
    uint256 constant BACKING = 66_666_666e18;
    EFMockDegen degen;
    EFMockSpy spy;
    EFMockEntropy entropy;
    EFMockPrice price;
    DegenhoodDegens degens;
    address treasury = makeAddr("treasury");
    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        degen = new EFMockDegen();
        spy = new EFMockSpy();
        entropy = new EFMockEntropy();
        price = new EFMockPrice();
        degens = new DegenhoodDegens(address(degen), address(spy), address(price), address(entropy), treasury, admin);
        degen.mint(alice, 1200 * BACKING);
        degen.mint(bob, 100 * BACKING);
        vm.deal(alice, 20_000 ether);
        vm.deal(bob, 1000 ether);
        vm.warp(block.timestamp + 12 hours + 1);
        vm.startPrank(alice);
        degen.approve(address(degens), type(uint256).max);
        degens.mintPhase1(500);
        vm.stopPrank();
        vm.prank(bob);
        degen.approve(address(degens), type(uint256).max);
    }

    // ---- fee clamps + slippage guard under arbitrary prices ---------------

    function testFuzz_fee_always_within_floor_and_cap(uint160 sqrtPrice) public {
        sqrtPrice = uint160(bound(uint256(sqrtPrice), 1, type(uint160).max));
        price.set(sqrtPrice);
        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        degens.mintPhase2{value: 10 ether}(1, 10 ether);
        uint256 paid = balanceBefore - alice.balance;
        assertGe(paid, 0.0001 ether, "fee floor holds at any price");
        assertLe(paid, 10 ether, "fee cap holds at any price");
    }

    function test_maxFeeWei_slippage_guard_reverts() public {
        // Price implies a fee above the floor; a lower maxFee must revert FeeTooHigh.
        price.set(uint160(1) << 90);
        vm.prank(alice);
        vm.expectRevert(DegenhoodDegens.FeeTooHigh.selector);
        degens.mintPhase2{value: 10 ether}(1, 0.00009 ether);
    }

    function testFuzz_router_split_is_exact_and_complete(uint96 rawFee) public {
        uint256 fee = bound(uint256(rawFee), 1, 100 ether);
        vm.deal(alice, fee);
        uint256 treasuryBefore = treasury.balance;
        uint256 burnBefore = degens.burnAccruedWei();
        uint256 poolBefore = degens.pendingHolderEthWei();
        vm.prank(alice);
        degens.notifyLpFees{value: fee}();
        uint256 h = degens.pendingHolderEthWei() - poolBefore;
        uint256 b = degens.burnAccruedWei() - burnBefore;
        uint256 t = treasury.balance - treasuryBefore;
        assertEq(h + b + t, fee, "every wei of every fee is accounted");
        assertEq(h, fee * 6666 / 10_000);
        assertEq(b, fee * 1667 / 10_000);
    }

    // ---- redeem round-trip -------------------------------------------------

    function test_redeem_returns_full_backing_and_repools_the_pack() public {
        uint256 balBefore = degen.balanceOf(alice);
        uint256 invBefore = degens.inventorySize();
        uint16 outBefore = degens.outstanding();
        // Rip so redeem is single-step, then redeem with a generous maxFee.
        vm.startPrank(alice);
        degens.requestTierRip(1);
        degens.finalizeTierRip(1);
        degens.redeem{value: 10 ether}(1, 10 ether);
        vm.stopPrank();
        assertEq(degen.balanceOf(alice), balBefore + BACKING, "full 66,666,666 backing out");
        assertEq(degens.inventorySize(), invBefore + 1, "pack repooled for the vault");
        assertEq(degens.outstanding(), outBefore - 1);
        assertEq(degens.ownerOf(1), address(degens), "vault holds the returned pack");
        // Solvency identity after the round trip.
        assertGe(degen.balanceOf(address(degens)), uint256(degens.outstanding()) * BACKING);
    }

    // ---- claimMany duplicates ------------------------------------------------

    function test_claimMany_duplicate_ids_cannot_double_credit() public {
        vm.prank(alice);
        degens.activate(1, 0);
        vm.warp(degens.epochDeadline() + 1);
        degens.flushHolderPool();
        vm.prank(alice);
        degens.notifyEth{value: 1 ether}();
        uint256 pending = degens.pendingEth(1);
        uint256[] memory ids = new uint256[](3);
        ids[0] = 1;
        ids[1] = 1;
        ids[2] = 1;
        vm.prank(alice);
        degens.claimMany(ids);
        assertEq(degens.owedEth(alice), pending, "repeats credit zero, never double");
    }

    // ---- epoch conservation under fuzzed weights ----------------------------

    function testFuzz_epoch_flush_conserves_value_within_dust(uint8 tierA, uint8 tierB, uint96 rawAmount) public {
        tierA = uint8(bound(uint256(tierA), 0, 4));
        tierB = uint8(bound(uint256(tierB), 0, 4));
        uint256 amount = bound(uint256(rawAmount), 0.001 ether, 50 ether);
        vm.startPrank(alice);
        degens.activate(1, 0); // activate() requires no prior rip at base tier
        vm.stopPrank();
        // Give bob a pack with an arbitrary tier weight via rip-then-activate.
        vm.prank(alice);
        degens.transferFrom(alice, bob, 2);
        vm.startPrank(bob);
        degens.requestTierRip(2);
        degens.finalizeTierRip(2);
        uint8 tier = degens.TIER_WEIGHT(tierB) > 0 ? tierB : 0;
        degens.activate(2, tier);
        vm.stopPrank();
        vm.prank(alice);
        degens.notifyEth{value: amount}();
        vm.warp(degens.epochDeadline() + 1);
        degens.flushHolderPool();
        uint256 credited = degens.pendingEth(1) + degens.pendingEth(2);
        assertLe(credited, amount, "never credits more than arrived");
        // WAD accumulator dust only: bounded by totalWeight wei.
        assertGe(credited + degens.totalWeight(), amount, "conservation within dust");
    }

    // ---- epoch deadline ------------------------------------------------------

    function test_deadline_opens_the_pool_below_mintout() public {
        vm.prank(alice);
        degens.notifyEth{value: 1 ether}();
        vm.prank(alice);
        degens.activate(1, 0);
        assertFalse(degens.distributionOpened(), "before the deadline: mint-out only");
        vm.warp(degens.epochDeadline() + 1);
        degens.flushHolderPool(); // permissionless poke - no activation needed
        assertTrue(degens.distributionOpened());
        assertEq(degens.pendingHolderEthWei(), 0);
        assertApproxEqAbs(degens.pendingEth(1), 1 ether, 1e6);
    }

    function test_deadline_without_weight_still_waits_for_first_activation() public {
        vm.warp(degens.epochDeadline() + 1);
        degens.flushHolderPool();
        assertFalse(degens.distributionOpened(), "no weight: nothing to flush to");
        vm.prank(alice);
        degens.activate(1, 0);
        assertTrue(degens.distributionOpened(), "first activation after the deadline opens it");
    }

    function test_deadline_is_seven_days_from_launch() public view {
        assertEq(degens.epochDeadline(), degens.phase1OpenedAt() + 7 days);
    }
}
