// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";

import {DegenHoodFeeLocker} from "../src/DegenHoodFeeLocker.sol";
import {IDegenHoodFeeLocker} from "../src/interfaces/IDegenHoodFeeLocker.sol";

contract MockFeeLockerWeth is ERC20 {
    error TransferBlocked();

    uint256 public transferFeeBps;
    address public blockedSender;
    address public reentryTarget;
    address public reentryBeneficiary;
    bool public blockTransfer;
    bool public reenterOnTransfer;
    bool public reentryAttempted;
    bool public reentrySucceeded;

    constructor() ERC20("Wrapped Ether", "WETH") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setTransferFeeBps(uint256 feeBps) external {
        transferFeeBps = feeBps;
    }

    function setBlockedSender(address sender, bool blocked) external {
        blockedSender = sender;
        blockTransfer = blocked;
    }

    function setReentry(address target, address beneficiary) external {
        reentryTarget = target;
        reentryBeneficiary = beneficiary;
        reenterOnTransfer = true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (blockTransfer && msg.sender == blockedSender) revert TransferBlocked();
        if (reenterOnTransfer && msg.sender == reentryTarget) {
            reenterOnTransfer = false;
            reentryAttempted = true;
            (reentrySucceeded,) = reentryTarget.call(
                abi.encodeCall(IDegenHoodFeeLocker.claimFor, (reentryBeneficiary))
            );
        }
        return super.transfer(to, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0) && transferFeeBps != 0) {
            uint256 fee = amount * transferFeeBps / 10_000;
            super._update(from, to, amount - fee);
            super._update(from, address(0), fee);
            return;
        }
        super._update(from, to, amount);
    }
}

contract ContractBeneficiary {}

