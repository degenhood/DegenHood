// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {DegenHoodTokenV4} from "../src/DegenHoodTokenV4.sol";

contract DegenHoodTokenV4Test is Test {
    event MetadataUpdated(string contractURI, string imageURI);
    event TokenAdminUpdated(address indexed previousAdmin, address indexed newAdmin);

    address private launchReceiver = makeAddr("launchReceiver");
    address private tokenAdmin = makeAddr("tokenAdmin");
    address private nextAdmin = makeAddr("nextAdmin");
    address private holder = makeAddr("holder");
    address private spender = makeAddr("spender");

    DegenHoodTokenV4 private token;

    function setUp() public {
        token = new DegenHoodTokenV4(
            "DegenHood", "DEGEN", launchReceiver, tokenAdmin, "ipfs://contract", "ipfs://image"
        );
    }

    function testMintsFixedSupplyOnceToLaunchReceiver() public view {
        assertEq(token.STANDARD_SUPPLY(), 100_000_000_000 ether);
        assertEq(token.totalSupply(), 100_000_000_000 ether);
        assertEq(token.balanceOf(launchReceiver), 100_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function testConstructorRejectsZeroLaunchReceiverAndTokenAdmin() public {
        vm.expectRevert(DegenHoodTokenV4.InvalidRecipient.selector);
        new DegenHoodTokenV4("Token", "TOK", address(0), tokenAdmin, "", "");

        vm.expectRevert(DegenHoodTokenV4.InvalidTokenAdmin.selector);
        new DegenHoodTokenV4("Token", "TOK", launchReceiver, address(0), "", "");
    }

    function testOrdinaryTransfersAndApprovalsHaveNoTaxOrWalletLimit() public {
        uint256 transferAmount = 99_000_000_000 ether;
        vm.prank(launchReceiver);
        token.transfer(holder, transferAmount);

        assertEq(token.balanceOf(holder), transferAmount);
        assertEq(token.balanceOf(launchReceiver), token.STANDARD_SUPPLY() - transferAmount);

        vm.prank(holder);
        token.approve(spender, 1000 ether);
        vm.prank(spender);
        token.transferFrom(holder, launchReceiver, 1000 ether);

        assertEq(token.balanceOf(holder), transferAmount - 1000 ether);
        assertEq(token.allowance(holder, spender), 0);
        assertEq(token.totalSupply(), token.STANDARD_SUPPLY());
    }

    function testNoMintFunctionExistsAfterConstruction() public {
        (bool success,) =
            address(token).call(abi.encodeWithSignature("mint(address,uint256)", holder, 1 ether));

        assertFalse(success);
        assertEq(token.totalSupply(), token.STANDARD_SUPPLY());
        assertEq(token.balanceOf(holder), 0);
    }

    function testOnlyTokenAdminMayUpdateMetadata() public {
        vm.prank(holder);
        vm.expectRevert(
            abi.encodeWithSelector(DegenHoodTokenV4.UnauthorizedTokenAdmin.selector, holder)
        );
        token.updateMetadata("ipfs://bad", "ipfs://bad-image");

        vm.expectEmit(false, false, false, true, address(token));
        emit MetadataUpdated("ipfs://new-contract", "ipfs://new-image");
        vm.prank(tokenAdmin);
        token.updateMetadata("ipfs://new-contract", "ipfs://new-image");

        assertEq(token.contractURI(), "ipfs://new-contract");
        assertEq(token.extraMetadata("image"), "ipfs://new-image");
        assertEq(token.extraMetadata("unknown"), "");
    }

    function testTokenAdminTransferIsOneStepAndImmediatelyRevokesOldAdmin() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit TokenAdminUpdated(tokenAdmin, nextAdmin);
        vm.prank(tokenAdmin);
        token.transferTokenAdmin(nextAdmin);

        assertEq(token.tokenAdmin(), nextAdmin);

        vm.prank(tokenAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(DegenHoodTokenV4.UnauthorizedTokenAdmin.selector, tokenAdmin)
        );
        token.updateMetadata("ipfs://old", "ipfs://old");

        vm.prank(nextAdmin);
        token.updateMetadata("ipfs://next", "ipfs://next-image");
        assertEq(token.contractURI(), "ipfs://next");
    }

    function testTokenAdminTransferRejectsZeroAndUnauthorizedCaller() public {
        vm.prank(tokenAdmin);
        vm.expectRevert(DegenHoodTokenV4.InvalidTokenAdmin.selector);
        token.transferTokenAdmin(address(0));

        vm.prank(holder);
        vm.expectRevert(
            abi.encodeWithSelector(DegenHoodTokenV4.UnauthorizedTokenAdmin.selector, holder)
        );
        token.transferTokenAdmin(nextAdmin);
    }

    function testTokenAdminHasNoFeeLpTreasuryOrTransferControlMethods() public {
        bytes[5] memory calls = [
            abi.encodeWithSignature("setTransferFee(uint256)", 1),
            abi.encodeWithSignature("setMaxWallet(uint256)", 1),
            abi.encodeWithSignature("setAllowlisted(address,bool)", holder, true),
            abi.encodeWithSignature("claimFees()"),
            abi.encodeWithSignature("setTreasury(address)", holder)
        ];

        for (uint256 i; i < calls.length; ++i) {
            vm.prank(tokenAdmin);
            (bool success,) = address(token).call(calls[i]);
            assertFalse(success);
        }
        assertEq(token.totalSupply(), token.STANDARD_SUPPLY());
    }
}
