// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Test-only model of the salt-prefixed universal CREATE2 deployer interface.
contract UniversalCreate2ProxyMock {
    fallback() external payable {
        assembly ("memory-safe") {
            if lt(calldatasize(), 33) { revert(0, 0) }
            let initCodeSize := sub(calldatasize(), 32)
            calldatacopy(0, 32, initCodeSize)
            let deployed := create2(callvalue(), 0, initCodeSize, calldataload(0))
            if iszero(extcodesize(deployed)) { revert(0, 0) }
            mstore(0, deployed)
            return(12, 20)
        }
    }
}
