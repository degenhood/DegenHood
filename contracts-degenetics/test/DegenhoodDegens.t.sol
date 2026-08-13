// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DegenhoodDegens} from "../src/DegenhoodDegens.sol";
import {IEntropySource} from "../src/interfaces/IEntropySource.sol";
import {IPriceSource} from "../src/interfaces/IPriceSource.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ---------------------------------------------------------------------------
// Mocks
// ---------------------------------------------------------------------------
contract MockDegen is ERC20("DegenHood", "DEGEN") {
    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

contract MockSpy is ERC20("SPY", "SPY") {
    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

contract MockEntropy is IEntropySource {
    uint64 public round = 100;
    mapping(uint64 => bytes32) public seeds;

    function tick(bytes32 seed) external {
        seeds[++round] = seed;
    }

    function currentRound() external view returns (uint64) {
        return round;
    }

    function nextRound() external view returns (uint64) {
        return round + 1;
    }

    function entropyOf(uint64 r) external view returns (bytes32) {
        require(r <= round && seeds[r] != 0, "not ready");
        return seeds[r];
    }
}

contract MockPrice is IPriceSource {
    uint160 public sp = 79228162514264337593543950; // ~2^96/1000, arbitrary small price

    function set(uint160 v) external {
        sp = v;
    }

    function sqrtPriceX96() external view returns (uint160) {
        return sp;
    }
}

// ---------------------------------------------------------------------------
// Unit tests — spec v0.2 behaviors. Extend every TODO before audit.
// ---------------------------------------------------------------------------
contract DegensTest is Test {
    DegenhoodDegens degens;
    MockDegen degen;
    MockSpy spy;
    MockEntropy entropy;
    MockPrice price;
    address treasury = makeAddr("treasury");
    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant BACKING = 66_666_666e18;

    function setUp() public {
        degen = new MockDegen();
        spy = new MockSpy();
        entropy = new MockEntropy();
        price = new MockPrice();
        degens = new DegenhoodDegens(address(degen), address(spy), address(price), address(entropy), treasury, admin);
        degen.mint(alice, 100 * BACKING);
        degen.mint(bob, 100 * BACKING);
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
    }

    function _mint1(address who) internal returns (uint256 id) {
        vm.startPrank(who);
        degen.approve(address(degens), type(uint256).max);
        degens.mintPhase1(1);
        vm.stopPrank();
        return degens.minted();
    }

    // ---- mint & escrow -------------------------------------------------
    function test_phase1_mint_escrows_backing() public {
        _mint1(alice);
        assertEq(degen.balanceOf(address(degens)), BACKING);
        assertEq(degens.outstanding(), 1);
    }

    function test_phase1_wallet_cap_first_12h() public {
        vm.startPrank(alice);
        degen.approve(address(degens), type(uint256).max);
        degens.mintPhase1(5);
        vm.expectRevert(DegenhoodDegens.CapExceeded.selector);
        degens.mintPhase1(1);
        vm.stopPrank();
        vm.warp(block.timestamp + 12 hours + 1);
        vm.prank(alice);
        degens.mintPhase1(6); // uncapped after window
    }

    // Distribution epoch: reach mint-out so the continuous distributor is live.
    function _mintOutAll(address who) internal {
        vm.warp(block.timestamp + 12 hours + 1);
        degen.mint(who, 1000 * BACKING);
        vm.startPrank(who);
        degen.approve(address(degens), type(uint256).max);
        if (degens.minted() < 500) degens.mintPhase1(uint16(500 - degens.minted()));
        uint16 remaining = uint16(1000 - degens.minted());
        // maxFee at the contract cap; fund value for the worst case (cap x qty).
        vm.deal(who, uint256(remaining) * 10 ether + 1 ether);
        if (remaining > 0) degens.mintPhase2{value: uint256(remaining) * 10 ether}(remaining, 10 ether);
        vm.stopPrank();
    }

    // ---- activation lifecycle -----------------------------------------
    function test_activation_clears_on_transfer_and_forces_claim() public {
        uint256 id = _mint1(alice);
        vm.prank(alice);
        degens.activate(id, 0);
        assertGt(degens.weightOf(id), 0);
        _mintOutAll(makeAddr("carol")); // opens distribution (weight already exists)

        degens.notifyEth{value: 1 ether}();
        uint256 pending = degens.pendingEth(id);
        assertGt(pending, 0);

        vm.prank(alice);
        degens.transferFrom(alice, bob, id);
        assertEq(degens.weightOf(id), 0); // deactivated
        assertEq(degens.owedEth(alice), pending); // force-claim CREDITS (pull-payment)
        assertEq(degens.pendingEth(id), 0); // bob starts clean

        uint256 before = alice.balance;
        vm.prank(alice);
        degens.withdraw(); // seller pulls
        assertEq(alice.balance, before + pending);
    }

    function test_activation_split_50_burn_50_treasury() public {
        uint256 id = _mint1(alice);
        uint256 cost = degens.TIER_COST(0);
        vm.prank(alice);
        degens.activate(id, 0);
        assertEq(degen.balanceOf(degens.DEAD()), cost / 2);
        assertEq(degen.balanceOf(treasury), cost - cost / 2);
    }

    // ---- distributor math ----------------------------------------------
    function test_no_retroactive_rewards() public {
        uint256 a = _mint1(alice);
        uint256 b = _mint1(bob);
        vm.prank(alice);
        degens.activate(a, 0);
        _mintOutAll(makeAddr("carol")); // opens distribution; pool flushes to a only
        degens.notifyEth{value: 1 ether}();
        uint256 aBefore = degens.pendingEth(a);
        vm.prank(bob);
        degens.activate(b, 0);
        assertGt(aBefore, 0); // a earned the flush + the notify
        assertEq(degens.pendingEth(b), 0); // bob earns nothing from before activation
    }

    // ---- tier rip + FIFO (FWA/TokenWorks defense) -----------------------
    function _mintOutPhase1(address who) internal {
        vm.warp(block.timestamp + 12 hours + 1);
        degen.mint(who, 600 * BACKING);
        vm.startPrank(who);
        degen.approve(address(degens), type(uint256).max);
        degens.mintPhase1(500);
        vm.stopPrank();
    }

    function _ripInOrder(uint256 id) internal {
        degens.requestTierRip(id);
        entropy.tick(keccak256(abi.encode("seed", id)));
        degens.finalizeTierRip(id);
    }

    function test_fifo_order_enforced() public {
        _mintOutPhase1(alice);
        vm.startPrank(alice);
        degens.requestTierRip(1);
        degens.requestTierRip(2);
        vm.stopPrank();
        entropy.tick(keccak256("s1"));
        entropy.tick(keccak256("s2"));
        vm.expectRevert(bytes("out of order"));
        degens.finalizeTierRip(2);
        degens.finalizeTierRip(1);
        degens.finalizeTierRip(2);
        assertEq(degens.processedSeq(), 2);
    }

    function test_art_reveal_request_is_owner_gated() public {
        _mintOutPhase1(alice);
        vm.prank(alice);
        degens.requestTierRip(1);
        entropy.tick(keccak256("s1"));
        degens.finalizeTierRip(1);
        vm.prank(admin);
        degens.commitProvenance(keccak256("art"), "ar://base/");
        vm.prank(bob); // not the owner: cannot force someone else's reveal or spam the FIFO
        vm.expectRevert(DegenhoodDegens.NotOwner.selector);
        degens.requestArtReveal(1);
    }

    function test_fifo_covers_art_reveals_too() public {
        _mintOutPhase1(alice);
        vm.prank(alice);
        degens.requestTierRip(1);
        entropy.tick(keccak256("s1"));
        degens.finalizeTierRip(1);
        vm.prank(admin);
        degens.commitProvenance(keccak256("art"), "ar://base/");
        vm.startPrank(alice);
        degens.requestArtReveal(1);
        degens.requestTierRip(2);
        vm.stopPrank();
        entropy.tick(keccak256("s2"));
        entropy.tick(keccak256("s3"));
        vm.expectRevert(bytes("out of order"));
        degens.finalizeTierRip(2);
        degens.finalizeArtReveal(1);
        degens.finalizeTierRip(2);
        assertEq(degens.processedSeq(), 3);
    }

    function test_tier_census_depletes() public {
        _mintOutPhase1(alice);
        uint256 startTotal;
        for (uint8 i; i < 5; ++i) {
            startTotal += degens.tierRemaining(i);
        }
        assertEq(startTotal, 1000);
        vm.startPrank(alice);
        for (uint256 id = 1; id <= 20; ++id) {
            _ripInOrder(id);
        }
        vm.stopPrank();
        uint256 endTotal;
        for (uint8 i; i < 5; ++i) {
            endTotal += degens.tierRemaining(i);
        }
        assertEq(endTotal, 980);
        assertEq(degens.processedSeq(), 20);
    }

    // ---- solvency invariant (fuzz + invariant harness) ------------------
    function invariant_solvency() public view {
        assertGe(degen.balanceOf(address(degens)), uint256(degens.outstanding()) * BACKING);
    }

    // TODO before audit (spec §12 checklist):
    // - reroll: excludes own deposit; entropy-not-ready reverts; finalize by third party
    // - redeem: auto-rip path; ETH fee; inventory entry; full backing returned
    // - swapRandom: backing pulled, outstanding incremented on finalize
    // - fee router split 6666/1667/1667 exact
    // - maxFeeWei slippage revert
    // - fee floor/cap clamps under price.set() extremes
    // - booster ladder costs/weights; boost clears on transfer
    // - royalty routing via receive()
    // - lore append split
    // - fork tests (Robinhood RPC): real pool tick read; DERP adapter; tax-free escrow transfer

    function test_modelB_reroll_draws_fresh_pack() public {
        _mintOutPhase1(alice);
        vm.prank(alice);
        _ripInOrder(1);
        uint256 mintedBefore = degens.minted();
        uint256 outBefore = degens.outstanding();
        vm.prank(alice);
        uint256 drawId = degens.reroll{value: 11 ether}(1, 100 ether);
        entropy.tick(keccak256("reroll-fresh"));
        degens.finalizeDraw(drawId);
        assertEq(degens.minted(), mintedBefore + 1, "fresh pack minted");
        assertEq(degens.outstanding(), outBefore, "reroll net-zero");
        assertEq(degens.ownerOf(mintedBefore + 1), alice, "alice got fresh");
        assertGe(degen.balanceOf(address(degens)), uint256(degens.outstanding()) * BACKING, "solvent");
    }

    function test_modelB_swapRandom_entry_pulls_fresh() public {
        _mintOutPhase1(alice);
        uint256 mintedBefore = degens.minted();
        uint256 outBefore = degens.outstanding();
        vm.startPrank(bob);
        degen.approve(address(degens), type(uint256).max);
        uint256 drawId = degens.swapRandom{value: 11 ether}(100 ether);
        vm.stopPrank();
        entropy.tick(keccak256("swap-fresh"));
        degens.finalizeDraw(drawId);
        assertEq(degens.minted(), mintedBefore + 1, "fresh minted");
        assertEq(degens.outstanding(), outBefore + 1, "swap adds one");
        assertEq(degens.ownerOf(mintedBefore + 1), bob, "bob got pack");
        assertGe(degen.balanceOf(address(degens)), uint256(degens.outstanding()) * BACKING, "solvent");
    }

    function test_modelB_reroll_gated_to_phase2() public {
        uint256 id = _mint1(alice);
        vm.prank(alice);
        vm.expectRevert(bytes("phase 2 only"));
        degens.reroll{value: 11 ether}(id, 100 ether);
    }

    function test_voucher_covers_premium_once() public {
        _mintOutPhase1(alice);
        uint256 target;
        uint8 vtier;
        for (uint256 id = 1; id <= 30; ++id) {
            vm.prank(alice);
            _ripInOrder(id);
            (,,,,, uint8 vt,) = degens.reveals(id);
            if (vt > 0) {
                target = id;
                vtier = vt;
                break;
            }
        }
        require(target != 0, "no voucher pack in 30 rips");
        uint256 deadBefore = degen.balanceOf(degens.DEAD());
        vm.expectEmit(true, false, false, true);
        emit VoucherRedeemed(target, vtier);
        vm.prank(alice);
        degens.activate(target, vtier);
        assertEq(degen.balanceOf(degens.DEAD()) - deadBefore, degens.TIER_COST(0) / 2, "base burned, premium waived");
        assertEq(degens.weightOf(target), degens.TIER_WEIGHT(vtier), "full tier weight");
        (,,,,,, bool spent) = degens.reveals(target);
        assertTrue(spent, "voucher spent");
    }
    event VoucherRedeemed(uint256 indexed tokenId, uint8 tierIdx);
}
