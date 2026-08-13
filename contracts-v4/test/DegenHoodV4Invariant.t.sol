// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DegenHoodFeeLocker} from "../src/DegenHoodFeeLocker.sol";
import {DegenHoodV4Hook} from "../src/DegenHoodV4Hook.sol";
import {DegenHoodV4LpLocker} from "../src/DegenHoodV4LpLocker.sol";
import {IDegenHoodV4Factory} from "../src/interfaces/IDegenHoodV4Factory.sol";
import {IDegenHoodV4Hook} from "../src/interfaces/IDegenHoodV4Hook.sol";
import {IDegenHoodV4LpLocker} from "../src/interfaces/IDegenHoodV4LpLocker.sol";
import {DegenFeeMath} from "../src/libraries/DegenFeeMath.sol";
import {DegenV4LaunchFixture} from "./helpers/DegenV4LaunchFixture.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

contract DegenHoodV4Handler is Test {
    uint160 private constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 private constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    IPoolManager public immutable manager;
    PoolSwapTest public immutable swapRouter;
    DegenHoodV4Hook public immutable hook;
    DegenHoodV4LpLocker public immutable lpLocker;
    DegenHoodFeeLocker public immutable feeLocker;
    IERC20 public immutable token;
    IERC20 public immutable weth;
    PoolId public immutable poolId;
    address public immutable treasury;
    address public immutable attacker;

    PoolKey private _poolKey;
    address[4] private _beneficiaries;
    address[3] private _feeAdmins;

    uint256 public hookBeneficiaryFlushed;
    uint256 public expectedHookProtocol;
    uint256 public expectedHookBeneficiary;
    uint256 public expectedLpBeneficiary;
    uint256 public unauthorizedSuccesses;
    uint256 public unexpectedSwapFailures;
    uint256 public unexpectedRoleUpdateFailures;
    uint256 public unexpectedOperationFailures;
    uint256 public economicOracleViolations;
    uint256 public doubleCollectionViolations;
    uint256 public doubleClaimViolations;
    uint256 public claimDestinationViolations;
    uint256 public rateIncreaseViolations;
    uint256 public lastObservedRate;
    uint256[4] public successfulSwapModes;

    constructor(
        IPoolManager manager_,
        PoolSwapTest swapRouter_,
        DegenHoodV4Hook hook_,
        DegenHoodV4LpLocker lpLocker_,
        DegenHoodFeeLocker feeLocker_,
        address token_,
        address weth_,
        PoolKey memory poolKey_,
        PoolId poolId_,
        address treasury_,
        address[4] memory beneficiaries_,
        address[3] memory feeAdmins_,
        address attacker_
    ) {
        manager = manager_;
        swapRouter = swapRouter_;
        hook = hook_;
        lpLocker = lpLocker_;
        feeLocker = feeLocker_;
        token = IERC20(token_);
        weth = IERC20(weth_);
        _poolKey = poolKey_;
        poolId = poolId_;
        treasury = treasury_;
        _beneficiaries = beneficiaries_;
        _feeAdmins = feeAdmins_;
        attacker = attacker_;
        lastObservedRate = 800_000;

        IERC20(token_).approve(address(swapRouter_), type(uint256).max);
        IERC20(weth_).approve(address(swapRouter_), type(uint256).max);
    }

    function beneficiary(uint256 index) external view returns (address) {
        return _beneficiaries[index];
    }

    function swapMode(uint8 rawMode, uint96 rawAmount) external {
        uint8 mode = rawMode % 4;
        bool zeroForOne;
        int256 amountSpecified;
        if (mode == 0) {
            zeroForOne = false;
            amountSpecified = -int256(bound(uint256(rawAmount), 1e6, 1e11));
        } else if (mode == 1) {
            zeroForOne = false;
            amountSpecified = int256(bound(uint256(rawAmount), 1e12, 1e17));
        } else if (mode == 2) {
            uint256 balance = token.balanceOf(address(this));
            if (balance == 0) {
                unexpectedSwapFailures++;
                return;
            }
            zeroForOne = true;
            amountSpecified = -int256(bound(uint256(rawAmount), 1, _min(balance, 1e12)));
        } else {
            zeroForOne = true;
            amountSpecified = int256(bound(uint256(rawAmount), 1, 1e6));
        }

        uint256 rate = _currentRate();
        uint256 accruedBefore = hook.totalWethFeesAccrued(poolId);
        try swapRouter.swap(
            _poolKey,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) returns (
            BalanceDelta delta
        ) {
            uint256 realizedFee = hook.totalWethFeesAccrued(poolId) - accruedBefore;
            uint256 grossWeth;
            if (mode == 0) {
                // Safe: mode 0 always sets a bounded negative exact-input amount.
                // forge-lint: disable-next-line(unsafe-typecast)
                grossWeth = uint256(-amountSpecified);
            } else if (mode == 1) {
                grossWeth = uint256(uint128(-delta.amount1()));
            } else if (mode == 2) {
                grossWeth = uint256(uint128(delta.amount1())) + realizedFee;
            } else {
                // Safe: mode 3 always sets a bounded positive exact-output amount.
                // forge-lint: disable-next-line(unsafe-typecast)
                grossWeth = DegenFeeMath.grossFromNet(uint256(amountSpecified), rate);
            }
            DegenFeeMath.FeeSplit memory split;
            if (mode == 0 || mode == 2) {
                split = DegenFeeMath.splitHookFee(grossWeth, rate);
            } else {
                split = DegenFeeMath.splitRealizedHookFee(grossWeth, rate, realizedFee);
            }
            if (split.totalHookFee != realizedFee) economicOracleViolations++;
            expectedHookProtocol += split.protocolCredit;
            expectedHookBeneficiary += split.beneficiaryTemporary;
            successfulSwapModes[mode]++;
        } catch {
            unexpectedSwapFailures++;
        }
        _observeRate();
    }

    function moveTime(uint32 rawDelta) external {
        vm.warp(block.timestamp + uint256(rawDelta % 121));
        _observeRate();
    }

    function collect() external {
        try lpLocker.collectRewards(address(token)) returns (uint256, uint256 wethFees) {
            expectedLpBeneficiary += wethFees;
        } catch {
            unexpectedOperationFailures++;
        }
        _observeRate();
    }

    function flush(uint8 rawIndex) external {
        uint256 pendingBefore = hook.pendingTotalWeth(poolId);
        uint256 treasuryBefore = weth.balanceOf(treasury);
        try hook.flushPoolFees(poolId, _beneficiaries[rawIndex % 4]) {}
        catch {
            unexpectedOperationFailures++;
        }
        _recordFlush(pendingBefore, treasuryBefore);
        _observeRate();
    }

    function claim(uint8 rawIndex) external {
        address recipient = _beneficiaries[rawIndex % 4];
        uint256 credit = feeLocker.feesToClaim(recipient);
        uint256 recipientBefore = weth.balanceOf(recipient);
        uint256 callerBefore = weth.balanceOf(address(this));
        try feeLocker.claimFor(recipient) returns (uint256 amount) {
            if (
                amount != credit || weth.balanceOf(recipient) != recipientBefore + credit
                    || weth.balanceOf(address(this)) != callerBefore
            ) claimDestinationViolations++;
        } catch {
            claimDestinationViolations++;
        }
        _observeRate();
    }

    function updateBeneficiary(uint8 rawIndex) external {
        address next = _beneficiaries[rawIndex % 4];
        address currentFeeAdmin = lpLocker.positionForToken(address(token)).feeAdmin;
        uint256 pendingBefore = hook.pendingTotalWeth(poolId);
        uint256 treasuryBefore = weth.balanceOf(treasury);
        uint256 deliveredBefore = _creatorDelivered();
        uint256 hookFlushedBefore = hookBeneficiaryFlushed;
        vm.prank(currentFeeAdmin);
        try lpLocker.updateBeneficiary(address(token), next) {
            IDegenHoodV4LpLocker.PositionConfig memory position =
                lpLocker.positionForToken(address(token));
            IDegenHoodV4Hook.PoolConfig memory config = hook.getPoolConfig(poolId);
            if (position.beneficiary != next || config.beneficiary != next) {
                unexpectedRoleUpdateFailures++;
            }
        } catch {
            unexpectedRoleUpdateFailures++;
        }
        _recordFlush(pendingBefore, treasuryBefore);
        uint256 deliveredIncrease = _creatorDelivered() - deliveredBefore;
        uint256 hookFlushedIncrease = hookBeneficiaryFlushed - hookFlushedBefore;
        if (deliveredIncrease < hookFlushedIncrease) {
            economicOracleViolations++;
        } else {
            expectedLpBeneficiary += deliveredIncrease - hookFlushedIncrease;
        }
        _observeRate();
    }

    function updateFeeAdmin(uint8 rawIndex) external {
        address currentFeeAdmin = lpLocker.positionForToken(address(token)).feeAdmin;
        address next = _feeAdmins[rawIndex % 3];
        vm.prank(currentFeeAdmin);
        try lpLocker.updateFeeAdmin(address(token), next) {
            if (lpLocker.positionForToken(address(token)).feeAdmin != next) {
                unexpectedRoleUpdateFailures++;
            }
        } catch {
            unexpectedRoleUpdateFailures++;
        }
        _observeRate();
    }

    function attemptUnauthorized(uint8 rawAction) external {
        vm.startPrank(attacker);
        if (rawAction % 3 == 0) {
            try lpLocker.updateBeneficiary(address(token), _beneficiaries[0]) {
                unauthorizedSuccesses++;
            } catch {}
        } else if (rawAction % 3 == 1) {
            try lpLocker.updateFeeAdmin(address(token), _feeAdmins[0]) {
                unauthorizedSuccesses++;
            } catch {}
        } else {
            try hook.updateBeneficiary(address(token), _beneficiaries[0]) {
                unauthorizedSuccesses++;
            } catch {}
        }
        vm.stopPrank();
        _observeRate();
    }

    function doubleCollect() external {
        try lpLocker.collectRewards(address(token)) returns (uint256, uint256 wethFees) {
            expectedLpBeneficiary += wethFees;
        } catch {
            unexpectedOperationFailures++;
        }
        try lpLocker.collectRewards(address(token)) returns (uint256 tokenFees, uint256 wethFees) {
            if (tokenFees != 0 || wethFees != 0) doubleCollectionViolations++;
        } catch {
            doubleCollectionViolations++;
        }
        _observeRate();
    }

    function doubleClaim(uint8 rawIndex) external {
        address recipient = _beneficiaries[rawIndex % 4];
        try feeLocker.claimFor(recipient) {}
        catch {
            unexpectedOperationFailures++;
        }
        try feeLocker.claimFor(recipient) returns (uint256 amount) {
            if (amount != 0) doubleClaimViolations++;
        } catch {
            doubleClaimViolations++;
        }
        _observeRate();
    }

    function _recordFlush(uint256 pendingBefore, uint256 treasuryBefore) private {
        uint256 pendingAfter = hook.pendingTotalWeth(poolId);
        uint256 treasuryIncrease = weth.balanceOf(treasury) - treasuryBefore;
        if (pendingAfter <= pendingBefore) {
            uint256 reduction = pendingBefore - pendingAfter;
            if (reduction >= treasuryIncrease) {
                hookBeneficiaryFlushed += reduction - treasuryIncrease;
            } else {
                economicOracleViolations++;
            }
        } else {
            economicOracleViolations++;
        }
    }

    function _observeRate() private {
        uint256 rate = _currentRate();
        if (rate > lastObservedRate) rateIncreaseViolations++;
        lastObservedRate = rate;
    }

    function _currentRate() private view returns (uint256) {
        return DegenFeeMath.totalHookRate(hook.getPoolConfig(poolId).initializedAt, block.timestamp);
    }

    function _creatorDelivered() private view returns (uint256 amount) {
        amount = feeLocker.totalLiability();
        for (uint256 i; i < 4; ++i) {
            amount += weth.balanceOf(_beneficiaries[i]);
        }
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}

contract DegenHoodV4InvariantTest is StdInvariant, DegenV4LaunchFixture {
    using StateLibrary for IPoolManager;

    address private launcher = makeAddr("invariantLauncher");
    address private tokenAdmin = makeAddr("invariantTokenAdmin");
    address private treasury = makeAddr("invariantTreasury");
    address private reserve = makeAddr("invariantReserve");
    address private attacker = makeAddr("invariantAttacker");
    address[4] private beneficiaries;
    address[3] private feeAdmins;

    IDegenHoodV4Factory.LaunchRecord private primary;
    IDegenHoodV4Factory.LaunchRecord private isolated;
    DegenHoodV4Handler private handler;
    uint64 private initializedAt;
    uint256 private primaryPositionId;
    uint256 private isolatedPositionId;
    uint256 private isolatedAccrued;
    uint256 private isolatedPendingProtocol;
    uint256 private isolatedPendingCreator;
    uint256 private isolatedPendingTotal;
    uint256 private isolatedFeeGrowth0;
    uint256 private isolatedFeeGrowth1;
    uint160 private isolatedSqrtPriceX96;
    int24 private isolatedTick;

    function setUp() public {
        beneficiaries = [
            makeAddr("beneficiaryA"),
            makeAddr("beneficiaryB"),
            makeAddr("beneficiaryC"),
            makeAddr("isolatedBeneficiary")
        ];
        feeAdmins = [makeAddr("feeAdminA"), makeAddr("feeAdminB"), makeAddr("feeAdminC")];
        _setUpLaunchSystem(treasury, reserve, address(this));
        vm.warp(10_000);

        primary = _launch("Invariant Primary", "INVA", beneficiaries[0], feeAdmins[0]);
        isolated = _launch("Invariant Isolated", "INVB", beneficiaries[3], feeAdmins[2]);
        initializedAt = launchHook.getPoolConfig(primary.poolId).initializedAt;
        primaryPositionId = launchLpLocker.positionForToken(primary.token).positionId;
        isolatedPositionId = launchLpLocker.positionForToken(isolated.token).positionId;

        swap(isolated.poolKey, false, -int256(1e11), "");
        isolatedAccrued = launchHook.totalWethFeesAccrued(isolated.poolId);
        isolatedPendingProtocol = launchHook.pendingProtocolWeth(isolated.poolId);
        isolatedPendingCreator =
            launchHook.pendingBeneficiaryWeth(isolated.poolId, beneficiaries[3]);
        isolatedPendingTotal = launchHook.pendingTotalWeth(isolated.poolId);
        (isolatedFeeGrowth0, isolatedFeeGrowth1) = manager.getFeeGrowthGlobals(isolated.poolId);
        (isolatedSqrtPriceX96, isolatedTick,,) = manager.getSlot0(isolated.poolId);
        assertGt(isolatedAccrued, 0);
        assertGt(isolatedFeeGrowth1, 0);

        handler = new DegenHoodV4Handler(
            manager,
            swapRouter,
            launchHook,
            launchLpLocker,
            launchFeeLocker,
            primary.token,
            launchWeth,
            primary.poolKey,
            primary.poolId,
            treasury,
            beneficiaries,
            feeAdmins,
            attacker
        );
        assertTrue(IERC20(launchWeth).transfer(address(handler), 1e24));
        handler.swapMode(0, 1e11);
        handler.swapMode(1, 1e14);
        handler.swapMode(2, 1e10);
        handler.swapMode(3, 1e3);

        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.swapMode.selector;
        selectors[1] = handler.moveTime.selector;
        selectors[2] = handler.collect.selector;
        selectors[3] = handler.flush.selector;
        selectors[4] = handler.claim.selector;
        selectors[5] = handler.updateBeneficiary.selector;
        selectors[6] = handler.updateFeeAdmin.selector;
        selectors[7] = handler.attemptUnauthorized.selector;
        selectors[8] = handler.doubleCollect.selector;
        selectors[9] = handler.doubleClaim.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_wethIsConservedAndClaimsAreFullyBacked() public view {
        IERC20 weth = IERC20(launchWeth);
        uint256 accounted = weth.balanceOf(address(this)) + weth.balanceOf(address(handler))
            + weth.balanceOf(address(manager)) + weth.balanceOf(address(launchFeeLocker))
            + weth.balanceOf(treasury) + weth.balanceOf(address(launchHook))
            + weth.balanceOf(address(launchLpLocker)) + weth.balanceOf(address(launchFactory))
            + weth.balanceOf(address(swapRouter)) + weth.balanceOf(address(positionManager))
            + weth.balanceOf(address(permit2)) + weth.balanceOf(reserve)
            + weth.balanceOf(launchLpLocker.BURN_SINK()) + weth.balanceOf(attacker);
        uint256 credits;
        for (uint256 i; i < 4; ++i) {
            accounted += weth.balanceOf(beneficiaries[i]);
            credits += launchFeeLocker.feesToClaim(beneficiaries[i]);
        }
        for (uint256 i; i < 3; ++i) {
            accounted += weth.balanceOf(feeAdmins[i]);
        }
        accounted += weth.balanceOf(launcher) + weth.balanceOf(tokenAdmin);

        assertEq(accounted, weth.totalSupply());
        assertEq(weth.balanceOf(address(launchFeeLocker)), launchFeeLocker.totalLiability());
        assertEq(credits, launchFeeLocker.totalLiability());
    }

    function invariant_launchTokenIsConservedAndTokenFeesStayProtocolBound() public view {
        IERC20 launchToken = IERC20(primary.token);
        uint256 accounted = launchToken.balanceOf(address(this))
            + launchToken.balanceOf(address(handler)) + launchToken.balanceOf(address(manager))
            + launchToken.balanceOf(address(launchLpLocker))
            + launchToken.balanceOf(address(launchHook))
            + launchToken.balanceOf(address(launchFeeLocker))
            + launchToken.balanceOf(address(launchFactory))
            + launchToken.balanceOf(address(swapRouter))
            + launchToken.balanceOf(address(positionManager))
            + launchToken.balanceOf(address(permit2)) + launchToken.balanceOf(reserve)
            + launchToken.balanceOf(launchLpLocker.BURN_SINK());
        assertEq(accounted, launchToken.totalSupply());
        assertGe(
            launchToken.balanceOf(launchLpLocker.BURN_SINK()), launchToken.balanceOf(reserve) * 4
        );
    }

    function invariant_hookWethAccountingIsExact() public view {
        uint256 accrued = launchHook.totalWethFeesAccrued(primary.poolId);
        uint256 pendingCreator = _pendingCreatorWeth();
        assertEq(
            accrued,
            launchHook.pendingTotalWeth(primary.poolId) + IERC20(launchWeth).balanceOf(treasury)
                + handler.hookBeneficiaryFlushed()
        );
        assertEq(
            launchHook.pendingTotalWeth(primary.poolId),
            launchHook.pendingProtocolWeth(primary.poolId) + pendingCreator
        );
        assertEq(accrued, handler.expectedHookProtocol() + handler.expectedHookBeneficiary());
        assertEq(
            launchHook.pendingProtocolWeth(primary.poolId) + IERC20(launchWeth).balanceOf(treasury),
            handler.expectedHookProtocol()
        );
        assertEq(
            pendingCreator + handler.hookBeneficiaryFlushed(), handler.expectedHookBeneficiary()
        );
        assertEq(
            pendingCreator + _deliveredCreatorWeth(),
            handler.expectedHookBeneficiary() + handler.expectedLpBeneficiary()
        );
    }

    function invariant_rolesClaimsAndRepeatedOperationsRemainSafe() public view {
        assertEq(handler.unauthorizedSuccesses(), 0);
        assertEq(handler.doubleCollectionViolations(), 0);
        assertEq(handler.doubleClaimViolations(), 0);
        assertEq(handler.claimDestinationViolations(), 0);
        assertEq(handler.rateIncreaseViolations(), 0);
        assertEq(handler.unexpectedSwapFailures(), 0);
        assertEq(handler.unexpectedRoleUpdateFailures(), 0);
        assertEq(handler.unexpectedOperationFailures(), 0);
        assertEq(handler.economicOracleViolations(), 0);
        for (uint256 i; i < 4; ++i) {
            assertGt(handler.successfulSwapModes(i), 0);
        }

        IDegenHoodV4LpLocker.PositionConfig memory position =
            launchLpLocker.positionForToken(primary.token);
        assertEq(position.beneficiary, launchHook.getPoolConfig(primary.poolId).beneficiary);
    }

    function invariant_poolConstantsScheduleAndPermanentCustodyDoNotChange() public view {
        IDegenHoodV4Hook.PoolConfig memory config = launchHook.getPoolConfig(primary.poolId);
        IDegenHoodV4LpLocker.PositionConfig memory position =
            launchLpLocker.positionForToken(primary.token);
        (uint160 sqrtPriceX96,,, uint24 lpFee) = manager.getSlot0(primary.poolId);
        assertGt(sqrtPriceX96, 0);
        assertEq(lpFee, 7000);
        assertEq(config.token, primary.token);
        assertEq(config.beneficiaryController, address(launchLpLocker));
        assertEq(config.initializedAt, initializedAt);
        assertTrue(config.registered && config.initialized);
        assertEq(Currency.unwrap(position.poolKey.currency0), primary.token);
        assertEq(Currency.unwrap(position.poolKey.currency1), launchWeth);
        assertEq(position.poolKey.fee, primary.poolKey.fee);
        assertEq(position.poolKey.tickSpacing, 200);
        assertEq(position.positionId, primaryPositionId);
        assertEq(
            IERC721(address(positionManager)).ownerOf(primaryPositionId), address(launchLpLocker)
        );

        uint256 rate = DegenFeeMath.totalHookRate(initializedAt, block.timestamp);
        assertGe(rate, 5000);
        assertLe(rate, 800_000);
    }

    function invariant_unrelatedPoolCannotBeConsumedOrReconfigured() public view {
        IDegenHoodV4Hook.PoolConfig memory config = launchHook.getPoolConfig(isolated.poolId);
        IDegenHoodV4LpLocker.PositionConfig memory position =
            launchLpLocker.positionForToken(isolated.token);
        (uint160 sqrtPriceX96, int24 tick,, uint24 lpFee) = manager.getSlot0(isolated.poolId);
        (uint256 feeGrowth0, uint256 feeGrowth1) = manager.getFeeGrowthGlobals(isolated.poolId);
        assertEq(config.beneficiary, beneficiaries[3]);
        assertEq(config.beneficiaryController, address(launchLpLocker));
        assertEq(launchHook.totalWethFeesAccrued(isolated.poolId), isolatedAccrued);
        assertEq(launchHook.pendingProtocolWeth(isolated.poolId), isolatedPendingProtocol);
        assertEq(
            launchHook.pendingBeneficiaryWeth(isolated.poolId, beneficiaries[3]),
            isolatedPendingCreator
        );
        assertEq(launchHook.pendingTotalWeth(isolated.poolId), isolatedPendingTotal);
        assertEq(position.positionId, isolatedPositionId);
        assertEq(position.beneficiary, beneficiaries[3]);
        assertEq(position.feeAdmin, feeAdmins[2]);
        assertEq(
            IERC721(address(positionManager)).ownerOf(isolatedPositionId), address(launchLpLocker)
        );
        assertEq(sqrtPriceX96, isolatedSqrtPriceX96);
        assertEq(tick, isolatedTick);
        assertEq(lpFee, 7000);
        assertEq(feeGrowth0, isolatedFeeGrowth0);
        assertEq(feeGrowth1, isolatedFeeGrowth1);
        assertEq(
            manager.balanceOf(address(launchHook), uint256(uint160(launchWeth))),
            launchHook.pendingTotalWeth(primary.poolId) + isolatedPendingTotal
        );
    }

    function _launch(
        string memory name,
        string memory symbol,
        address beneficiary_,
        address feeAdmin_
    ) private returns (IDegenHoodV4Factory.LaunchRecord memory launched) {
        IDegenHoodV4Factory.LaunchRequest memory request =
            IDegenHoodV4Factory.LaunchRequest({
                name: name,
                symbol: symbol,
                contractURI: "ipfs://invariant-contract",
                imageURI: "ipfs://invariant-image",
                launcher: launcher,
                tokenAdmin: tokenAdmin,
                feeAdmin: feeAdmin_,
                beneficiary: beneficiary_,
                templateId: 1,
                userSalt: bytes32(0)
            });
        request.userSalt = _mineLaunchSalt(request);
        vm.prank(launcher);
        launched = launchFactory.launch(request);
    }

    function _pendingCreatorWeth() private view returns (uint256 amount) {
        for (uint256 i; i < 4; ++i) {
            amount += launchHook.pendingBeneficiaryWeth(primary.poolId, beneficiaries[i]);
        }
    }

    function _deliveredCreatorWeth() private view returns (uint256 amount) {
        amount = launchFeeLocker.totalLiability();
        for (uint256 i; i < 4; ++i) {
            amount += IERC20(launchWeth).balanceOf(beneficiaries[i]);
        }
    }
}
