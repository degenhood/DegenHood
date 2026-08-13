// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Abstraction over DERP (miner-certified entropy on Robinhood Chain).
/// Implementations must return entropy for a round ONLY once that round is
/// finalized on-chain, and must revert (or return unavailable) before then.
/// Wire the concrete adapter after fork-test (c) confirms the DERP interface.
interface IEntropySource {
    /// @return the current (latest finalized) round id
    function currentRound() external view returns (uint64);

    /// @notice entropy for a finalized round; MUST revert if not yet available
    function entropyOf(uint64 round) external view returns (bytes32);

    /// @notice first round id that is strictly in the future at call time
    function nextRound() external view returns (uint64);
}
