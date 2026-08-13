// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DegenHoodFeeLocker} from "./DegenHoodFeeLocker.sol";
import {DegenHoodTokenV4} from "./DegenHoodTokenV4.sol";
import {DegenHoodV4Hook} from "./DegenHoodV4Hook.sol";
import {DegenHoodV4LpLocker} from "./DegenHoodV4LpLocker.sol";
import {IDegenHoodV4Factory} from "./interfaces/IDegenHoodV4Factory.sol";
import {DegenPoolKey} from "./libraries/DegenPoolKey.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/*
HEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEENEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEOoooooOEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEOooooooooooNEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEOooooooooooooooHEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEEEEEEEEEOooooooooooooooooooNEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEEEEEEEhooooooooooooooooooooooEEEEEEEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEEEEEEoooooooooooooooooooooooooOEEEEEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEEEEOooooooooooooooooooooooooooooNEEEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEEEooooooooooooooeEnooooooooooooooOEEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEDoooooooooooeEEEEEEEEEEeoooooooooooEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEoooooooogeEEEEEEEEEEEEEEEEEEeooooooooNEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEoooooogEEEEEEEEEEEEEEEEEEEEEEEEEEooooooOEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEooooooooooOOHEEEEEEEEEEEEEEEEhOOoooooooooOEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEOooooooogEoooooooooooOOOooooooooooonEooooooooEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEDooooooooEEEooooooooooooooooooooooodEEoooooooooEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEooooooooooOEEoooooooooeEEooooooooogEEoooooooooogEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEooooooooooooOEEEEEEnEEEEEEEenEEEEEEooooooooooogEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEooooooooooooNEEEEEEEEEEEEEEEEEEOoooooooooooeEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEENooooooooooEEEEEEEEEEEEEEEEoooooooooeEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEEEEhoooooooOEEEEEEEEEEEEoooooooeEEEEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEEEEEEEEEnooooNEEEEEEEEoooogEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEnoEEEEEOenEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE
DEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE
gEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE
                                   DEGENHOOD
*/

