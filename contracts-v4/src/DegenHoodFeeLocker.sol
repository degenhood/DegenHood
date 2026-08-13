// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IDegenHoodFeeLocker} from "./interfaces/IDegenHoodFeeLocker.sol";

/*
HEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEENEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEOoooooOEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEOooooooooooNEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEOooooooooooooooHEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEEEEEEEEEOooooooooooooooooooNEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEEEEEEEhooooooooooooooooooooooEEEEEEEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEEEEEEoooooooooooooooooooooooooOEEEEEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEEEEOooooooooooooooooooooooooooooNEEEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEEEooooooooooooooeEnooooooooooooooOEEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEDoooooooooooeEEEEEEEEEEeoooooooooooEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEoooooooogeEEEEEEEEEEEEEEEEEEeooooooooNEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEoooooogEEEEEEEEEEEEEEEEEEEEEEEEEEooooooOEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEooooooooooOOHEEEEEEEEEEEEEEEEhOOoooooooooOEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEOooooooogEoooooooooooOOOooooooooooonEooooooooEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEDooooooooEEEooooooooooooooooooooooodEEoooooooooEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEooooooooooOEEoooooooooeEEooooooooogEEoooooooooogEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEooooooooooooOEEEEEEnEEEEEEEenEEEEEEooooooooooogEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEooooooooooooNEEEEEEEEEEEEEEEEEEOoooooooooooeEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEENooooooooooEEEEEEEEEEEEEEEEoooooooooeEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEEEEhoooooooOEEEEEEEEEEEEoooooooeEEEEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEEEEEEEEEnooooNEEEEEEEEoooogEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEnoEEEEEOenEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE
gEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE
                                   DEGENHOOD
*/

/// @title DegenHoodFeeLocker
/// @notice WETH-only, fully backed beneficiary credits with permissionless delivery.
/// @dev Protocol-wide WETH accounting vault with revocable depositors, destination-bound claims,
///      and no arbitrary-token custody or caller-selected claim recipient.
contract DegenHoodFeeLocker is IDegenHoodFeeLocker, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable override WETH;

    mapping(address depositor => bool allowed) public override allowedDepositors;
    mapping(address beneficiary => uint256 balance) public override feesToClaim;
    uint256 public override totalLiability;

    constructor(address initialOwner, address weth) Ownable(initialOwner) {
        if (weth == address(0)) revert InvalidWeth();
        WETH = weth;
    }

    function setDepositor(address depositor, bool allowed) external override onlyOwner {
        if (depositor == address(0)) revert InvalidDepositor();
        allowedDepositors[depositor] = allowed;
        emit DepositorSet(depositor, allowed);
    }

    function storeFees(address beneficiary, uint256 amount)
        external
        override
        nonReentrant
        returns (uint256 received)
    {
        if (!allowedDepositors[msg.sender]) revert UnauthorizedDepositor(msg.sender);
        if (beneficiary == address(0)) revert InvalidBeneficiary();
        if (amount == 0) revert ZeroAmount();

        IERC20 weth = IERC20(WETH);
        uint256 balanceBefore = weth.balanceOf(address(this));
        weth.safeTransferFrom(msg.sender, address(this), amount);
        received = weth.balanceOf(address(this)) - balanceBefore;
        if (received == 0) revert ZeroReceived();

        uint256 newBalance = feesToClaim[beneficiary] + received;
        feesToClaim[beneficiary] = newBalance;
        totalLiability += received;

        emit FeesStored(msg.sender, beneficiary, WETH, amount, received, newBalance);
    }

    function claimFor(address beneficiary) external override nonReentrant returns (uint256 amount) {
        if (beneficiary == address(0)) revert InvalidBeneficiary();

        amount = feesToClaim[beneficiary];
        if (amount == 0) return 0;

        feesToClaim[beneficiary] = 0;
        totalLiability -= amount;
        IERC20(WETH).safeTransfer(beneficiary, amount);

        emit FeesClaimed(msg.sender, beneficiary, WETH, amount);
    }
}
