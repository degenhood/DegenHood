// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Strict parser for DegenHood's canonical dag-pb/sha2-256 CIDv1 base16 URI form.
library CanonicalIpfsDigest {
    error InvalidCanonicalIpfsUri();

    bytes16 private constant URI_PREFIX = "ipfs://f01701220";

    function parse(string calldata uri) internal pure returns (bytes32 digest) {
        bytes calldata encoded = bytes(uri);
        if (encoded.length == 0) return bytes32(0);
        if (encoded.length != 80) revert InvalidCanonicalIpfsUri();

        for (uint256 i; i < 16; ++i) {
            if (encoded[i] != URI_PREFIX[i]) revert InvalidCanonicalIpfsUri();
        }

        uint256 value;
        for (uint256 i = 16; i < 80; ++i) {
            uint8 character = uint8(encoded[i]);
            uint256 nibble;
            if (character >= uint8(bytes1("0")) && character <= uint8(bytes1("9"))) {
                nibble = character - uint8(bytes1("0"));
            } else if (character >= uint8(bytes1("a")) && character <= uint8(bytes1("f"))) {
                nibble = character - uint8(bytes1("a")) + 10;
            } else {
                revert InvalidCanonicalIpfsUri();
            }
            value = (value << 4) | nibble;
        }
        digest = bytes32(value);
    }
}