/// @title DegenHood v4 atomic factory
/// @notice Deploys role-bound tokens into approved immutable hook/locker templates.
/// @dev Non-proxy template registry. Each launch pins immutable implementation addresses and role
///      bindings; future launch versions require separately approved templates.
contract DegenHoodV4Factory is IDegenHoodV4Factory, Ownable {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    bytes32 public constant FACTORY_VERSION = keccak256("DegenHoodV4Factory/1.0.0");
    uint256 public constant STANDARD_SUPPLY = 100_000_000_000 ether;
    uint24 public constant LP_FEE = 7000;
    uint256 public constant PERMANENT_HOOK_RATE = 5000;
    uint256 public constant MAXIMUM_TEMPORARY_HOOK_RATE = 795_000;
    uint64 public constant LAUNCH_FEE_DURATION = 30 seconds;
    int24 public constant INITIAL_TICK = -230_400;
    int24 public constant UPPER_TICK = -120_000;
    int24 public constant TICK_SPACING = 200;
    uint160 public constant VANITY_MASK = 0xFFF;
    uint160 public constant VANITY_SUFFIX = 0xDE6;

    IPoolManager public immutable POOL_MANAGER;
    address public immutable WETH;
    address public immutable OPERATING_TREASURY;
    address public immutable TOKEN_RESERVE;

    bool public factoryDeprecated;
    uint256 public launchCount;
    mapping(uint256 templateId => Template config) private _templates;
    mapping(bytes32 pairHash => bool approved) private _approvedPairs;
    mapping(address token => LaunchRecord record) private _launchRecords;
    mapping(uint256 launchId => address token) public tokenByLaunch;
    mapping(bytes32 commitment => bool used) public usedCommitments;

    constructor(
        address poolManager_,
        address weth_,
        address operatingTreasury_,
        address tokenReserve_,
        address initialOwner
    ) Ownable(initialOwner) {
        if (
            poolManager_ == address(0) || weth_ == address(0) || operatingTreasury_ == address(0)
                || tokenReserve_ == address(0) || poolManager_.code.length == 0
                || weth_.code.length == 0 || operatingTreasury_ == tokenReserve_
                || initialOwner == operatingTreasury_ || initialOwner == tokenReserve_
        ) {
            revert InvalidAddress();
        }
        POOL_MANAGER = IPoolManager(poolManager_);
        WETH = weth_;
        OPERATING_TREASURY = operatingTreasury_;
        TOKEN_RESERVE = tokenReserve_;
    }

    function template(uint256 templateId) external view returns (Template memory) {
        return _templates[templateId];
    }

    function launchRecord(address token) external view returns (LaunchRecord memory) {
        return _launchRecords[token];
    }

    function transferOwnership(address newOwner) public override onlyOwner {
        if (newOwner == OPERATING_TREASURY || newOwner == TOKEN_RESERVE) {
            revert InvalidAddress();
        }
        super.transferOwnership(newOwner);
    }

    function approveTemplate(uint256 templateId, address hook, address lpLocker)
        external
        onlyOwner
    {
        if (templateId == 0 || hook.code.length == 0 || lpLocker.code.length == 0) {
            revert InvalidTemplate();
        }
        if (_templates[templateId].approved) revert TemplateAlreadyExists();
        bytes32 pairHash = keccak256(abi.encode(hook, lpLocker));
        if (_approvedPairs[pairHash]) revert InvalidTemplate();

        DegenHoodV4Hook degenHook = DegenHoodV4Hook(hook);
        DegenHoodV4LpLocker locker = DegenHoodV4LpLocker(lpLocker);
        address hookFeeLocker = address(degenHook.feeLocker());
        DegenHoodFeeLocker ledger = DegenHoodFeeLocker(hookFeeLocker);
        if (
            degenHook.factory() != address(this)
                || address(degenHook.poolManager()) != address(POOL_MANAGER)
                || degenHook.weth() != WETH || degenHook.operatingTreasury() != OPERATING_TREASURY
                || locker.factory() != address(this) || locker.hook() != hook
                || locker.weth() != WETH || locker.tokenReserve() != TOKEN_RESERVE
                || address(locker.positionManager().poolManager()) != address(POOL_MANAGER)
                || address(locker.feeLocker()) != hookFeeLocker || !ledger.allowedDepositors(hook)
                || !ledger.allowedDepositors(lpLocker)
        ) {
            revert InvalidTemplate();
        }

        bytes32 hookCodeHash = hook.codehash;
        bytes32 lockerCodeHash = lpLocker.codehash;
        _templates[templateId] = Template({
            hook: hook,
            lpLocker: lpLocker,
            feeLocker: hookFeeLocker,
            hookCodeHash: hookCodeHash,
            lockerCodeHash: lockerCodeHash,
            approved: true,
            deprecated: false
        });
        _approvedPairs[pairHash] = true;
        emit TemplateApproved(
            templateId, hook, lpLocker, hookFeeLocker, hookCodeHash, lockerCodeHash
        );
    }

    function deprecateTemplate(uint256 templateId) external onlyOwner {
        Template storage config = _templates[templateId];
        if (!config.approved) revert TemplateNotApproved();
        config.deprecated = true;
        emit TemplateRetired(templateId);
    }

    function deprecateFactory() external onlyOwner {
        factoryDeprecated = true;
        emit FactoryPermanentlyDeprecated();
    }

    function launch(LaunchRequest calldata request) external returns (LaunchRecord memory record) {
        if (factoryDeprecated) revert FactoryDeprecated();
        _validateRoles(request);
        Template memory config = _activeTemplate(request.templateId);

        bytes32 commitment = launchCommitment(request);
        if (usedCommitments[commitment]) revert LaunchAlreadyUsed();
        address predicted = _predictTokenAddress(request, commitment);
        _validateTokenAddress(predicted);
        usedCommitments[commitment] = true;

        address token = address(
            new DegenHoodTokenV4{salt: commitment}(
                request.name,
                request.symbol,
                address(this),
                request.tokenAdmin,
                request.contractURI,
                request.imageURI
            )
        );
        if (token != predicted) revert UnexpectedPosition();

        DegenHoodV4Hook degenHook = DegenHoodV4Hook(config.hook);
        PoolKey memory poolKey = degenHook.registerPool(token, request.beneficiary, config.lpLocker);
        if (!DegenPoolKey.matches(poolKey, token, WETH, config.hook)) revert UnexpectedPoolKey();
        PoolId poolId = poolKey.toId();
        POOL_MANAGER.initialize(poolKey, TickMath.getSqrtPriceAtTick(INITIAL_TICK));

        IERC20(token).forceApprove(config.lpLocker, STANDARD_SUPPLY);
        uint256 positionId = DegenHoodV4LpLocker(config.lpLocker)
            .placeLiquidity(poolKey, token, STANDARD_SUPPLY, request.beneficiary, request.feeAdmin);
        IERC20(token).forceApprove(config.lpLocker, 0);
        if (IERC20(token).balanceOf(address(this)) != 0) revert UnexpectedPosition();

        uint256 launchId = ++launchCount;
        bytes32 metadataHash = _metadataHash(request);
        record = LaunchRecord({
            launchId: launchId,
            token: token,
            launcher: request.launcher,
            tokenAdmin: request.tokenAdmin,
            feeAdmin: request.feeAdmin,
            beneficiary: request.beneficiary,
            operatingTreasury: OPERATING_TREASURY,
            tokenReserve: TOKEN_RESERVE,
            templateId: request.templateId,
            hook: config.hook,
            lpLocker: config.lpLocker,
            feeLocker: config.feeLocker,
            poolKey: poolKey,
            poolId: poolId,
            positionId: positionId,
            supply: STANDARD_SUPPLY,
            lpFee: LP_FEE,
            permanentHookRate: PERMANENT_HOOK_RATE,
            maximumTemporaryHookRate: MAXIMUM_TEMPORARY_HOOK_RATE,
            launchFeeDuration: LAUNCH_FEE_DURATION,
            initialTick: INITIAL_TICK,
            upperTick: UPPER_TICK,
            tickSpacing: TICK_SPACING,
            metadataHash: metadataHash,
            factoryVersion: FACTORY_VERSION,
            hookCodeHash: config.hookCodeHash,
            lockerCodeHash: config.lockerCodeHash
        });
        _launchRecords[token] = record;
        tokenByLaunch[launchId] = token;
        _emitLaunch(record);
    }

    function predictTokenAddress(LaunchRequest calldata request) external view returns (address) {
        return _predictTokenAddress(request, launchCommitment(request));
    }

    function launchCommitment(LaunchRequest calldata request) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                request.userSalt,
                request.launcher,
                request.tokenAdmin,
                request.feeAdmin,
                request.beneficiary,
                request.templateId,
                _metadataHash(request)
            )
        );
    }

    function _predictTokenAddress(LaunchRequest calldata request, bytes32 commitment)
        private
        view
        returns (address)
    {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(DegenHoodTokenV4).creationCode,
                abi.encode(
                    request.name,
                    request.symbol,
                    address(this),
                    request.tokenAdmin,
                    request.contractURI,
                    request.imageURI
                )
            )
        );
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), address(this), commitment, initCodeHash)
                    )
                )
            )
        );
    }

    function _metadataHash(LaunchRequest calldata request) private pure returns (bytes32) {
        return
            keccak256(
                abi.encode(request.name, request.symbol, request.contractURI, request.imageURI)
            );
    }

    function _validateRoles(LaunchRequest calldata request) private view {
        if (request.launcher == address(0)) revert InvalidLauncher();
        if (msg.sender != request.launcher) revert UnauthorizedLauncher();
        if (request.tokenAdmin == address(0)) revert InvalidTokenAdmin();
        if (request.feeAdmin == address(0)) revert InvalidFeeAdmin();
        if (request.beneficiary == address(0)) revert InvalidBeneficiary();
        if (bytes(request.name).length == 0 || bytes(request.symbol).length == 0) {
            revert EmptyNameOrSymbol();
        }
    }

    function _activeTemplate(uint256 templateId) private view returns (Template memory config) {
        config = _templates[templateId];
        if (!config.approved) revert TemplateNotApproved();
        if (config.deprecated) revert TemplateDeprecated();
        if (
            config.hook.codehash != config.hookCodeHash
                || config.lpLocker.codehash != config.lockerCodeHash
        ) {
            revert TemplateCodeChanged();
        }
        DegenHoodFeeLocker ledger = DegenHoodFeeLocker(config.feeLocker);
        if (!ledger.allowedDepositors(config.hook) || !ledger.allowedDepositors(config.lpLocker)) {
            revert InvalidTemplate();
        }
    }

    function _validateTokenAddress(address token) private view {
        if (token >= WETH) revert TokenMustSortBeforeWeth(token, WETH);
        if (uint160(token) & VANITY_MASK != VANITY_SUFFIX) {
            revert VanitySuffixMismatch(token);
        }
    }

    function _emitLaunch(LaunchRecord memory record) private {
        emit TokenLaunched(
            record.launchId,
            record.token,
            record.launcher,
            record.tokenAdmin,
            record.feeAdmin,
            record.beneficiary,
            record.operatingTreasury,
            record.tokenReserve,
            record.templateId,
            record.hook,
            record.lpLocker,
            record.feeLocker,
            PoolId.unwrap(record.poolId),
            record.positionId,
            record.supply,
            record.lpFee,
            record.permanentHookRate,
            record.maximumTemporaryHookRate,
            record.launchFeeDuration,
            record.initialTick,
            record.upperTick,
            record.tickSpacing,
            record.metadataHash,
            record.factoryVersion,
            record.hookCodeHash,
            record.lockerCodeHash
        );
    }
}
