// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DegenHoodFeeLocker} from "../src/DegenHoodFeeLocker.sol";
import {DegenHoodV4HookV2} from "../src/DegenHoodV4HookV2.sol";
import {DegenHoodV4LpLocker} from "../src/DegenHoodV4LpLocker.sol";
import {IDegenHoodV4Factory} from "../src/interfaces/IDegenHoodV4Factory.sol";
import {DegenV4LaunchFixture} from "./helpers/DegenV4LaunchFixture.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

contract DegenHoodV4HandlerV2 is Test {
    uint160 private constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 private constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    IPoolManager public immutable manager;
    PoolSwapTest public immutable swapRouter;
    DegenHoodV4HookV2 public immutable hook;
    DegenHoodV4LpLocker public immutable lpLocker;
    DegenHoodFeeLocker public immutable feeLocker;
    IERC20 public immutable weth;

    PoolKey[2] private _keys;
    PoolId[2] private _poolIds;
    IERC20[2] private _tokens;
    address[2] private _beneficiaries;

    uint256 public unexpectedFailures;
    uint256 public creatorIsolationViolations;
    uint256 public lockerMutationViolations;
    uint256[2] public successfulBuys;
    uint256[2] public successfulSells;

    constructor(
        IPoolManager manager_,
        PoolSwapTest swapRouter_,
        DegenHoodV4HookV2 hook_,
        DegenHoodV4LpLocker lpLocker_,
        DegenHoodFeeLocker feeLocker_,
        address weth_,
        PoolKey[2] memory keys_,
        PoolId[2] memory poolIds_,
        address[2] memory tokens_,
        address[2] memory beneficiaries_
    ) {
        manager = manager_;
        swapRouter = swapRouter_;
        hook = hook_;
        lpLocker = lpLocker_;
        feeLocker = feeLocker_;
        weth = IERC20(weth_);
        _keys = keys_;
        _poolIds = poolIds_;
        _beneficiaries = beneficiaries_;
        for (uint256 i; i < 2; ++i) {
            _tokens[i] = IERC20(tokens_[i]);
            _tokens[i].approve(address(swapRouter_), type(uint256).max);
        }
        IERC20(weth_).approve(address(swapRouter_), type(uint256).max);
    }

    function buy(uint8 rawPool, uint96 rawAmount) external {
        uint256 index = rawPool % 2;
        uint256 amount = bound(uint256(rawAmount), 1e6, 1e11);
        uint256 liabilityBefore = feeLocker.totalLiability();
        uint256[2] memory creatorBefore = _creatorPending();
        try swapRouter.swap(
            _keys[index],
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) returns (
            BalanceDelta
        ) {
            successfulBuys[index]++;
            _checkSwapIsolation(index, liabilityBefore, creatorBefore);
        } catch {
            unexpectedFailures++;
        }
    }

    function sell(uint8 rawPool, uint96 rawAmount) external {
        uint256 index = rawPool % 2;
        uint256 balance = _tokens[index].balanceOf(address(this));
        if (balance == 0) return;
        uint256 amount = bound(uint256(rawAmount), 1, _min(balance, 1e12));
        uint256 liabilityBefore = feeLocker.totalLiability();
        uint256[2] memory creatorBefore = _creatorPending();
        try swapRouter.swap(
            _keys[index],
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) returns (
            BalanceDelta
        ) {
            successfulSells[index]++;
            _checkSwapIsolation(index, liabilityBefore, creatorBefore);
        } catch {
            unexpectedFailures++;
        }
    }

    function flushProtocol() external {
        uint256 liabilityBefore = feeLocker.totalLiability();
        uint256[2] memory creatorBefore = _creatorPending();
        try hook.flushProtocolFees() {}
        catch {
            unexpectedFailures++;
        }
        if (feeLocker.totalLiability() != liabilityBefore) lockerMutationViolations++;
        uint256[2] memory creatorAfter = _creatorPending();
        if (creatorAfter[0] != creatorBefore[0] || creatorAfter[1] != creatorBefore[1]) {
            creatorIsolationViolations++;
        }
    }

    function flushCreator(uint8 rawPool) external {
        uint256 index = rawPool % 2;
        uint256 protocolBefore = hook.pendingProtocolWeth();
        uint256 otherBefore = hook.pendingBeneficiaryTotalWeth(_poolIds[index == 0 ? 1 : 0]);
        try hook.flushPoolFees(_poolIds[index], _beneficiaries[index]) {}
        catch {
            unexpectedFailures++;
        }
        if (hook.pendingProtocolWeth() != protocolBefore) creatorIsolationViolations++;
        if (hook.pendingBeneficiaryTotalWeth(_poolIds[index == 0 ? 1 : 0]) != otherBefore) {
            creatorIsolationViolations++;
        }
    }

    function collectLp(uint8 rawPool) external {
        uint256 index = rawPool % 2;
        uint256 protocolBefore = hook.pendingProtocolWeth();
        uint256[2] memory creatorBefore = _creatorPending();
        try lpLocker.collectRewards(address(_tokens[index])) {}
        catch {
            unexpectedFailures++;
        }
        if (hook.pendingProtocolWeth() != protocolBefore) creatorIsolationViolations++;
        uint256[2] memory creatorAfter = _creatorPending();
        if (creatorAfter[0] != creatorBefore[0] || creatorAfter[1] != creatorBefore[1]) {
            creatorIsolationViolations++;
        }
    }

    function claim(uint8 rawPool) external {
        try feeLocker.claimFor(_beneficiaries[rawPool % 2]) {}
        catch {
            unexpectedFailures++;
        }
    }

    function moveTime(uint32 rawDelta) external {
        vm.warp(block.timestamp + uint256(rawDelta % 121));
    }

    function _checkSwapIsolation(
        uint256 activeIndex,
        uint256 liabilityBefore,
        uint256[2] memory creatorBefore
    ) private {
        if (feeLocker.totalLiability() != liabilityBefore) {
            lockerMutationViolations++;
        }
        uint256[2] memory creatorAfter = _creatorPending();
        uint256 other = activeIndex == 0 ? 1 : 0;
        if (creatorAfter[other] != creatorBefore[other]) creatorIsolationViolations++;
        if (creatorAfter[activeIndex] < creatorBefore[activeIndex]) {
            creatorIsolationViolations++;
        }
    }

    function _creatorPending() private view returns (uint256[2] memory pending) {
        pending[0] = hook.pendingBeneficiaryTotalWeth(_poolIds[0]);
        pending[1] = hook.pendingBeneficiaryTotalWeth(_poolIds[1]);
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}

contract DegenHoodV4InvariantV2Test is StdInvariant, DegenV4LaunchFixture {
    uint256 private constant TEMPLATE_V2 = 2;

    DegenHoodV4HookV2 private hookV2;
    DegenHoodV4LpLocker private lpLockerV2;
    DegenHoodV4HandlerV2 private handler;

    address private treasury = makeAddr("v2InvariantTreasury");
    address private reserve = makeAddr("v2InvariantReserve");
    address private launcher = makeAddr("v2InvariantLauncher");
    address private tokenAdmin = makeAddr("v2InvariantTokenAdmin");
    address[2] private beneficiaries;
    address[2] private feeAdmins;
    IDegenHoodV4Factory.LaunchRecord[2] private launches;

    function setUp() public {
        beneficiaries = [makeAddr("v2InvariantBeneficiaryA"), makeAddr("v2InvariantBeneficiaryB")];
        feeAdmins = [makeAddr("v2InvariantFeeAdminA"), makeAddr("v2InvariantFeeAdminB")];
        _setUpLaunchSystem(treasury, reserve, address(this));
        _deployAndApproveTemplateV2();

        vm.warp(10_000);
        launches[0] = _launch("V2 Invariant A", "V2IA", 0);
        launches[1] = _launch("V2 Invariant B", "V2IB", 1);

        PoolKey[2] memory keys = [launches[0].poolKey, launches[1].poolKey];
        PoolId[2] memory poolIds = [launches[0].poolId, launches[1].poolId];
        address[2] memory tokens = [launches[0].token, launches[1].token];
        handler = new DegenHoodV4HandlerV2(
            manager,
            swapRouter,
            hookV2,
            lpLockerV2,
            launchFeeLocker,
            launchWeth,
            keys,
            poolIds,
            tokens,
            beneficiaries
        );
        assertTrue(IERC20(launchWeth).transfer(address(handler), 1e24));
        handler.buy(0, 1e11);
        handler.buy(1, 1e11);
        handler.sell(0, 1e10);
        handler.sell(1, 1e10);

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.buy.selector;
        selectors[1] = handler.sell.selector;
        selectors[2] = handler.flushProtocol.selector;
        selectors[3] = handler.flushCreator.selector;
        selectors[4] = handler.collectLp.selector;
        selectors[5] = handler.claim.selector;
        selectors[6] = handler.moveTime.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_protocolAccrualEqualsDeliveredPlusPending() public view {
        uint256 accrued = hookV2.totalProtocolWethAccrued(launches[0].poolId)
            + hookV2.totalProtocolWethAccrued(launches[1].poolId);
        assertEq(accrued, hookV2.totalProtocolWethSwept() + hookV2.pendingProtocolWeth());
        assertEq(hookV2.totalProtocolWethSwept(), IERC20(launchWeth).balanceOf(treasury));
    }

    function invariant_hookAndFeeLockerWethAreFullyBacked() public view {
        uint256 creatorPending = hookV2.pendingBeneficiaryTotalWeth(launches[0].poolId)
            + hookV2.pendingBeneficiaryTotalWeth(launches[1].poolId);
        assertEq(
            manager.balanceOf(address(hookV2), uint256(uint160(launchWeth))),
            hookV2.pendingProtocolWeth() + creatorPending
        );
        assertEq(
            IERC20(launchWeth).balanceOf(address(launchFeeLocker)), launchFeeLocker.totalLiability()
        );
        assertEq(
            launchFeeLocker.feesToClaim(beneficiaries[0])
                + launchFeeLocker.feesToClaim(beneficiaries[1]),
            launchFeeLocker.totalLiability()
        );
    }

    function invariant_protocolOperationsNeverTouchCreatorOrLaunchedTokenDestinations()
        public
        view
    {
        assertEq(handler.unexpectedFailures(), 0);
        assertEq(handler.creatorIsolationViolations(), 0);
        assertEq(handler.lockerMutationViolations(), 0);
        for (uint256 i; i < 2; ++i) {
            assertGt(handler.successfulBuys(i), 0);
            assertGt(handler.successfulSells(i), 0);
            assertEq(IERC20(launches[i].token).balanceOf(treasury), 0);
            assertEq(manager.balanceOf(address(hookV2), launches[i].poolKey.currency0.toId()), 0);
            assertGe(
                IERC20(launches[i].token).balanceOf(lpLockerV2.BURN_SINK()),
                IERC20(launches[i].token).balanceOf(reserve) * 4
            );
            assertEq(
                IERC721(address(positionManager)).ownerOf(launches[i].positionId),
                address(lpLockerV2)
            );
        }
    }

    function _deployAndApproveTemplateV2() private {
        bytes memory constructorArgs = abi.encode(
            manager, address(launchFactory), launchWeth, treasury, address(launchFeeLocker)
        );
        (address expected, bytes32 salt) = HookMiner.find(
            address(this), _hookFlags(), type(DegenHoodV4HookV2).creationCode, constructorArgs
        );
        hookV2 = new DegenHoodV4HookV2{salt: salt}(
            manager, address(launchFactory), launchWeth, treasury, address(launchFeeLocker)
        );
        assertEq(address(hookV2), expected);
        lpLockerV2 = new DegenHoodV4LpLocker(
            address(launchFactory),
            address(hookV2),
            launchWeth,
            reserve,
            address(launchFeeLocker),
            address(positionManager),
            address(permit2)
        );
        launchFeeLocker.setDepositor(address(hookV2), true);
        launchFeeLocker.setDepositor(address(lpLockerV2), true);
        launchFactory.approveTemplate(TEMPLATE_V2, address(hookV2), address(lpLockerV2));
    }

    function _launch(string memory name, string memory symbol, uint256 index)
        private
        returns (IDegenHoodV4Factory.LaunchRecord memory record)
    {
        IDegenHoodV4Factory.LaunchRequest memory request = IDegenHoodV4Factory.LaunchRequest({
            name: name,
            symbol: symbol,
            contractURI: "ipfs://v2-invariant-contract",
            imageURI: "ipfs://v2-invariant-image",
            launcher: launcher,
            tokenAdmin: tokenAdmin,
            feeAdmin: feeAdmins[index],
            beneficiary: beneficiaries[index],
            templateId: TEMPLATE_V2,
            userSalt: keccak256(abi.encode(index))
        });
        request.userSalt = _mineLaunchSalt(request);
        vm.prank(launcher);
        record = launchFactory.launch(request);
    }

    function _hookFlags() private pure returns (uint160) {
        return uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
    }
}
