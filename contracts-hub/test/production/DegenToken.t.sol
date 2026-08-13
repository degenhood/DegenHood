// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

import {DegenToken} from "../../src/production/ProductionDegenToken.sol";
import {IDegenToken} from "../../src/production/ProductionDegenTokenInterface.sol";

contract DegenTokenTest is Test {
    uint256 private constant STANDARD_SUPPLY = 100_000_000_000 ether;
    bytes32 private constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant PERMIT_TYPEHASH = keccak256(
        "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
    );
    bytes32 private constant METADATA_DIGEST =
        0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;
    bytes32 private constant IMAGE_DIGEST =
        0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb;

    DegenToken private implementation;
    DegenToken private token;
    IERC20 private v4Token;
    address private supplyRecipient;
    address private tokenAdmin;
    address private poolManager;
    address private positionManager;
    address private lpLocker;
    uint40 private restrictionRampEndTime;

    function setUp() public {
        implementation = new DegenToken();
        supplyRecipient = makeAddr("supplyRecipient");
        tokenAdmin = makeAddr("tokenAdmin");
        poolManager = makeAddr("poolManager");
        positionManager = makeAddr("positionManager");
        lpLocker = makeAddr("lpLocker");
        restrictionRampEndTime = uint40(block.timestamp + 120 seconds);
        token = _newClone();
        v4Token = IERC20(
            deployCode(
                "../contracts-v4/out/DegenHoodTokenV4.sol/DegenHoodTokenV4.json",
                abi.encode(
                    "Degen Test",
                    "DTEST",
                    supplyRecipient,
                    tokenAdmin,
                    "ipfs://metadata",
                    "ipfs://image"
                )
            )
        );
    }

    function testInitializeMintsFixedSupplyAndSetsCloneState() public view {
        assertEq(token.name(), "Degen Test");
        assertEq(token.symbol(), "DTEST");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), STANDARD_SUPPLY);
        assertEq(token.balanceOf(supplyRecipient), STANDARD_SUPPLY);
        assertEq(token.tokenAdmin(), tokenAdmin);
        assertTrue(token.initialised());
        assertFalse(token.metadataFrozen());
        assertEq(token.metadataDigest(), METADATA_DIGEST);
        assertEq(token.imageDigest(), IMAGE_DIGEST);
    }

    function testThirtyTwoByteNameAndSymbolRoundTripFromDynamicStorage() public {
        DegenToken longStringToken = DegenToken(Clones.clone(address(implementation)));
        string memory longName = "12345678901234567890123456789012";
        string memory longSymbol = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef";

        longStringToken.initialize(
            longName,
            longSymbol,
            supplyRecipient,
            tokenAdmin,
            METADATA_DIGEST,
            IMAGE_DIGEST,
            poolManager,
            positionManager,
            lpLocker
        );

        assertEq(longStringToken.name(), longName);
        assertEq(longStringToken.symbol(), longSymbol);
        assertEq(uint256(vm.load(address(longStringToken), bytes32(uint256(1)))), 65);
        assertEq(uint256(vm.load(address(longStringToken), bytes32(uint256(2)))), 65);
    }

    function testInitializeRevertsOnSecondCallAgainstClone() public {
        vm.expectRevert(IDegenToken.AlreadyInitialised.selector);
        token.initialize(
            "Hostile",
            "BAD",
            address(this),
            address(this),
            bytes32(0),
            bytes32(0),
            poolManager,
            positionManager,
            lpLocker
        );
    }

    function testImplementationCannotBeInitialised() public {
        assertTrue(implementation.initialised());
        assertTrue(implementation.metadataFrozen());
        vm.expectRevert(IDegenToken.AlreadyInitialised.selector);
        implementation.initialize(
            "Hostile",
            "BAD",
            address(this),
            address(this),
            bytes32(0),
            bytes32(0),
            poolManager,
            positionManager,
            lpLocker
        );
    }

    function testInitializeRejectsZeroRecipientAndAdmin() public {
        DegenToken recipientClone = DegenToken(Clones.clone(address(implementation)));
        vm.expectRevert(IDegenToken.InvalidRecipient.selector);
        recipientClone.initialize(
            "Degen Test",
            "DTEST",
            address(0),
            tokenAdmin,
            METADATA_DIGEST,
            IMAGE_DIGEST,
            poolManager,
            positionManager,
            lpLocker
        );

        DegenToken adminClone = DegenToken(Clones.clone(address(implementation)));
        vm.expectRevert(IDegenToken.InvalidTokenAdmin.selector);
        adminClone.initialize(
            "Degen Test",
            "DTEST",
            supplyRecipient,
            address(0),
            METADATA_DIGEST,
            IMAGE_DIGEST,
            poolManager,
            positionManager,
            lpLocker
        );
    }

    function testStorageLayoutSlotZeroIsPacked() public view {
        uint256 packed = uint256(vm.load(address(token), bytes32(0)));
        assertEq(address(uint160(packed)), tokenAdmin);
        assertEq(uint8(packed >> 160), 1, "initialised offset");
        assertEq(uint8(packed >> 168), 0, "metadataFrozen offset");
        assertEq(uint40(packed >> 176), token.flatEndTime(), "flatEndTime offset");
        assertEq(uint40(packed >> 216), token.rampEndTime(), "rampEndTime offset");
    }

    function testTransferAndTransferFromUseStandardAllowanceSemantics() public {
        address recipient = makeAddr("recipient");
        address spender = makeAddr("spender");
        vm.prank(supplyRecipient);
        token.transfer(recipient, 7 ether);
        assertEq(token.balanceOf(recipient), 7 ether);

        vm.prank(supplyRecipient);
        token.approve(spender, 5 ether);
        vm.prank(spender);
        token.transferFrom(supplyRecipient, recipient, 3 ether);
        assertEq(token.allowance(supplyRecipient, spender), 2 ether);
        assertEq(token.balanceOf(recipient), 10 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, spender, 2 ether, 3 ether
            )
        );
        vm.prank(spender);
        token.transferFrom(supplyRecipient, recipient, 3 ether);
    }

    function test_maxWallet_enforcedDuringFlatWindow() public {
        address holder = makeAddr("capHolder");
        address recipient = makeAddr("capRecipient");
        vm.prank(supplyRecipient);
        token.transfer(holder, 4_000_000_000 ether);

        vm.prank(holder);
        token.transfer(recipient, 2_000_000_000 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDegenToken.MaxWalletExceeded.selector,
                recipient,
                2_000_000_000 ether + 1,
                2_000_000_000 ether
            )
        );
        vm.prank(holder);
        token.transfer(recipient, 1);
    }

    function test_maxTx_enforcedDuringFlatWindow() public {
        address holder = makeAddr("txHolder");
        vm.prank(supplyRecipient);
        token.transfer(holder, 4_000_000_000 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDegenToken.MaxTransactionExceeded.selector,
                2_200_000_000 ether + 1,
                2_200_000_000 ether
            )
        );
        vm.prank(holder);
        token.transfer(makeAddr("txRecipient"), 2_200_000_000 ether + 1);
    }

    function test_restrictionSchedule_usesTimestampNotBlockHeight() public {
        uint256 initializedAt = block.timestamp;

        vm.roll(block.number + 1200);
        assertEq(token.currentWalletCapBps(), 200);
        assertEq(token.currentTxCapBps(), 220);

        vm.warp(initializedAt + 120 seconds);
        assertEq(token.currentWalletCapBps(), 10_000);
        assertEq(token.currentTxCapBps(), 10_000);
    }

    function test_restrictionSchedule_exposesTimestampGetters() public view {
        (bool startOk, bytes memory startData) =
            address(token).staticcall(abi.encodeWithSignature("restrictionStartTime()"));
        (bool flatOk, bytes memory flatData) =
            address(token).staticcall(abi.encodeWithSignature("flatEndTime()"));
        (bool rampOk, bytes memory rampData) =
            address(token).staticcall(abi.encodeWithSignature("rampEndTime()"));

        assertTrue(startOk && flatOk && rampOk);
        assertEq(abi.decode(startData, (uint40)), uint40(block.timestamp));
        assertEq(abi.decode(flatData, (uint40)), uint40(block.timestamp + 60 seconds));
        assertEq(abi.decode(rampData, (uint40)), uint40(block.timestamp + 120 seconds));
    }

    function test_walletCap_rampsLinearlyBetweenFlatEndAndRampEnd() public {
        vm.warp(token.flatEndTime() + 30 seconds);
        assertEq(token.currentWalletCapBps(), 5100);
        assertEq(token.currentTxCapBps(), 5110);
    }

    function test_walletCap_exactlyUnrestrictedAtRampEndTime() public {
        vm.warp(token.rampEndTime());
        assertEq(token.currentWalletCapBps(), 10_000);
        assertEq(token.currentTxCapBps(), 10_000);

        address holder = makeAddr("unrestrictedHolder");
        vm.prank(supplyRecipient);
        token.transfer(holder, 60_000_000_000 ether);
        vm.prank(holder);
        token.transfer(makeAddr("unrestrictedRecipient"), 60_000_000_000 ether);
    }

    function test_noCliff_capIncreasesMonotonicallyAcrossRamp() public {
        uint256 previous = token.currentWalletCapBps();
        for (uint256 offset = 1; offset <= 60; ++offset) {
            vm.warp(token.flatEndTime() + offset);
            uint256 current = token.currentWalletCapBps();
            assertGe(current, previous);
            assertLe(current - previous, 164);
            previous = current;
        }
        assertEq(previous, 10_000);
    }

    function test_noOwnerCanExtendLiftOrPauseRestrictions() public {
        (bool ownerOk,) = address(token).call(abi.encodeWithSignature("owner()"));
        (bool pauseOk,) = address(token).call(abi.encodeWithSignature("pause()"));
        (bool extendOk,) =
            address(token).call(abi.encodeWithSignature("extendRestrictions(uint40)", uint40(1)));
        (bool exemptOk,) = address(token)
            .call(
                abi.encodeWithSignature(
                    "setRestrictionExemption(address,bool)", address(this), true
                )
            );
        assertFalse(ownerOk || pauseOk || extendOk || exemptOk);
    }

    function test_structuralExemptionsOnly_setAtConstruction() public {
        assertEq(token.poolManager(), poolManager);
        assertEq(token.positionManager(), positionManager);
        assertEq(token.launchModule(), supplyRecipient);
        assertEq(token.lpLocker(), lpLocker);

        address holder = makeAddr("structuralHolder");
        vm.prank(supplyRecipient);
        token.transfer(holder, 5_000_000_000 ether);
        vm.prank(holder);
        token.transfer(poolManager, 5_000_000_000 ether);

        vm.prank(supplyRecipient);
        token.transfer(poolManager, 5_000_000_000 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDegenToken.MaxTransactionExceeded.selector,
                2_200_000_000 ether + 1,
                2_200_000_000 ether
            )
        );
        vm.prank(poolManager);
        token.transfer(makeAddr("ordinaryBuyer"), 2_200_000_000 ether + 1);

        vm.expectRevert(IDegenToken.AlreadyInitialised.selector);
        token.initialize(
            "Hostile",
            "BAD",
            supplyRecipient,
            tokenAdmin,
            bytes32(0),
            bytes32(0),
            makeAddr("replacementPoolManager"),
            positionManager,
            lpLocker
        );
    }

    function test_postWindowTransferOverhead_measured() public {
        vm.warp(restrictionRampEndTime);
        (uint256 v4Gas, uint256 v5Gas) = _measureTransfers(false);
        emit log_named_uint("V4 post-window transfer gas", v4Gas);
        emit log_named_uint("V5 clone post-window transfer gas", v5Gas);
        emit log_named_int("V5 minus V4 post-window gas", int256(v5Gas) - int256(v4Gas));
    }

    function test_feeWindowAndCapWindow_areIndependent() public {
        uint256 initializedAt = block.timestamp;
        vm.warp(initializedAt + 30 seconds);
        assertLt(block.timestamp, token.flatEndTime());
        assertEq(token.currentWalletCapBps(), 200);
        assertEq(token.currentTxCapBps(), 220);
    }

    function testTransferGasDifferentialWithColdStorage() public {
        vm.warp(restrictionRampEndTime);
        (uint256 v4Gas, uint256 v5Gas) = _measureTransfers(false);

        emit log_named_uint("V4 transfer cold gas", v4Gas);
        emit log_named_uint("V5 transfer cold gas", v5Gas);
        emit log_named_int("V5 minus V4 cold gas", int256(v5Gas) - int256(v4Gas));
    }

    function testTransferGasDifferentialWithReadWarmedCleanStorage() public {
        vm.warp(restrictionRampEndTime);
        (uint256 v4Gas, uint256 v5Gas) = _measureTransfers(true);

        emit log_named_uint("V4 transfer read-warm gas", v4Gas);
        emit log_named_uint("V5 transfer read-warm gas", v5Gas);
        emit log_named_int("V5 minus V4 read-warm gas", int256(v5Gas) - int256(v4Gas));
    }

    function testBurnReducesBalanceAndTotalSupply() public {
        vm.prank(supplyRecipient);
        token.burn(12 ether);
        assertEq(token.balanceOf(supplyRecipient), STANDARD_SUPPLY - 12 ether);
        assertEq(token.totalSupply(), STANDARD_SUPPLY - 12 ether);
    }

    function testBurnFromDecrementsAllowance() public {
        address spender = makeAddr("spender");
        vm.prank(supplyRecipient);
        token.approve(spender, 20 ether);
        vm.prank(spender);
        token.burnFrom(supplyRecipient, 7 ether);
        assertEq(token.allowance(supplyRecipient, spender), 13 ether);
        assertEq(token.totalSupply(), STANDARD_SUPPLY - 7 ether);
    }

    function testBurnFromInfiniteAllowanceIsNotDecremented() public {
        address spender = makeAddr("spender");
        vm.prank(supplyRecipient);
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        token.burnFrom(supplyRecipient, 7 ether);
        assertEq(token.allowance(supplyRecipient, spender), type(uint256).max);
        assertEq(token.totalSupply(), STANDARD_SUPPLY - 7 ether);
    }

    function testTokenAdminCanTransferAdministration() public {
        address nextAdmin = makeAddr("nextAdmin");
        vm.prank(tokenAdmin);
        token.transferTokenAdmin(nextAdmin);
        assertEq(token.tokenAdmin(), nextAdmin);

        vm.expectRevert(IDegenToken.InvalidTokenAdmin.selector);
        vm.prank(nextAdmin);
        token.transferTokenAdmin(address(0));
    }

    function testRenounceTokenAdminRequiresFrozenMetadata() public {
        vm.expectRevert(IDegenToken.MetadataNotFrozen.selector);
        vm.prank(tokenAdmin);
        token.renounceTokenAdmin();
    }

    function testOnlyTokenAdminCanRenounceTokenAdmin() public {
        address stranger = makeAddr("stranger");
        vm.prank(tokenAdmin);
        token.freezeMetadata();

        vm.expectRevert(
            abi.encodeWithSelector(IDegenToken.UnauthorizedTokenAdmin.selector, stranger)
        );
        vm.prank(stranger);
        token.renounceTokenAdmin();
    }

    function testRenounceTokenAdminAfterFreezeIsPermanent() public {
        vm.prank(tokenAdmin);
        token.freezeMetadata();

        vm.expectEmit(true, true, false, false, address(token));
        emit IDegenToken.TokenAdminUpdated(tokenAdmin, address(0));
        vm.prank(tokenAdmin);
        token.renounceTokenAdmin();

        assertEq(token.tokenAdmin(), address(0));
        vm.expectRevert(
            abi.encodeWithSelector(IDegenToken.UnauthorizedTokenAdmin.selector, tokenAdmin)
        );
        vm.prank(tokenAdmin);
        token.transferTokenAdmin(makeAddr("nextAdmin"));

        vm.expectRevert(
            abi.encodeWithSelector(IDegenToken.UnauthorizedTokenAdmin.selector, tokenAdmin)
        );
        vm.prank(tokenAdmin);
        token.updateMetadata(bytes32(uint256(1)), bytes32(uint256(2)));
    }

    function testUpdateMetadataResolvesCanonicalCidV1Base16Uris() public {
        bytes32 nextMetadata = bytes32(uint256(0x1234));
        bytes32 nextImage = bytes32(uint256(0x5678));
        vm.prank(tokenAdmin);
        token.updateMetadata(nextMetadata, nextImage);

        assertEq(
            token.contractURI(),
            "ipfs://f017012200000000000000000000000000000000000000000000000000000000000001234"
        );
        assertEq(
            token.extraMetadata("image"),
            "ipfs://f017012200000000000000000000000000000000000000000000000000000000000005678"
        );
        assertEq(token.extraMetadata("unknown"), "");
    }

    function testZeroDigestResolvesToEmptyString() public {
        vm.prank(tokenAdmin);
        token.updateMetadata(bytes32(0), bytes32(0));
        assertEq(token.contractURI(), "");
        assertEq(token.extraMetadata("image"), "");
    }

    function testFreezeMetadataIsIrreversible() public {
        vm.prank(tokenAdmin);
        token.freezeMetadata();
        assertTrue(token.metadataFrozen());

        vm.expectRevert(IDegenToken.MetadataAlreadyFrozen.selector);
        vm.prank(tokenAdmin);
        token.freezeMetadata();
    }

    function testUpdateMetadataRevertsAfterFreeze() public {
        vm.prank(tokenAdmin);
        token.freezeMetadata();
        vm.expectRevert(IDegenToken.MetadataIsFrozen.selector);
        vm.prank(tokenAdmin);
        token.updateMetadata(bytes32(uint256(1)), bytes32(uint256(2)));
    }

    function testOnlyTokenAdminCanUpdateOrFreezeMetadata() public {
        address stranger = makeAddr("stranger");
        vm.expectRevert(
            abi.encodeWithSelector(IDegenToken.UnauthorizedTokenAdmin.selector, stranger)
        );
        vm.prank(stranger);
        token.updateMetadata(bytes32(uint256(1)), bytes32(uint256(2)));

        vm.expectRevert(
            abi.encodeWithSelector(IDegenToken.UnauthorizedTokenAdmin.selector, stranger)
        );
        vm.prank(stranger);
        token.freezeMetadata();
    }

    function testPermitKnownGoodVector() public {
        uint256 ownerKey = 0xA11CE;
        address owner = vm.addr(ownerKey);
        address spender = makeAddr("spender");
        vm.prank(supplyRecipient);
        token.transfer(owner, 10 ether);
        uint256 value = 4 ether;
        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = _permitDigest(owner, spender, value, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);

        token.permit(owner, spender, value, deadline, v, r, s);

        assertEq(token.allowance(owner, spender), value);
        assertEq(token.nonces(owner), 1);
    }

    function testPermitCrossChainReplayRejected() public {
        uint256 ownerKey = 0xA11CE;
        address owner = vm.addr(ownerKey);
        address spender = makeAddr("spender");
        uint256 deadline = block.timestamp + 1 days;
        uint256 originalChainId = block.chainid;
        bytes32 digest = _permitDigest(owner, spender, 1 ether, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);

        vm.chainId(originalChainId + 1);
        vm.expectRevert(IDegenToken.InvalidPermitSigner.selector);
        token.permit(owner, spender, 1 ether, deadline, v, r, s);
        assertEq(token.nonces(owner), 0);
    }

    function testEip712DomainAndSeparatorDescribeClone() public view {
        (
            bytes1 fields,
            string memory domainName,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        ) = token.eip712Domain();

        assertEq(uint8(fields), 0x0f);
        assertEq(domainName, "Degen Test");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(token));
        assertEq(salt, bytes32(0));
        assertEq(extensions.length, 0);
        assertEq(
            token.DOMAIN_SEPARATOR(),
            keccak256(
                abi.encode(
                    DOMAIN_TYPEHASH,
                    keccak256(bytes("Degen Test")),
                    keccak256(bytes("1")),
                    block.chainid,
                    address(token)
                )
            )
        );
    }

    function _newClone() private returns (DegenToken clone) {
        clone = DegenToken(Clones.clone(address(implementation)));
        clone.initialize(
            "Degen Test",
            "DTEST",
            supplyRecipient,
            tokenAdmin,
            METADATA_DIGEST,
            IMAGE_DIGEST,
            poolManager,
            positionManager,
            lpLocker
        );
    }

    function _permitDigest(
        address owner,
        address spender,
        uint256 value,
        uint256 nonce,
        uint256 deadline
    ) private view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                hex"1901",
                token.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline))
            )
        );
    }

    function _measureTransfers(bool warmStorage) private returns (uint256 v4Gas, uint256 v5Gas) {
        address v4Recipient = makeAddr("v4GasRecipient");
        address v5Recipient = makeAddr("v5GasRecipient");
        if (warmStorage) {
            v4Token.balanceOf(supplyRecipient);
            v4Token.balanceOf(v4Recipient);
            token.balanceOf(supplyRecipient);
            token.balanceOf(v5Recipient);
        }

        vm.prank(supplyRecipient);
        uint256 gasBefore = gasleft();
        v4Token.transfer(v4Recipient, 1 ether);
        v4Gas = gasBefore - gasleft();

        vm.prank(supplyRecipient);
        gasBefore = gasleft();
        token.transfer(v5Recipient, 1 ether);
        v5Gas = gasBefore - gasleft();
    }
}
