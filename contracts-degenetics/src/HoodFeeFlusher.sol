// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface ILpLocker {
    function collectRewards(address token) external returns (uint256 tokenFees, uint256 wethFees);
}

interface IFeeLocker {
    function claimFor(address beneficiary) external returns (uint256 amount);
}

interface IForwarder {
    function forward() external;
}

/// @title HoodFeeFlusher
/// @notice One permissionless call that walks the whole fee path: harvest the pool's
/// LP fees, claim the forwarder's share out of the fee locker, then unwrap and route
/// it into the Degens holder pool. Every underlying step is already permissionless -
/// this only saves callers from sending three transactions.
///
/// Immutable, no owner, no funds held, no admin surface. Each step is wrapped in
/// try/catch so a no-op or a transient failure in one stage never blocks the others;
/// the emitted event reports exactly which stages ran.
contract HoodFeeFlusher {
    ILpLocker public immutable lpLocker;
    IFeeLocker public immutable feeLocker;
    IForwarder public immutable forwarder;
    address public immutable token;

    event Flushed(address indexed caller, bool harvested, bool claimed, bool routed);

    constructor(address lpLocker_, address feeLocker_, address forwarder_, address token_) {
        require(
            lpLocker_ != address(0) && feeLocker_ != address(0) && forwarder_ != address(0) && token_ != address(0),
            "zero"
        );
        lpLocker = ILpLocker(lpLocker_);
        feeLocker = IFeeLocker(feeLocker_);
        forwarder = IForwarder(forwarder_);
        token = token_;
    }

    /// @notice harvest -> claim -> route, in one transaction. Anyone may call it.
    function flush() external returns (bool harvested, bool claimed, bool routed) {
        try lpLocker.collectRewards(token) {
            harvested = true;
        } catch {}
        try feeLocker.claimFor(address(forwarder)) {
            claimed = true;
        } catch {}
        try forwarder.forward() {
            routed = true;
        } catch {}
        emit Flushed(msg.sender, harvested, claimed, routed);
    }
}
