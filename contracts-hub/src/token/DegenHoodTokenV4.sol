// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title DegenHoodTokenV4
/// @notice Narrow fixed-supply ERC-20 used by reviewed DegenHood launch modules.
/// @dev Fee, LP, treasury, callback, mint, transfer-tax, allowlist, and wallet-limit
///      capabilities are intentionally absent.
contract DegenHoodTokenV4 is ERC20 {
    uint256 public constant STANDARD_SUPPLY = 100_000_000_000 ether;

    error InvalidRecipient();
    error InvalidTokenAdmin();
    error UnauthorizedTokenAdmin(address caller);

    event MetadataUpdated(string contractURI, string imageURI);
    event TokenAdminUpdated(address indexed previousAdmin, address indexed newAdmin);

    address public tokenAdmin;

    string private _contractURI;
    string private _imageURI;

    constructor(
        string memory name_,
        string memory symbol_,
        address supplyRecipient,
        address tokenAdmin_,
        string memory contractURI_,
        string memory imageURI_
    ) ERC20(name_, symbol_) {
        if (supplyRecipient == address(0)) revert InvalidRecipient();
        if (tokenAdmin_ == address(0)) revert InvalidTokenAdmin();

        tokenAdmin = tokenAdmin_;
        _contractURI = contractURI_;
        _imageURI = imageURI_;
        _mint(supplyRecipient, STANDARD_SUPPLY);
    }

    function updateMetadata(string calldata contractURI_, string calldata imageURI_) external {
        _checkTokenAdmin();
        _contractURI = contractURI_;
        _imageURI = imageURI_;
        emit MetadataUpdated(contractURI_, imageURI_);
    }

    function transferTokenAdmin(address newAdmin) external {
        _checkTokenAdmin();
        if (newAdmin == address(0)) revert InvalidTokenAdmin();

        address previousAdmin = tokenAdmin;
        tokenAdmin = newAdmin;
        emit TokenAdminUpdated(previousAdmin, newAdmin);
    }

    function contractURI() external view returns (string memory) {
        return _contractURI;
    }

    function extraMetadata(string calldata key) external view returns (string memory) {
        if (keccak256(bytes(key)) == keccak256("image")) return _imageURI;
        return "";
    }

    function _checkTokenAdmin() private view {
        if (msg.sender != tokenAdmin) revert UnauthorizedTokenAdmin(msg.sender);
    }
}
