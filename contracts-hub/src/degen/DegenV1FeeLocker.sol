// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IDegenV1FeeLocker} from "../interfaces/IDegenV1FeeLocker.sol";

/// @title DegenV1FeeLocker
/// @notice Immutable-depositor WETH credits with permissionless, destination-bound delivery.
/// @dev Holds creator fees only. It has no owner, sweep, redirect, expiry, or arbitrary-token path.
contract DegenV1FeeLocker is IDegenV1FeeLocker, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable override WETH;
    address public immutable override LP_LOCKER;
    address public immutable override HOOK;

    mapping(address beneficiary => uint256 balance) public override feesToClaim;
    uint256 public override totalLiability;

    constructor(address weth, address lpLocker, address hook) {
        if (weth == address(0) || weth.code.length == 0) revert InvalidWeth();
        if (lpLocker == address(0) || hook == address(0)) revert InvalidDepositor();
        if (lpLocker == hook) revert DuplicateDepositor();

        WETH = weth;
        LP_LOCKER = lpLocker;
        HOOK = hook;
    }

    function allowedDepositors(address depositor) public view override returns (bool) {
        return depositor == LP_LOCKER || depositor == HOOK;
    }

    function storeFees(address beneficiary, uint256 amount)
        external
        override
        nonReentrant
        returns (uint256 received)
    {
        if (!allowedDepositors(msg.sender)) revert UnauthorizedDepositor(msg.sender);
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
