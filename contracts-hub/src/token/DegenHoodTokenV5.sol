// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {IDegenHoodTokenV5} from "../interfaces/IDegenHoodTokenV5.sol";

/// @title DegenHoodTokenV5
/// @notice Clone-safe fixed-supply DegenHood token with content-addressed metadata and permit.
/// @dev The implementation constructor locks only implementation storage. ERC-1167 clones retain
///      zeroed storage and can initialize exactly once.
contract DegenHoodTokenV5 is IDegenHoodTokenV5, IERC20Errors {
    uint256 public constant STANDARD_SUPPLY = 100_000_000_000 ether;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_WALLET_BPS = 200;
    uint256 public constant MAX_TX_BPS = 220;
    uint40 public constant FLAT_RESTRICTION_SECONDS = 60;
    uint40 public constant RAMP_RESTRICTION_SECONDS = 60;

    bytes32 private constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant PERMIT_TYPEHASH = keccak256(
        "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
    );
    bytes32 private constant VERSION_HASH = keccak256("1");
    bytes32 private constant IMAGE_KEY_HASH = keccak256("image");
    bytes16 private constant HEX_DIGITS = "0123456789abcdef";
    string private constant IPFS_PREFIX = "ipfs://f01701220";

    // Slot 0. Declaration order and widths are a reviewed storage invariant.
    address public tokenAdmin;
    bool public initialised;
    bool public metadataFrozen;
    uint40 public flatEndTime;
    uint40 public rampEndTime;

    string private _name;
    string private _symbol;
    bytes32 public metadataDigest;
    bytes32 public imageDigest;
    address public poolManager;
    address public positionManager;
    address public launchModule;
    address public lpLocker;
    uint256 private _totalSupply;
    mapping(address account => uint256 balance) private _balances;
    mapping(address owner => mapping(address spender => uint256 amount)) private _allowances;
    mapping(address owner => uint256 nonce) public nonces;

    constructor() {
        tokenAdmin = address(1);
        initialised = true;
        metadataFrozen = true;
    }

    function initialize(
        string calldata name_,
        string calldata symbol_,
        address supplyRecipient,
        address tokenAdmin_,
        bytes32 metadataDigest_,
        bytes32 imageDigest_,
        address poolManager_,
        address positionManager_,
        address lpLocker_
    ) external {
        if (initialised) revert AlreadyInitialised();
        if (supplyRecipient == address(0)) revert InvalidRecipient();
        if (tokenAdmin_ == address(0)) revert InvalidTokenAdmin();
        if (
            poolManager_ == address(0) || positionManager_ == address(0) || lpLocker_ == address(0)
                || poolManager_ == positionManager_ || poolManager_ == supplyRecipient
                || poolManager_ == lpLocker_ || positionManager_ == supplyRecipient
                || positionManager_ == lpLocker_ || supplyRecipient == lpLocker_
        ) revert InvalidStructuralAddress();
        if (
            block.timestamp > type(uint40).max - FLAT_RESTRICTION_SECONDS - RAMP_RESTRICTION_SECONDS
        ) {
            revert RestrictionTimeOverflow();
        }

        initialised = true;
        tokenAdmin = tokenAdmin_;
        flatEndTime = uint40(block.timestamp) + FLAT_RESTRICTION_SECONDS;
        rampEndTime = flatEndTime + RAMP_RESTRICTION_SECONDS;
        _name = name_;
        _symbol = symbol_;
        metadataDigest = metadataDigest_;
        imageDigest = imageDigest_;
        poolManager = poolManager_;
        positionManager = positionManager_;
        launchModule = supplyRecipient;
        lpLocker = lpLocker_;
        _totalSupply = STANDARD_SUPPLY;
        _balances[supplyRecipient] = STANDARD_SUPPLY;
        emit Transfer(address(0), supplyRecipient, STANDARD_SUPPLY);
    }

    function name() external view returns (string memory) {
        return _name;
    }

    function symbol() external view returns (string memory) {
        return _symbol;
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        _approve(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        _spendAllowance(from, msg.sender, value);
        _transfer(from, to, value);
        return true;
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    function burnFrom(address account, uint256 amount) external {
        _spendAllowance(account, msg.sender, amount);
        _burn(account, amount);
    }

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        if (block.timestamp > deadline) revert PermitExpired(deadline);
        uint256 nonce = nonces[owner];
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", DOMAIN_SEPARATOR(), structHash));
        if (ECDSA.recover(digest, v, r, s) != owner || owner == address(0)) {
            revert InvalidPermitSigner();
        }
        nonces[owner] = nonce + 1;
        _approve(owner, spender, value);
    }

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes(_name)),
                VERSION_HASH,
                block.chainid,
                address(this)
            )
        );
    }

    function eip712Domain()
        external
        view
        returns (
            bytes1 fields,
            string memory domainName,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        )
    {
        fields = hex"0f";
        domainName = _name;
        version = "1";
        chainId = block.chainid;
        verifyingContract = address(this);
        salt = bytes32(0);
        extensions = new uint256[](0);
    }

    function updateMetadata(bytes32 metadataDigest_, bytes32 imageDigest_) external {
        _checkTokenAdmin();
        if (metadataFrozen) revert MetadataIsFrozen();
        metadataDigest = metadataDigest_;
        imageDigest = imageDigest_;
        emit MetadataUpdated(_ipfs(metadataDigest_), _ipfs(imageDigest_));
    }

    function freezeMetadata() external {
        _checkTokenAdmin();
        if (metadataFrozen) revert MetadataAlreadyFrozen();
        metadataFrozen = true;
        emit MetadataFrozen();
    }

    function transferTokenAdmin(address newAdmin) external {
        _checkTokenAdmin();
        if (newAdmin == address(0)) revert InvalidTokenAdmin();
        address previousAdmin = tokenAdmin;
        tokenAdmin = newAdmin;
        emit TokenAdminUpdated(previousAdmin, newAdmin);
    }

    function renounceTokenAdmin() external {
        _checkTokenAdmin();
        if (!metadataFrozen) revert MetadataNotFrozen();
        address previousAdmin = tokenAdmin;
        tokenAdmin = address(0);
        emit TokenAdminUpdated(previousAdmin, address(0));
    }

    function contractURI() external view returns (string memory) {
        return _ipfs(metadataDigest);
    }

    function extraMetadata(string calldata key) external view returns (string memory) {
        if (keccak256(bytes(key)) == IMAGE_KEY_HASH) return _ipfs(imageDigest);
        return "";
    }

    function restrictionStartTime() external view returns (uint40) {
        if (flatEndTime == 0) return 0;
        return flatEndTime - FLAT_RESTRICTION_SECONDS;
    }

    function currentWalletCapBps() public view returns (uint256) {
        return _currentCapBps(MAX_WALLET_BPS);
    }

    function currentTxCapBps() public view returns (uint256) {
        return _currentCapBps(MAX_TX_BPS);
    }

    function _transfer(address from, address to, uint256 value) private {
        if (from == address(0)) revert ERC20InvalidSender(address(0));
        if (to == address(0)) revert ERC20InvalidReceiver(address(0));
        uint256 fromBalance = _balances[from];
        if (fromBalance < value) revert ERC20InsufficientBalance(from, fromBalance, value);
        _enforceRestrictions(from, to, value);
        unchecked {
            _balances[from] = fromBalance - value;
            _balances[to] += value;
        }
        emit Transfer(from, to, value);
    }

    function _enforceRestrictions(address from, address to, uint256 value) private view {
        if (block.timestamp >= rampEndTime) return;
        if (from == launchModule || from == lpLocker || _isStructuralDestination(to)) return;

        uint256 txMaximum = STANDARD_SUPPLY * _currentCapBps(MAX_TX_BPS) / BPS_DENOMINATOR;
        if (value > txMaximum) revert MaxTransactionExceeded(value, txMaximum);
        uint256 walletMaximum = STANDARD_SUPPLY * _currentCapBps(MAX_WALLET_BPS) / BPS_DENOMINATOR;
        uint256 resultingBalance = _balances[to] + value;
        if (resultingBalance > walletMaximum) {
            revert MaxWalletExceeded(to, resultingBalance, walletMaximum);
        }
    }

    function _currentCapBps(uint256 initialCapBps) private view returns (uint256) {
        if (block.timestamp >= rampEndTime) return BPS_DENOMINATOR;
        if (block.timestamp < flatEndTime) return initialCapBps;
        unchecked {
            return initialCapBps
                + ((BPS_DENOMINATOR - initialCapBps) * (block.timestamp - flatEndTime))
                / (rampEndTime - flatEndTime);
        }
    }

    function _isStructuralDestination(address account) private view returns (bool) {
        return account == poolManager || account == positionManager || account == launchModule
            || account == lpLocker;
    }

    function _burn(address account, uint256 value) private {
        if (account == address(0)) revert ERC20InvalidSender(address(0));
        uint256 accountBalance = _balances[account];
        if (accountBalance < value) {
            revert ERC20InsufficientBalance(account, accountBalance, value);
        }
        unchecked {
            _balances[account] = accountBalance - value;
            _totalSupply -= value;
        }
        emit Transfer(account, address(0), value);
    }

    function _approve(address owner, address spender, uint256 value) private {
        if (owner == address(0)) revert ERC20InvalidApprover(address(0));
        if (spender == address(0)) revert ERC20InvalidSpender(address(0));
        _allowances[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    function _spendAllowance(address owner, address spender, uint256 value) private {
        uint256 currentAllowance = _allowances[owner][spender];
        if (currentAllowance == type(uint256).max) return;
        if (currentAllowance < value) {
            revert ERC20InsufficientAllowance(spender, currentAllowance, value);
        }
        unchecked {
            _allowances[owner][spender] = currentAllowance - value;
        }
    }

    function _checkTokenAdmin() private view {
        if (msg.sender != tokenAdmin) revert UnauthorizedTokenAdmin(msg.sender);
    }

    function _ipfs(bytes32 digest) private pure returns (string memory) {
        if (digest == bytes32(0)) return "";
        bytes memory encoded = new bytes(64);
        for (uint256 i; i < 32; ++i) {
            uint8 value = uint8(digest[i]);
            encoded[i * 2] = HEX_DIGITS[value >> 4];
            encoded[i * 2 + 1] = HEX_DIGITS[value & 0x0f];
        }
        return string.concat(IPFS_PREFIX, string(encoded));
    }
}
