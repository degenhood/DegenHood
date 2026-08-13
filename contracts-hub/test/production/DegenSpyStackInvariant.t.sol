// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {IDegenSpyV3LpLocker} from "../../src/interfaces/IDegenSpyV3LpLocker.sol";
import {LaunchContext, TemplateId, Version} from "../../src/production/ProductionLaunchTypes.sol";
import {DegenSpyStackFixture} from "./DegenSpyStack.t.sol";

contract DegenSpyInvariantHandler {
    IDegenSpyV3LpLocker public immutable locker;
    address public immutable token;
    IERC721 public immutable positions;
    IERC20 public immutable quote;
    PoolSwapTest public immutable router;
    PoolKey private _key;

    constructor(
        IDegenSpyV3LpLocker locker_,
        address token_,
        IERC721 positions_,
        IERC20 quote_,
        PoolSwapTest router_,
        PoolKey memory key_
    ) {
        locker = locker_;
        token = token_;
        positions = positions_;
        quote = quote_;
        router = router_;
        _key = key_;
        IERC20(token_).approve(address(router_), type(uint256).max);
        quote_.approve(address(router_), type(uint256).max);
    }

    function claim() external {
        locker.claimFees(token);
    }

    function collect() external {
        locker.collectRewards(token);
    }

    function swapBuy(uint96 rawAmount) external {
        uint256 balance = quote.balanceOf(address(this));
        if (balance == 0) return;
        uint256 cap = balance < 1e15 ? balance : 1e15;
        uint256 amount = uint256(rawAmount) % cap + 1;
        router.swap(
            _key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function swapSell(uint96 rawAmount) external {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) return;
        uint256 cap = balance < 1e18 ? balance : 1e18;
        uint256 amount = uint256(rawAmount) % cap + 1;
        router.swap(
            _key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function rotateBeneficiary(address next) external {
        address normalized = next == address(0) || next == address(locker) ? address(1) : next;
        locker.updateBeneficiary(token, normalized);
    }

    function attemptNftEscape(uint8 index, address recipient) external returns (bool success) {
        uint256[10] memory ids = locker.positionForToken(token).positionIds;
        address to = recipient == address(0) ? address(1) : recipient;
        (success,) = address(positions)
            .call(abi.encodeCall(IERC721.transferFrom, (address(locker), to, ids[index % 10])));
    }
}

contract DegenSpyStackInvariant is StdInvariant, DegenSpyStackFixture {
    DegenSpyInvariantHandler private handler;

    function setUp() public {
        _setUpDegenSpyStack();
        module.configure(_context());
        handler = new DegenSpyInvariantHandler(
            lpLocker,
            address(token),
            IERC721(address(positionManager)),
            IERC20(spy),
            swapRouter,
            _poolKey()
        );
        IERC20(spy).transfer(address(handler), 1 ether);
        vm.prank(feeAdmin);
        lpLocker.updateFeeAdmin(address(token), address(handler));
        handler.swapBuy(1e12);
        targetContract(address(handler));
    }

    function invariantAllTenNftsRemainInPermanentCustody() public view {
        uint256[10] memory ids = lpLocker.positionForToken(address(token)).positionIds;
        for (uint256 i; i < 10; ++i) {
            assertEq(IERC721(address(positionManager)).ownerOf(ids[i]), address(lpLocker));
        }
    }

    function invariantSupplyDustAndFeeBackingRemainConservative() public view {
        IDegenSpyV3LpLocker.PositionConfig memory config = lpLocker.positionForToken(address(token));
        assertLe(token.totalSupply(), POOL_SUPPLY);
        assertEq(token.balanceOf(address(lpLocker)), config.lockedTokenDust);
        assertGe(IERC20(spy).balanceOf(address(feeLocker)), feeLocker.totalLiability());
    }

    function invariantDestinationsAndControllerNeverChange() public view {
        assertEq(lpLocker.tokenReserve(), tokenReserve);
        assertEq(lpLocker.hook(), address(hook));
        assertEq(hook.beneficiaryController(), address(lpLocker));
    }

    function _context() private view returns (LaunchContext memory) {
        return LaunchContext({
            domainId: domain,
            templateId: TemplateId.wrap(2),
            version: Version.wrap(1),
            commitment: keccak256("spy-invariant-launch"),
            token: address(token),
            launcher: address(this),
            tokenAdmin: token.tokenAdmin(),
            feeAdmin: feeAdmin,
            beneficiary: beneficiary,
            metadataHash: keccak256("metadata"),
            inputSchemaHash: EMPTY_SCHEMA_HASH,
            launchData: bytes("")
        });
    }
}
