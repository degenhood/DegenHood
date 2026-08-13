// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC5267} from "@openzeppelin/contracts/interfaces/IERC5267.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

interface IDegenHoodTokenV5 is IERC20Metadata, IERC20Permit, IERC5267 {
    /// @notice Raised when initialization is attempted after the implementation or clone was locked.
    error AlreadyInitialised();
    /// @notice Raised when the fixed supply would be minted to the zero address.
    error InvalidRecipient();
    /// @notice Raised when initialization or an admin transfer specifies the zero address.
    error InvalidTokenAdmin();
    /// @notice Raised when an account other than the current token admin invokes an admin action.
    /// @param caller Account that attempted the restricted action.
    error UnauthorizedTokenAdmin(address caller);
    /// @notice Raised when metadata is frozen more than once.
    error MetadataAlreadyFrozen();
    /// @notice Raised when metadata is updated after the irreversible freeze.
    error MetadataIsFrozen();
    /// @notice Raised when token administration is renounced before metadata is frozen.
    error MetadataNotFrozen();
    /// @notice Raised when a permit is submitted after its signed deadline.
    /// @param deadline Last timestamp at which the permit was valid.
    error PermitExpired(uint256 deadline);
    /// @notice Raised when a permit signature does not recover to its nonzero owner.
    error InvalidPermitSigner();
    /// @notice Raised when any immutable structural address is zero or duplicated.
    error InvalidStructuralAddress();
    /// @notice Raised when the current timestamp cannot fit both restriction endpoints in uint40.
    error RestrictionTimeOverflow();
    /// @notice Raised when a restricted transfer exceeds the current transaction cap.
    /// @param amount Transfer amount that was requested.
    /// @param maximum Maximum transfer amount allowed at the current time.
    error MaxTransactionExceeded(uint256 amount, uint256 maximum);
    /// @notice Raised when a restricted transfer would leave an ordinary wallet above its cap.
    /// @param account Recipient whose resulting balance exceeds the cap.
    /// @param balance Recipient balance that the transfer would produce.
    /// @param maximum Maximum wallet balance allowed at the current block.
    error MaxWalletExceeded(address account, uint256 balance, uint256 maximum);

    /// @notice Emitted when the token admin replaces either content-addressed metadata digest.
    /// @param contractURI Canonical IPFS URI resolved from the new contract metadata digest.
    /// @param imageURI Canonical IPFS URI resolved from the new image digest.
    event MetadataUpdated(string contractURI, string imageURI);
    /// @notice Emitted when the token admin irreversibly freezes both metadata digests.
    event MetadataFrozen();
    /// @notice Emitted when token administration is transferred to another account.
    /// @param previousAdmin Account that held token administration before the transfer.
    /// @param newAdmin Account that holds token administration after the transfer.
    event TokenAdminUpdated(address indexed previousAdmin, address indexed newAdmin);

