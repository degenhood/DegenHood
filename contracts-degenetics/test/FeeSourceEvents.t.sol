// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DegenhoodDegens} from "../src/DegenhoodDegens.sol";
import {IEntropySource} from "../src/interfaces/IEntropySource.sol";
import {IPriceSource} from "../src/interfaces/IPriceSource.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract FSMockDegen is ERC20("DegenHood", "DEGEN") {
    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

contract FSMockSpy is ERC20("SPY", "SPY") {
    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

contract FSMockEntropy is IEntropySource {
    uint64 public round = 100;

    function currentRound() external view returns (uint64) {
        return round;
    }

    function nextRound() external view returns (uint64) {
        return round + 1;
    }

    function entropyOf(uint64) external pure returns (bytes32) {
        return bytes32(uint256(1));
    }
}

contract FSMockPrice is IPriceSource {
    function sqrtPriceX96() external pure returns (uint160) {
        return uint160(1) << 48; // microscopic price -> fees clamp to the 0.0001 ether floor
    }
}

/// Source-tagged earning events (pre-audit item): each inflow path emits FeesRouted with
/// its FeeSource tag, notifySpy emits SpyNotified, and the routing MATH is untouched -
/// the split amounts asserted here are identical to the untagged implementation's.
contract FeeSourceEventsTest is Test {
    uint256 constant BACKING = 66_666_666e18;
    FSMockDegen degen;
    FSMockSpy spy;
    FSMockEntropy entropy;
    FSMockPrice price;
    DegenhoodDegens degens;
    address treasury = makeAddr("treasury");
    address admin = makeAddr("admin");
    address alice = makeAddr("alice");

    event FeesRouted(uint8 indexed source, uint256 toHolders, uint256 toBurn, uint256 toTreasury);
    event SpyNotified(address indexed from, uint256 amount);

    function setUp() public {
        degen = new FSMockDegen();
        spy = new FSMockSpy();
        entropy = new FSMockEntropy();
        price = new FSMockPrice();
        degens = new DegenhoodDegens(address(degen), address(spy), address(price), address(entropy), treasury, admin);
        degen.mint(alice, 1100 * BACKING);
        vm.deal(alice, 1000 ether);
        // Fill phase 1 past the cap window so phase-2 (fee-bearing) paths open.
        vm.warp(block.timestamp + 12 hours + 1);
        vm.startPrank(alice);
        degen.approve(address(degens), type(uint256).max);
        for (uint256 i = 0; i < 10; i++) {
            degens.mintPhase1(50);
        }
        vm.stopPrank();
    }

    function _split(uint256 fee) internal pure returns (uint256 h, uint256 b, uint256 t) {
        h = fee * 6666 / 10_000;
        b = fee * 1667 / 10_000;
        t = fee - h - b;
    }

    function test_action_fee_tagged() public {
        uint256 fee = 0.0001 ether; // floor (price is tiny)
        (uint256 h, uint256 b, uint256 t) = _split(fee);
        vm.expectEmit(true, false, false, true);
        emit FeesRouted(uint8(DegenhoodDegens.FeeSource.Action), h, b, t);
        vm.prank(alice);
        degens.mintPhase2{value: fee}(1, fee);
    }

    function test_lp_fee_entrypoint_tagged() public {
        (uint256 h, uint256 b, uint256 t) = _split(1 ether);
        vm.expectEmit(true, false, false, true);
        emit FeesRouted(uint8(DegenhoodDegens.FeeSource.LpFee), h, b, t);
        vm.prank(alice);
        degens.notifyLpFees{value: 1 ether}();
    }

    function test_royalty_entrypoint_tagged() public {
        (uint256 h, uint256 b, uint256 t) = _split(2 ether);
        vm.expectEmit(true, false, false, true);
        emit FeesRouted(uint8(DegenhoodDegens.FeeSource.Royalty), h, b, t);
        vm.prank(alice);
        degens.notifyRoyalty{value: 2 ether}();
    }

    function test_receive_tagged_external() public {
        (uint256 h, uint256 b, uint256 t) = _split(0.5 ether);
        vm.expectEmit(true, false, false, true);
        emit FeesRouted(uint8(DegenhoodDegens.FeeSource.External), h, b, t);
        vm.prank(alice);
        (bool ok,) = address(degens).call{value: 0.5 ether}("");
        assertTrue(ok);
    }

    function test_notifySpy_emits_amount() public {
        // Activate one token so totalWeight > 0 (notifySpy requires it).
        vm.startPrank(alice);
        degens.requestTierRip(1);
        degens.finalizeTierRip(1);
        degens.activate(1, 0);
        spy.mint(alice, 10e18);
        spy.approve(address(degens), 10e18);
        vm.expectEmit(true, false, false, true);
        emit SpyNotified(alice, 10e18);
        degens.notifySpy(10e18);
        vm.stopPrank();
    }

    function test_tagging_does_not_touch_escrow_or_fifo() public {
        // Escrow and FIFO counters behave exactly as before through a tagged action path.
        uint256 escrowBefore = degens.escrowBalance();
        uint64 processedBefore = degens.processedSeq();
        vm.prank(alice);
        degens.mintPhase2{value: 0.0001 ether}(1, 0.0001 ether);
        assertEq(degens.escrowBalance(), escrowBefore + BACKING);
        assertEq(degens.processedSeq(), processedBefore);
        vm.prank(alice);
        degens.notifyLpFees{value: 1 ether}();
        assertEq(degens.escrowBalance(), escrowBefore + BACKING); // inflows never touch escrow
    }
}
