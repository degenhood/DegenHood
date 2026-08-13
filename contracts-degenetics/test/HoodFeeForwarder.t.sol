// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DegenhoodDegens} from "../src/DegenhoodDegens.sol";
import {HoodFeeForwarder} from "../src/HoodFeeForwarder.sol";
import {FSMockDegen, FSMockSpy, FSMockEntropy, FSMockPrice} from "./FeeSourceEvents.t.sol";

/// Minimal WETH9: deposit/withdraw/transfer, enough for delivery + unwrap flows.
contract MockWETH9 {
    mapping(address => uint256) public balanceOf;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "weth send");
    }
}

contract HoodFeeForwarderTest is Test {
    uint256 constant BACKING = 66_666_666e18;
    FSMockDegen degen;
    FSMockSpy spy;
    FSMockEntropy entropy;
    FSMockPrice price;
    DegenhoodDegens degens;
    MockWETH9 weth;
    HoodFeeForwarder lpForwarder;
    HoodFeeForwarder royaltyForwarder;
    address treasury = makeAddr("treasury");
    address admin = makeAddr("admin");
    address alice = makeAddr("alice");

    event FeesRouted(uint8 indexed source, uint256 toHolders, uint256 toBurn, uint256 toTreasury);

    function setUp() public {
        degen = new FSMockDegen();
        spy = new FSMockSpy();
        entropy = new FSMockEntropy();
        price = new FSMockPrice();
        degens = new DegenhoodDegens(address(degen), address(spy), address(price), address(entropy), treasury, admin);
        weth = new MockWETH9();
        lpForwarder = new HoodFeeForwarder(address(weth), address(degen), payable(address(degens)), false);
        royaltyForwarder = new HoodFeeForwarder(address(weth), address(degen), payable(address(degens)), true);
        vm.deal(alice, 100 ether);
    }

    function _deliverWeth(address to, uint256 amount) internal {
        vm.startPrank(alice);
        weth.deposit{value: amount}();
        weth.transfer(to, amount);
        vm.stopPrank();
    }

    function test_forwards_weth_lp_fees_through_the_tagged_entrypoint() public {
        _deliverWeth(address(lpForwarder), 2 ether);
        uint256 h = 2 ether * 6666 / 10_000;
        uint256 b = 2 ether * 1667 / 10_000;
        vm.expectEmit(true, false, false, true, address(degens));
        emit FeesRouted(uint8(DegenhoodDegens.FeeSource.LpFee), h, b, 2 ether - h - b);
        lpForwarder.forward(); // permissionless - any caller
        assertEq(weth.balanceOf(address(lpForwarder)), 0);
        assertEq(address(lpForwarder).balance, 0);
        assertEq(degens.pendingHolderEthWei(), h, "holder cut stacked in the epoch pool");
    }

    function test_royalty_mode_routes_via_notifyRoyalty() public {
        _deliverWeth(address(royaltyForwarder), 1 ether);
        uint256 h = 1 ether * 6666 / 10_000;
        uint256 b = 1 ether * 1667 / 10_000;
        vm.expectEmit(true, false, false, true, address(degens));
        emit FeesRouted(uint8(DegenhoodDegens.FeeSource.Royalty), h, b, 1 ether - h - b);
        royaltyForwarder.forward();
    }

    function test_stray_eth_is_swept_and_degen_burns() public {
        vm.prank(alice);
        (bool ok,) = address(lpForwarder).call{value: 0.5 ether}("");
        assertTrue(ok);
        degen.mint(address(lpForwarder), 123e18);
        lpForwarder.forward();
        assertEq(address(lpForwarder).balance, 0);
        assertEq(degen.balanceOf(lpForwarder.DEAD()), 123e18, "all DEGEN through the machine burns");
    }

    function test_forward_with_nothing_held_is_a_noop() public {
        lpForwarder.forward();
        assertEq(degens.pendingHolderEthWei(), 0);
    }

    function test_royalty_receiver_set_once_and_defaults_to_the_vault() public {
        (address receiver,) = degens.royaltyInfo(1, 1 ether);
        assertEq(receiver, address(degens), "default: raw-ETH royalties auto-route");
        vm.prank(alice);
        vm.expectRevert(bytes("once"));
        degens.setRoyaltyReceiverOnce(address(royaltyForwarder));
        vm.prank(admin);
        degens.setRoyaltyReceiverOnce(address(royaltyForwarder));
        (receiver,) = degens.royaltyInfo(1, 1 ether);
        assertEq(receiver, address(royaltyForwarder));
        vm.prank(admin);
        vm.expectRevert(bytes("once"));
        degens.setRoyaltyReceiverOnce(treasury); // once means once
    }

    function test_buyburner_wiring_is_admin_gated_and_zero_admin_reverts() public {
        vm.prank(treasury); // the fee sink can NOT wire the burner
        vm.expectRevert(bytes("once"));
        degens.setBuyBurnerOnce(alice);
        vm.prank(admin);
        degens.setBuyBurnerOnce(alice);
        assertEq(degens.buyBurner(), alice);
        vm.expectRevert(bytes("zero")); // constructor refuses an unset admin
        new DegenhoodDegens(address(degen), address(spy), address(price), address(entropy), treasury, address(0));
    }

    function test_marketplace_conventions_carry_no_authority() public {
        assertEq(degens.owner(), admin); // collection claiming only
        vm.prank(alice);
        vm.expectRevert(bytes("admin"));
        degens.setContractURI("ipfs://x");
        vm.prank(admin);
        degens.setContractURI("ipfs://collection.json");
        assertEq(degens.contractURI(), "ipfs://collection.json");
    }
}