    /// @notice Initializes one ERC-1167 clone and mints its fixed supply exactly once.
    /// @dev Slot 0 is packed as follows:
    ///      bits 0..159 tokenAdmin | bits 160..167 initialised |
    ///      bits 168..175 metadataFrozen | bits 176..215 flatEndTime |
    ///      bits 216..255 rampEndTime. The flat and ramp phases are each 60 seconds
    ///      and are measured from `block.timestamp` independently of block cadence.
    /// @param name_ Human-readable ERC-20 name.
    /// @param symbol_ ERC-20 ticker symbol.
    /// @param supplyRecipient Address receiving the complete fixed supply.
    /// @param tokenAdmin_ Initial account allowed to update and freeze metadata.
    /// @param metadataDigest_ sha2-256 digest of the contract metadata IPFS CID.
    /// @param imageDigest_ sha2-256 digest of the image IPFS CID.
    /// @param poolManager_ PoolManager singleton used as the sell settlement destination.
    /// @param positionManager_ PositionManager used to mint and settle launch liquidity.
    /// @param lpLocker_ Permanent locker that holds every launch position NFT.
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
    ) external;
    /// @notice Permanently destroys tokens held by the caller and reduces total supply.
    /// @param amount Token amount to burn.
    function burn(uint256 amount) external;
    /// @notice Permanently destroys another account's tokens using ERC-20 allowance semantics.
    /// @param account Account whose balance is burned.
    /// @param amount Token amount to burn.
    function burnFrom(address account, uint256 amount) external;
    /// @notice Replaces both content-addressed metadata digests before metadata is frozen.
    /// @param metadataDigest_ New sha2-256 contract metadata digest, or zero to unset it.
    /// @param imageDigest_ New sha2-256 image digest, or zero to unset it.
    function updateMetadata(bytes32 metadataDigest_, bytes32 imageDigest_) external;
    /// @notice Irreversibly prevents all future metadata updates.
    function freezeMetadata() external;
    /// @notice Transfers metadata administration to a nonzero account.
    /// @param newAdmin Account that will hold token administration.
    function transferTokenAdmin(address newAdmin) external;
    /// @notice Permanently removes token administration after metadata has been frozen.
    function renounceTokenAdmin() external;
    /// @notice Resolves the contract metadata digest to canonical CIDv1 base16 form.
    /// @return uri IPFS URI, or an empty string when the digest is unset.
    function contractURI() external view returns (string memory uri);
    /// @notice Resolves supported supplemental metadata by key.
    /// @param key Metadata key; `image` is the only supported value.
    /// @return uri Image IPFS URI for `image`, otherwise an empty string.
    function extraMetadata(string calldata key) external view returns (string memory uri);
    /// @notice Returns the current metadata administrator.
    /// @return admin Current admin, or zero after renunciation is introduced and completed.
    function tokenAdmin() external view returns (address admin);
    /// @notice Reports whether initialization has permanently completed.
    /// @return isInitialised True for the locked implementation and every initialized clone.
    function initialised() external view returns (bool isInitialised);
    /// @notice Reports whether both metadata digests are permanently frozen.
    /// @return isFrozen True once no future metadata update is possible.
    function metadataFrozen() external view returns (bool isFrozen);
    /// @notice Returns the raw sha2-256 contract metadata digest.
    /// @return digest Digest with the CID multihash `0x1220` prefix removed.
    function metadataDigest() external view returns (bytes32 digest);
    /// @notice Returns the raw sha2-256 image digest.
    /// @return digest Digest with the CID multihash `0x1220` prefix removed.
    function imageDigest() external view returns (bytes32 digest);
    /// @notice Returns the PoolManager singleton fixed during clone initialization.
    /// @return manager Immutable structural PoolManager address.
    function poolManager() external view returns (address manager);
    /// @notice Returns the PositionManager fixed during clone initialization.
    /// @return manager Immutable structural PositionManager address.
    function positionManager() external view returns (address manager);
    /// @notice Returns the launch module that received the fixed supply.
    /// @return module Immutable structural launch-module address.
    function launchModule() external view returns (address module);
    /// @notice Returns the permanent LP locker fixed during clone initialization.
    /// @return locker Immutable structural LP-locker address.
    function lpLocker() external view returns (address locker);
    /// @notice Returns the first timestamp of the linear cap-release phase.
    /// @return timestamp Initialization timestamp plus 60 seconds.
    function flatEndTime() external view returns (uint40 timestamp);
    /// @notice Returns the timestamp at which all transfer caps become exactly unrestricted.
    /// @return timestamp Initialization timestamp plus 120 seconds.
    function rampEndTime() external view returns (uint40 timestamp);
    /// @notice Returns the initialization timestamp from which the cap schedule is measured.
    /// @return timestamp Start timestamp reconstructed from `flatEndTime - 60 seconds`.
    function restrictionStartTime() external view returns (uint40 timestamp);
    /// @notice Returns the current wallet cap in basis points of the fixed launch supply.
    /// @return capBps 200 during the flat phase, linearly rising to 10,000 at expiry.
    function currentWalletCapBps() external view returns (uint256 capBps);
    /// @notice Returns the current transaction cap in basis points of the fixed launch supply.
    /// @return capBps 220 during the flat phase, linearly rising to 10,000 at expiry.
    function currentTxCapBps() external view returns (uint256 capBps);
    /// @notice Returns the immutable flat-phase wallet cap.
    /// @return capBps Wallet cap in basis points of fixed supply.
    function MAX_WALLET_BPS() external view returns (uint256 capBps);
    /// @notice Returns the immutable flat-phase transaction cap.
    /// @return capBps Transaction cap in basis points of fixed supply.
    function MAX_TX_BPS() external view returns (uint256 capBps);
}
