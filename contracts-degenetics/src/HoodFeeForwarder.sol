// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IWETH9 {
    function balanceOf(address) external view returns (uint256);
    function withdraw(uint256) external;
}

interface IERC20Minimal {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IDegensNotify {
    function notifyLpFees() external payable;
    function notifyRoyalty() external payable;
}

/// @title HoodFeeForwarder
/// @notice Immutable, permissionless bridge between ERC20-denominated fee deliveries
/// and the DegenhoodDegens ETH distributor. The v4 fee locker delivers LP fees as
/// WETH (and marketplaces settle offer royalties in WETH); this contract unwraps
/// and forwards them through the correct tagged entrypoint. Any $DEGEN that lands
/// here burns - all $DEGEN that moves through the machine burns.
///
/// Two deployments, one code path:
///   - lp mode (royaltyMode = false): the token's fee BENEFICIARY. forward() sends
///     via notifyLpFees (tagged LpFee).
///   - royalty mode (royaltyMode = true): the collection's ERC-2981 receiver
///     (setRoyaltyReceiverOnce). forward() sends via notifyRoyalty (tagged Royalty).
///
/// No owner, no admin, no rescue: everything it can ever do is fixed at deployment.
/// The operator keeps control ABOVE this contract (the fee admin can repoint the
/// beneficiary away), never inside it.
contract HoodFeeForwarder is ReentrancyGuard {
    IWETH9 public immutable weth;
    IERC20Minimal public immutable degen;
    IDegensNotify public immutable degens;
    bool public immutable royaltyMode;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    event Forwarded(uint256 ethAmt, uint256 degenBurned, bool royaltyMode);

    constructor(address weth_, address degen_, address payable degens_, bool royaltyMode_) {
        require(weth_ != address(0) && degen_ != address(0) && degens_ != address(0), "zero");
        weth = IWETH9(weth_);
        degen = IERC20Minimal(degen_);
        degens = IDegensNotify(degens_);
        royaltyMode = royaltyMode_;
    }

    /// @dev WETH.withdraw pays ETH back here; stray direct ETH is also accepted
    /// and swept by the next forward().
    receive() external payable {}

    /// @notice permissionless: unwrap all held WETH, forward all held ETH through
    /// the mode's tagged entrypoint, burn all held $DEGEN.
    function forward() external nonReentrant {
        uint256 wethBal = weth.balanceOf(address(this));
        if (wethBal > 0) weth.withdraw(wethBal);
        uint256 ethAmt = address(this).balance;
        if (ethAmt > 0) {
            if (royaltyMode) degens.notifyRoyalty{value: ethAmt}();
            else degens.notifyLpFees{value: ethAmt}();
        }
        uint256 degenBal = degen.balanceOf(address(this));
        if (degenBal > 0) require(degen.transfer(DEAD, degenBal), "burn");
        emit Forwarded(ethAmt, degenBal, royaltyMode);
    }
}
