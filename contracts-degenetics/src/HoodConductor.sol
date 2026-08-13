// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IEntropySource} from "./interfaces/IEntropySource.sol";

/// @title HoodConductor - DegenHood's own commit-reveal entropy beacon (v1)
contract HoodConductor is IEntropySource {
    /// @notice Rotates the keeper key; never signs the hot loop itself.
    address public immutable owner;
    /// @notice The hot keeper key (commit/reveal). Dedicated low-value wallet,
    /// rotatable by the owner if lost or leaked - liveness is never key-bound.
    address public operator;
    uint64 public constant TARGET_DELAY = 30;

    struct Round {
        bytes32 commitment;
        bytes32 seed;
        uint64 targetBlock;
        bytes32 wordBase;
    }
    Round[] public rounds;
    uint64 public revealedCount;
    uint64 public snappedCount;

    event Committed(uint64 fromIndex, uint256 count);
    event OperatorRotated(address indexed previous, address indexed next);
    event Revealed(uint64 indexed index, uint64 targetBlock);
    event Rearmed(uint64 indexed index, uint64 targetBlock);
    event Snapped(uint64 indexed index, bytes32 wordBase);

    error NotOperator();
    error NotOwner();
    error BadReveal();
    error NotReady();

    constructor(address operator_, address owner_) {
        require(operator_ != address(0) && owner_ != address(0), "zero");
        operator = operator_;
        owner = owner_;
    }

    /// @notice Swap the keeper key (compromise or loss recovery). Owner-only.
    function setOperator(address next) external {
        if (msg.sender != owner) revert NotOwner();
        require(next != address(0), "zero");
        emit OperatorRotated(operator, next);
        operator = next;
    }

    function commit(bytes32[] calldata hashes) external {
        if (msg.sender != operator) revert NotOperator();
        uint64 from = uint64(rounds.length);
        for (uint256 i; i < hashes.length; ++i) {
            rounds.push(Round(hashes[i], 0, 0, 0));
        }
        emit Committed(from, hashes.length);
    }

    function reveal(bytes32 seed) external {
        if (msg.sender != operator) revert NotOperator();
        Round storage r = rounds[revealedCount];
        if (keccak256(abi.encodePacked(seed)) != r.commitment) revert BadReveal();
        r.seed = seed;
        r.targetBlock = uint64(block.number) + TARGET_DELAY;
        emit Revealed(revealedCount, r.targetBlock);
        ++revealedCount;
    }

    function snap() external {
        Round storage r = rounds[snappedCount];
        if (r.targetBlock == 0 || block.number <= r.targetBlock) revert NotReady();
        bytes32 bh = blockhash(r.targetBlock);
        if (bh == bytes32(0)) revert NotReady();
        r.wordBase = keccak256(abi.encodePacked(r.seed, bh, snappedCount));
        emit Snapped(snappedCount, r.wordBase);
        ++snappedCount;
    }

    function rearm() external {
        Round storage r = rounds[snappedCount];
        if (r.targetBlock == 0) revert NotReady();
        if (block.number <= r.targetBlock + 255) revert NotReady();
        r.targetBlock = uint64(block.number) + TARGET_DELAY;
        emit Rearmed(snappedCount, r.targetBlock);
    }

    function currentRound() external view returns (uint64) {
        return snappedCount;
    }

    function nextRound() external view returns (uint64) {
        return revealedCount + 1;
    }

    function entropyOf(uint64 round) external view returns (bytes32) {
        uint64 idx = round - 1;
        if (idx >= snappedCount) revert NotReady();
        return rounds[idx].wordBase;
    }

    function roundsCommitted() external view returns (uint256) {
        return rounds.length;
    }
}
