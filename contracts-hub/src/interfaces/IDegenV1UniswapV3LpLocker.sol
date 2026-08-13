// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IDegenV1UniswapV3LpLocker {
    struct PositionConfig {
        address pool;
        uint256[7] positionIds;
        address beneficiary;
        address feeAdmin;
        uint256 poolSupply;
        uint256 tokenPrincipal;
        uint256 lockedTokenDust;
        bool placed;
    }

    error OnlyModule();
    error InvalidAddress();
    error InvalidBuybackVault();
    error InvalidBeneficiary();
    error InvalidFeeAdmin();
    error InvalidPoolSupply();
    error PositionAlreadyPlaced();
    error InvalidPool();
    error UnsupportedTokenBehavior();
    error InvalidPositionReceipt();
    error PrincipalAccountingMismatch();
    error PositionNotPlaced();
    error OnlyFeeAdmin();
    error FeeAccountingMismatch();

    event LiquidityPlaced(
        address indexed token,
        address indexed pool,
        uint256 indexed firstPositionId,
        address beneficiary,
        address feeAdmin,
        uint256 poolSupply,
        uint256 tokenPrincipal,
        uint256 lockedTokenDust
    );

    event FeesDelivered(
        address indexed token,
        address indexed beneficiary,
        address indexed caller,
        uint256 tokenFeesCollected,
        uint256 tokenToReserve,
        uint256 tokenToBurn,
        uint256 wethFeesCollected,
        uint256 wethToCreator,
        uint256 wethToTreasury,
        uint256 wethToBuyback
    );

    event BeneficiaryUpdated(
        address indexed token, address indexed oldBeneficiary, address indexed newBeneficiary
    );

    event FeeAdminUpdated(
        address indexed token, address indexed oldFeeAdmin, address indexed newFeeAdmin
    );

    function positionForToken(address token) external view returns (PositionConfig memory);

    function placeLiquidity(
        address pool,
        address token,
        uint256 poolSupply,
        address beneficiary,
        address feeAdmin
    ) external returns (uint256 firstPositionId);

    function claimFees(address token) external returns (uint256 beneficiaryWethDelivered);

    function updateBeneficiary(address token, address newBeneficiary) external;

    function updateFeeAdmin(address token, address newFeeAdmin) external;
}
