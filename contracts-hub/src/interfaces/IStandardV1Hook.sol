// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IStandardV1Hook {
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
    error InvalidFeeLocker();
    error InvalidInitialPrice();
    error InvalidToken();
    error InvalidTokenOrder();
    error OnlyModule();
    error OnlyBeneficiaryController();
    error PoolAlreadyInitialized();
    error PoolAlreadyRegistered();
    error PoolNotInitialized();
    error PoolNotRegistered();
    error UnauthorizedUnlock();
    error UnexpectedLockerReceipt(uint256 expected, uint256 received);

    event PoolRegistered(
        PoolId indexed poolId,
        address indexed token,
        address indexed weth,
        address beneficiaryController
    );
    event PoolInitialized(PoolId indexed poolId, uint64 initializedAt, uint24 lpFee);
    event BeneficiaryUpdated(
        PoolId indexed poolId,
        address indexed token,
        address indexed previousBeneficiary,
        address newBeneficiary
    );
    event WethHookFeeAccrued(
        PoolId indexed poolId,
        address indexed beneficiary,
        uint256 grossWethBasis,
        uint256 totalRate,
        uint256 totalFee,
        uint256 permanentFee,
        uint256 temporaryFee,
        uint256 beneficiaryCredit,
        uint256 protocolCredit,
        uint256 roundingDust,
        uint256 cumulativeAmount
    );
    event PoolFeesFlushed(
        PoolId indexed poolId,
        address indexed beneficiary,
        address indexed caller,
        uint256 protocolPaid,
        uint256 beneficiaryStored
    );

    function registerPool(address token, address beneficiary, address beneficiaryController)
        external
        returns (PoolKey memory key);
    function updateBeneficiary(address token, address newBeneficiary) external;
    function flushPoolFees(PoolId poolId, address beneficiary)
        external
        returns (uint256 protocolPaid, uint256 beneficiaryStored);
    function totalWethFeesAccrued(PoolId poolId) external view returns (uint256);
    function pendingProtocolWeth(PoolId poolId) external view returns (uint256);
    function pendingBeneficiaryWeth(PoolId poolId, address beneficiary)
        external
        view
        returns (uint256);
    function pendingTotalWeth(PoolId poolId) external view returns (uint256);
    function getPoolConfig(PoolId poolId) external view returns (PoolConfig memory);
    function poolIdForToken(address token) external view returns (PoolId);
}
