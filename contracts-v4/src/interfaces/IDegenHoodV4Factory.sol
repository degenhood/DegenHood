// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IDegenHoodV4Factory {
    struct LaunchRequest {
        string name;
        string symbol;
        string contractURI;
        string imageURI;
        address launcher;
        address tokenAdmin;
        address feeAdmin;
        address beneficiary;
        uint256 templateId;
        bytes32 userSalt;
    }

    struct Template {
        address hook;
        address lpLocker;
        address feeLocker;
        bytes32 hookCodeHash;
        bytes32 lockerCodeHash;
        bool approved;
        bool deprecated;
    }

    struct LaunchRecord {
        uint256 launchId;
        address token;
        address launcher;
        address tokenAdmin;
        address feeAdmin;
        address beneficiary;
        address operatingTreasury;
        address tokenReserve;
        uint256 templateId;
        address hook;
        address lpLocker;
        address feeLocker;
        PoolKey poolKey;
        PoolId poolId;
        uint256 positionId;
        uint256 supply;
        uint24 lpFee;
        uint256 permanentHookRate;
        uint256 maximumTemporaryHookRate;
        uint64 launchFeeDuration;
        int24 initialTick;
        int24 upperTick;
        int24 tickSpacing;
        bytes32 metadataHash;
        bytes32 factoryVersion;
        bytes32 hookCodeHash;
        bytes32 lockerCodeHash;
    }

    error InvalidAddress();
    error InvalidLauncher();
    error InvalidTokenAdmin();
    error InvalidFeeAdmin();
    error InvalidBeneficiary();
    error UnauthorizedLauncher();
    error EmptyNameOrSymbol();
    error FactoryDeprecated();
    error InvalidTemplate();
    error TemplateAlreadyExists();
    error TemplateNotApproved();
    error TemplateDeprecated();
    error TemplateCodeChanged();
    error LaunchAlreadyUsed();
    error TokenMustSortBeforeWeth(address token, address weth);
    error VanitySuffixMismatch(address token);
    error UnexpectedPoolKey();
    error UnexpectedPosition();

    event TemplateApproved(
        uint256 indexed templateId,
        address indexed hook,
        address indexed lpLocker,
        address feeLocker,
        bytes32 hookCodeHash,
        bytes32 lockerCodeHash
    );
    event TemplateRetired(uint256 indexed templateId);
    event FactoryPermanentlyDeprecated();
    event TokenLaunched(
        uint256 indexed launchId,
        address indexed token,
        address indexed launcher,
        address tokenAdmin,
        address feeAdmin,
        address beneficiary,
        address operatingTreasury,
        address tokenReserve,
        uint256 templateId,
        address hook,
        address lpLocker,
        address feeLocker,
        bytes32 poolId,
        uint256 positionId,
        uint256 supply,
        uint24 lpFee,
        uint256 permanentHookRate,
        uint256 maximumTemporaryHookRate,
        uint64 launchFeeDuration,
        int24 initialTick,
        int24 upperTick,
        int24 tickSpacing,
        bytes32 metadataHash,
        bytes32 factoryVersion,
        bytes32 hookCodeHash,
        bytes32 lockerCodeHash
    );

    function approveTemplate(uint256 templateId, address hook, address lpLocker) external;
    function deprecateTemplate(uint256 templateId) external;
    function deprecateFactory() external;
    function launch(LaunchRequest calldata request) external returns (LaunchRecord memory record);
    function predictTokenAddress(LaunchRequest calldata request) external view returns (address);
    function launchCommitment(LaunchRequest calldata request) external pure returns (bytes32);
    function template(uint256 templateId) external view returns (Template memory);
    function launchRecord(address token) external view returns (LaunchRecord memory);
}
