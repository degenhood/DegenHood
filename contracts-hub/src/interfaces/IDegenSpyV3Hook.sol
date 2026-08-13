// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IDegenSpyV3Hook {
    struct PoolConfig {
        address token;
        address beneficiary;
        address beneficiaryController;
        bool registered;
        bool initialized;
        uint64 initializedAt;
    }

    error FeeAmountOverflow(uint256 amount);
    error InvalidAddress();
    error InvalidBeneficiary();
    error InvalidBeneficiaryController();
    error InvalidBuybackVault();
    error InvalidFeeLocker();
    error InvalidInitialPrice();
    error InvalidToken();
    error InvalidTokenOrder();
    error OnlyModule();
    error OnlyBeneficiaryController();
    error PartialFillUnsupported(uint256 expectedQuote, uint256 realizedQuote);
    error PoolAlreadyInitialized();
    error PoolAlreadyRegistered();
    error PoolNotInitialized();
    error PoolNotRegistered();
    error UnauthorizedUnlock();
    error UnexpectedLockerReceipt(uint256 expected, uint256 received);

    event PoolRegistered(
        PoolId indexed poolId,
        address indexed token,
        address indexed spy,
        address beneficiaryController
    );
    event PoolInitialized(PoolId indexed poolId, uint64 initializedAt, uint24 lpFee);
    event BeneficiaryUpdated(
        PoolId indexed poolId,
        address indexed token,
        address indexed previousBeneficiary,
        address newBeneficiary
    );
    event RawSpyHookFeeAccrued(
        PoolId indexed poolId,
        address indexed beneficiary,
        uint256 grossRawSpyBasis,
        uint256 totalRate,
        uint256 totalFee,
        uint256 permanentFee,
        uint256 temporaryFee,
        uint256 beneficiaryTemporary,
        uint256 treasuryCredit,
        uint256 buybackCredit,
        uint256 roundingDust,
        uint256 cumulativeAmount
    );
    event ProtocolRawSpySwept(
        PoolId indexed triggeringPoolId,
        address indexed caller,
        uint256 treasuryAmount,
        uint256 buybackAmount,
        uint256 cumulativeTreasurySwept,
        uint256 cumulativeBuybackSwept,
        bool automatic
    );
    event PoolFeesFlushed(
        PoolId indexed poolId,
        address indexed beneficiary,
        address indexed caller,
        uint256 treasuryPaid,
        uint256 buybackPaid,
        uint256 beneficiaryStored
    );

    function registerPool(address token, address beneficiary, address beneficiaryController)
        external
        returns (PoolKey memory);
    function updateBeneficiary(address token, address newBeneficiary) external;
    function flushProtocolFees() external returns (uint256 treasuryPaid, uint256 buybackPaid);
    function flushPoolFees(PoolId poolId, address beneficiary)
        external
        returns (uint256 treasuryPaid, uint256 buybackPaid, uint256 beneficiaryStored);
    function getPoolConfig(PoolId poolId) external view returns (PoolConfig memory);
    function poolIdForToken(address token) external view returns (PoolId);
}