contract DegenHoodFeeLockerTest is Test {
    event DepositorSet(address indexed depositor, bool allowed);
    event FeesStored(
        address indexed depositor,
        address indexed beneficiary,
        address indexed weth,
        uint256 requestedAmount,
        uint256 receivedAmount,
        uint256 newBalance
    );
    event FeesClaimed(
        address indexed caller, address indexed beneficiary, address indexed weth, uint256 amount
    );

    MockFeeLockerWeth private weth;
    DegenHoodFeeLocker private locker;

    address private depositor = makeAddr("depositor");
    address private beneficiary = makeAddr("beneficiary");
    address private stranger = makeAddr("stranger");

    function setUp() public {
        weth = new MockFeeLockerWeth();
        locker = new DegenHoodFeeLocker(address(this), address(weth));
        weth.mint(depositor, 100 ether);
        vm.prank(depositor);
        weth.approve(address(locker), type(uint256).max);
    }

    function testOnlyEnabledDepositorMayStoreFees() public {
        vm.prank(depositor);
        vm.expectRevert(
            abi.encodeWithSelector(IDegenHoodFeeLocker.UnauthorizedDepositor.selector, depositor)
        );
        locker.storeFees(beneficiary, 1 ether);

        locker.setDepositor(depositor, true);
        vm.prank(depositor);
        locker.storeFees(beneficiary, 1 ether);

        assertEq(locker.feesToClaim(beneficiary), 1 ether);
    }

    function testConstructorRejectsZeroWeth() public {
        vm.expectRevert(IDegenHoodFeeLocker.InvalidWeth.selector);
        new DegenHoodFeeLocker(address(this), address(0));
    }

    function testOnlyOwnerMayConfigureDepositors() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger)
        );
        locker.setDepositor(depositor, true);
    }

    function testOwnerMayEnableAndRevokeDepositorWithoutErasingCredits() public {
        vm.expectEmit(true, false, false, true, address(locker));
        emit DepositorSet(depositor, true);
        locker.setDepositor(depositor, true);

        vm.prank(depositor);
        locker.storeFees(beneficiary, 2 ether);

        vm.expectEmit(true, false, false, true, address(locker));
        emit DepositorSet(depositor, false);
        locker.setDepositor(depositor, false);

        assertEq(locker.feesToClaim(beneficiary), 2 ether);
        assertEq(locker.totalLiability(), 2 ether);

        vm.prank(depositor);
        vm.expectRevert(
            abi.encodeWithSelector(IDegenHoodFeeLocker.UnauthorizedDepositor.selector, depositor)
        );
        locker.storeFees(beneficiary, 1 ether);
    }

    function testRejectsZeroDepositorBeneficiaryAndAmount() public {
        vm.expectRevert(IDegenHoodFeeLocker.InvalidDepositor.selector);
        locker.setDepositor(address(0), true);

        locker.setDepositor(depositor, true);

        vm.prank(depositor);
        vm.expectRevert(IDegenHoodFeeLocker.InvalidBeneficiary.selector);
        locker.storeFees(address(0), 1 ether);

        vm.prank(depositor);
        vm.expectRevert(IDegenHoodFeeLocker.ZeroAmount.selector);
        locker.storeFees(beneficiary, 0);
    }

    function testDepositTransfersWethAndCreditsOnlyAmountActuallyReceived() public {
        locker.setDepositor(depositor, true);
        weth.setTransferFeeBps(1000);

        vm.expectEmit(true, true, true, true, address(locker));
        emit FeesStored(depositor, beneficiary, address(weth), 10 ether, 9 ether, 9 ether);
        vm.prank(depositor);
        uint256 received = locker.storeFees(beneficiary, 10 ether);

        assertEq(received, 9 ether);
        assertEq(weth.balanceOf(address(locker)), 9 ether);
        assertEq(locker.feesToClaim(beneficiary), 9 ether);
        assertEq(locker.totalLiability(), 9 ether);
    }

    function testDepositRejectsZeroActualReceiptWithoutCreatingCredit() public {
        locker.setDepositor(depositor, true);
        weth.setTransferFeeBps(10_000);

        vm.prank(depositor);
        vm.expectRevert(IDegenHoodFeeLocker.ZeroReceived.selector);
        locker.storeFees(beneficiary, 1 ether);

        assertEq(locker.feesToClaim(beneficiary), 0);
        assertEq(locker.totalLiability(), 0);
        assertEq(weth.balanceOf(address(locker)), 0);
        assertEq(weth.balanceOf(depositor), 100 ether);
    }

    function testLockerRejectsNativeEth() public {
        vm.deal(address(this), 1 ether);
        (bool success,) = address(locker).call{value: 1 ether}("");

        assertFalse(success);
        assertEq(address(locker).balance, 0);
    }

    function testFuzzDepositConservesBacking(uint96 rawAmount) public {
        uint256 amount = bound(uint256(rawAmount), 1, 100 ether);
        locker.setDepositor(depositor, true);

        vm.prank(depositor);
        uint256 received = locker.storeFees(beneficiary, amount);

        assertEq(received, amount);
        assertEq(locker.feesToClaim(beneficiary), amount);
        assertEq(locker.totalLiability(), amount);
        assertEq(weth.balanceOf(address(locker)), amount);
    }

    function testAnyCallerMayClaimButPaymentOnlyGoesToBeneficiary() public {
        _deposit(beneficiary, 2 ether);

        vm.expectEmit(true, true, true, true, address(locker));
        emit FeesClaimed(stranger, beneficiary, address(weth), 2 ether);
        vm.prank(stranger);
        uint256 claimed = locker.claimFor(beneficiary);

        assertEq(claimed, 2 ether);
        assertEq(weth.balanceOf(beneficiary), 2 ether);
        assertEq(weth.balanceOf(stranger), 0);
        assertEq(locker.feesToClaim(beneficiary), 0);
        assertEq(locker.totalLiability(), 0);
    }

    function testCallerCannotSubstituteClaimRecipient() public {
        _deposit(beneficiary, 1 ether);

        vm.prank(stranger);
        (bool success,) = address(locker)
            .call(abi.encodeWithSignature("claimFor(address,address)", beneficiary, stranger));

        assertFalse(success);
        assertEq(locker.feesToClaim(beneficiary), 1 ether);
        assertEq(weth.balanceOf(stranger), 0);
    }

    function testZeroBalanceClaimIsIdempotent() public {
        vm.prank(stranger);
        assertEq(locker.claimFor(beneficiary), 0);
        vm.prank(stranger);
        assertEq(locker.claimFor(beneficiary), 0);
        assertEq(locker.totalLiability(), 0);
    }

    function testClaimRejectsZeroBeneficiary() public {
        vm.expectRevert(IDegenHoodFeeLocker.InvalidBeneficiary.selector);
        locker.claimFor(address(0));
    }

    function testClaimDebitsBeforeTransferAndCannotBeReentered() public {
        _deposit(beneficiary, 3 ether);
        weth.setReentry(address(locker), beneficiary);

        vm.prank(stranger);
        locker.claimFor(beneficiary);

        assertTrue(weth.reentryAttempted());
        assertFalse(weth.reentrySucceeded());
        assertEq(weth.balanceOf(beneficiary), 3 ether);
        assertEq(locker.feesToClaim(beneficiary), 0);
        assertEq(locker.totalLiability(), 0);
    }

    function testClaimTransferFailureRevertsWithoutLosingCredit() public {
        _deposit(beneficiary, 4 ether);
        weth.setBlockedSender(address(locker), true);

        vm.prank(stranger);
        vm.expectRevert(MockFeeLockerWeth.TransferBlocked.selector);
        locker.claimFor(beneficiary);

        assertEq(locker.feesToClaim(beneficiary), 4 ether);
        assertEq(locker.totalLiability(), 4 ether);
        assertEq(weth.balanceOf(address(locker)), 4 ether);
        assertEq(weth.balanceOf(beneficiary), 0);
    }

    function testContractBeneficiaryReceivesOrdinaryErc20Transfer() public {
        ContractBeneficiary contractBeneficiary = new ContractBeneficiary();
        _deposit(address(contractBeneficiary), 5 ether);

        vm.prank(stranger);
        locker.claimFor(address(contractBeneficiary));

        assertEq(weth.balanceOf(address(contractBeneficiary)), 5 ether);
    }

    function testFuzzClaimConservesBacking(uint96 rawAmount) public {
        uint256 amount = bound(uint256(rawAmount), 1, 100 ether);
        _deposit(beneficiary, amount);

        vm.prank(stranger);
        uint256 claimed = locker.claimFor(beneficiary);

        assertEq(claimed, amount);
        assertEq(weth.balanceOf(beneficiary), amount);
        assertEq(weth.balanceOf(address(locker)), 0);
        assertEq(locker.feesToClaim(beneficiary), 0);
        assertEq(locker.totalLiability(), 0);
    }

    function _deposit(address recipient, uint256 amount) private {
        locker.setDepositor(depositor, true);
        vm.prank(depositor);
        locker.storeFees(recipient, amount);
    }
}
