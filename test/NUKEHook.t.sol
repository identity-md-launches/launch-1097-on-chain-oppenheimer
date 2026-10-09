// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {NUKEHook} from "../src/NUKEHook.sol";
import {NUKE} from "../src/NUKE.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";
import {MineHook} from "../script/MineHook.s.sol";

contract NUKEHookTest is HookFixture {
    using StateLibrary for IPoolManager;

    function setUp() public virtual {
        _local(false);
    }

    function test_permissionsAndDeployment() public view {
        assertEq(uint160(address(hook)) & 0x3fff, hook.FLAGS());
        Hooks.validateHookPermissions(IHooks(address(hook)), hook.getHookPermissions());
        assertTrue(hook.initialized());
        assertEq(hook.referencePrice(), Q96);
        assertEq(hook.lastBatch(), start);
        assertLe(type(NUKEHook).creationCode.length + 64, 49152);
        assertLe(address(hook).code.length, 24576);
        _noEscapeHatches(address(hook).code);
        _noEscapeHatches(address(nuke).code);
    }

    function test_exactInputBuy() public {
        _swap(true, true, 1000 ether, false);
    }

    function test_exactInputSell() public {
        _swap(false, true, 1000 ether, false);
    }

    function test_exactOutputBuy() public {
        _swap(true, false, 1000 ether, false);
    }

    function test_exactOutputSell() public {
        _swap(false, false, 1000 ether, false);
    }

    function test_partialExactInputBuy() public {
        _swap(true, true, 100_000 ether, true);
    }

    function test_partialExactInputSell() public {
        _swap(false, true, 100_000 ether, true);
    }

    function test_partialExactOutputBuy() public {
        _swap(true, false, 100_000 ether, true);
    }

    function test_partialExactOutputSell() public {
        _swap(false, false, 100_000 ether, true);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_feeMatchesFill(bool buy, bool exactInput, bool limited, uint96 requested) public {
        uint256 amount = bound(uint256(requested), limited ? 1000 ether : 1 ether, 100_000 ether);
        _swap(buy, exactInput, amount, limited);
    }

    function test_dustFeeRoundsDown() public {
        _swap(true, true, 50, false);
        assertEq(hook.pendingBurn(), 0);
        assertEq(hook.pending(), 0);
    }

    function test_largeRequestWithSmallPartialFill() public {
        _swap(true, true, uint256(type(int256).max) / 2, true);
        _swap(false, false, uint256(type(int256).max) / 2, true);
    }

    function test_callbacksRejectUntrustedCallers() public {
        SwapParams memory params = SwapParams(true, -1 ether, Q96 / 2);
        vm.expectRevert(NUKEHook.OnlyPoolManager.selector);
        hook.beforeInitialize(address(this), key, Q96);
        vm.expectRevert(NUKEHook.OnlyPoolManager.selector);
        hook.beforeSwap(address(this), key, params, "");
        vm.expectRevert(NUKEHook.OnlyPoolManager.selector);
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
        vm.expectRevert(NUKEHook.OnlyPoolManager.selector);
        hook.unlockCallback("");
        vm.prank(address(manager));
        vm.expectRevert(NUKEHook.UnexpectedUnlock.selector);
        hook.unlockCallback("");
    }

    function test_initializationRejectsOtherPoolsAndDynamicFee() public {
        NUKEHook fresh = _deployHook(address(nuke));
        PoolKey memory wrong = fresh.poolKey();
        wrong.fee = 3000;
        vm.expectRevert();
        manager.initialize(wrong, Q96);
        wrong.fee = 0x800000;
        vm.expectRevert();
        manager.initialize(wrong, Q96);
        wrong = fresh.poolKey();
        wrong.tickSpacing = 1;
        vm.expectRevert();
        manager.initialize(wrong, Q96);
        assertFalse(fresh.initialized());
        manager.initialize(fresh.poolKey(), Q96);
        assertTrue(fresh.initialized());
    }

    function test_unrepresentableRequestsUseExplicitError() public {
        int256[3] memory values = [type(int256).max, type(int256).min, -type(int256).max];
        for (uint256 i; i < values.length; i++) {
            vm.prank(address(manager));
            vm.expectRevert(NUKEHook.UnrepresentableFee.selector);
            hook.beforeSwap(address(actor), key, SwapParams(true, values[i], Q96 / 2), "");
            vm.expectRevert(); // Core wraps the hook's custom error.
            actor.swap(key, SwapParams(true, values[i], Q96 / 2));
        }
    }

    function test_beforeSwapReturnsZeroDeltaAndNoLPOverride() public {
        vm.prank(address(manager));
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) =
            hook.beforeSwap(address(actor), key, SwapParams(true, -1 ether, Q96 / 2), "");
        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(BeforeSwapDelta.unwrap(delta), 0);
        assertEq(fee, 0);
    }

    function test_permissionlessSweepBurnsClaimsAndDonations() public {
        _swap(true, true, 1000 ether, false);
        nuke.transfer(address(hook), 33 ether);
        uint256 expected = hook.pendingBurn();
        assertGt(expected, 33 ether);
        uint256 imdBefore = hook.pending();
        vm.prank(makeAddr("any keeper"));
        assertEq(hook.sweep(), expected);
        assertEq(nuke.balanceOf(DEAD), expected);
        assertEq(hook.pendingBurn(), 0);
        assertEq(hook.pending(), imdBefore);
        assertEq(nuke.totalSupply(), 1e27);
        assertEq(hook.sweep(), 0);
        _settled();
    }

    function test_batchSpendsQuarterAndBurnsWithoutHookFee() public {
        _swap(false, true, 10_000 ether, false);
        _swap(true, true, 100 ether, false);
        uint256 beforeIMD = hook.pending();
        uint256 pendingNUKE = hook.pendingBurn();
        uint256 beforeBurn = nuke.balanceOf(DEAD);
        vm.warp(start + 3600);
        vm.recordLogs();
        vm.prank(makeAddr("batch keeper"));
        (uint256 spent, uint256 bought) = hook.executeBatch();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != keccak256("FeeAccrued(address,uint256)"), "batch taxed");
        }
        assertEq(spent, beforeIMD / 4);
        assertGt(bought, 0);
        assertEq(nuke.balanceOf(DEAD) - beforeBurn, bought);
        assertEq(hook.pending(), beforeIMD - spent);
        assertEq(hook.pendingBurn(), pendingNUKE);
        assertEq(hook.lastBatch(), start + 3600);
        vm.expectRevert(NUKEHook.BatchTooSoon.selector);
        hook.executeBatch();
        vm.warp(start + 7199);
        vm.expectRevert(NUKEHook.BatchTooSoon.selector);
        hook.executeBatch();
        vm.warp(start + 7200);
        (spent, bought) = hook.executeBatch();
        assertGt(spent, 0);
        assertGt(bought, 0);
        _settled();
    }

    function test_batchPartialFillKeepsRemainderAndNextBatchWorks() public {
        IERC20(IMD).transfer(address(hook), 1_000_000 ether);
        vm.warp(start + 3600);
        uint160 limit = hook.batchPriceLimit();
        (uint256 spent, uint256 bought) = hook.executeBatch();
        assertGt(spent, 0);
        assertLt(spent, 250_000 ether);
        assertGt(bought, 0);
        assertEq(hook.pending(), 1_000_000 ether - spent);
        (uint160 spot,,,) = manager.getSlot0(key.toId());
        assertEq(spot, limit);
        vm.warp(start + 7200);
        (uint256 nextSpent, uint256 nextBought) = hook.executeBatch();
        assertGt(nextSpent, 0);
        assertGt(nextBought, 0);
        assertEq(hook.pending(), 1_000_000 ether - spent - nextSpent);
        _settled();
    }

    function test_batchCanCombineClaimsAndWalletFunds() public {
        _swap(false, true, 1000 ether, false);
        uint256 claims = hook.pending();
        IERC20(IMD).transfer(address(hook), 10_000 ether);
        vm.warp(start + 3600);
        (uint256 spent,) = hook.executeBatch();
        assertGt(spent, claims);
        assertEq(manager.balanceOf(address(hook), uint160(IMD)), 0);
        assertEq(hook.pending(), claims + 10_000 ether - spent);
        _settled();
    }

    function test_emptyBatchAndOutsideLimitDoNotConsumeCooldown() public {
        vm.warp(start + 3600);
        (uint256 spent, uint256 bought) = hook.executeBatch();
        assertEq(spent + bought, 0);
        assertEq(hook.lastBatch(), start);
        // Same-block movement has no oracle weight and cannot widen the buyback bound.
        uint160 ref = hook.referencePrice();
        _swap(true, true, 100_000 ether, false);
        assertEq(hook.referencePrice(), ref);
        IERC20(IMD).transfer(address(hook), 1000 ether);
        uint256 pendingBefore = hook.pending();
        (spent, bought) = hook.executeBatch();
        assertEq(spent + bought, 0);
        assertEq(hook.pending(), pendingBefore);
        assertEq(hook.lastBatch(), start);
        // A full hour at the new price supplies a fresh time-weighted reference.
        vm.warp(start + 7200);
        (spent, bought) = hook.executeBatch();
        assertGt(spent, 0);
        assertGt(bought, 0);
    }

    function test_noLiquidityBatchDoesNotDeadlock() public {
        actor.liquidity(key, ModifyLiquidityParams(-12000, 12000, -int256(uint256(LIQUIDITY)), bytes32(0)));
        IERC20(IMD).transfer(address(hook), 1000 ether);
        vm.warp(start + 3600);
        (uint256 spent, uint256 bought) = hook.executeBatch();
        assertEq(spent + bought, 0);
        assertEq(hook.pending(), 1000 ether);
        _settled();
    }

    function test_batchCannotRunInsideAnotherUnlock() public {
        vm.warp(start + 3600);
        (bool ok, bytes memory reason) =
            abi.decode(actor.attemptDuringUnlock(address(hook), abi.encodeCall(hook.executeBatch, ())), (bool, bytes));
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(NUKEHook.ManagerBusy.selector));
        (ok, reason) =
            abi.decode(actor.attemptDuringUnlock(address(hook), abi.encodeCall(hook.sweep, ())), (bool, bytes));
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(NUKEHook.ManagerBusy.selector));
    }

    function test_hourlyReferenceWeightsElapsedTimeAndFloorsNegativeTicks() public {
        vm.warp(start + 901);
        _swap(true, true, 10_000 ether, false);
        int24 tick = hook.observedTick();
        // The callback observed the pre-settlement depth; the resting view agrees within a tick.
        assertApproxEqAbs(int256(tick), int256(_observedTick()), 1);
        assertEq(hook.referencePrice(), Q96);
        vm.warp(start + 3600);
        int256 integral = int256(tick) * 2699;
        int256 mean = integral / 3600;
        if (integral < 0 && integral % 3600 != 0) --mean;
        assertEq(hook.referencePrice(), TickMath.getSqrtPriceAtTick(int24(mean)));
        // Arbitrarily long gaps are handled without growing loops or stale references.
        vm.warp(start + 20 * 365 days);
        assertEq(hook.referencePrice(), TickMath.getSqrtPriceAtTick(tick));
        _swap(false, true, 100 ether, false);
        assertEq(hook.referencePrice(), TickMath.getSqrtPriceAtTick(tick));
    }

    function test_priceLimitIsThreePercentInPairPerToken() public view {
        uint256 limit = hook.batchPriceLimit();
        uint256 ref = hook.referencePrice();
        uint256 ratio = hook.tokenIs0() ? limit * 1e18 / ref : ref * 1e18 / limit;
        assertApproxEqAbs(ratio * ratio / 1e18, 1.03e18, 3);
    }

    function test_askPriceIsWhereObservationDepthIsPurchasable() public {
        (uint160 spot,,,) = manager.getSlot0(key.toId());
        uint256 depth = hook.observationDepth();
        assertEq(depth, (nuke.balanceOf(address(manager)) - hook.pendingBurn()) / 400);
        assertGt(depth, 0);
        (uint160 ask, bool found) = hook.askPrice();
        assertTrue(found);
        uint160 expected = hook.tokenIs0()
            ? SqrtPriceMath.getNextSqrtPriceFromAmount0RoundingUp(spot, LIQUIDITY, depth, false)
            : SqrtPriceMath.getNextSqrtPriceFromAmount1RoundingDown(spot, LIQUIDITY, depth, false);
        assertEq(ask, expected);
        // Buying exactly that depth lands the pool on the observed price.
        actor.swap(
            key,
            SwapParams(
                !hook.tokenIs0(),
                int256(depth),
                hook.tokenIs0() ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1
            )
        );
        (uint160 landed,,,) = manager.getSlot0(key.toId());
        assertApproxEqAbs(landed, ask, 1);
        // Without liquidity nothing is purchasable, so there is no observable price.
        actor.liquidity(key, ModifyLiquidityParams(-12000, 12000, -int256(uint256(LIQUIDITY)), bytes32(0)));
        (, found) = hook.askPrice();
        assertFalse(found);
    }

    function test_offlineMinerMatchesActualCreate2Deployment() public {
        MineHook miner = new MineHook();
        (address predicted, bytes32 salt, bytes32 hash) = miner.run(manager, address(nuke), address(this), 0, 300_000);
        assertEq(predicted, address(hook));
        assertEq(hash, keccak256(abi.encodePacked(type(NUKEHook).creationCode, abi.encode(manager, address(nuke)))));
        assertEq(
            predicted, address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hash)))))
        );
        vm.expectRevert(MineHook.SaltNotFound.selector);
        miner.run(manager, address(nuke), address(this), 0, 0);
    }

    function test_cannotInitializeBeforePredictedHookHasCode() public {
        MineHook miner = new MineHook();
        (address predicted,,) = miner.run(manager, address(nuke), address(this), 300_000, 300_000);
        assertEq(predicted.code.length, 0);
        PoolKey memory predictedKey = key;
        predictedKey.hooks = IHooks(predicted);
        vm.expectRevert();
        manager.initialize(predictedKey, Q96);
    }

    function testFuzz_oracleIntegratesMultipleObservations(uint16 firstSeed, uint16 secondSeed, bool buy) public {
        uint256 first = bound(uint256(firstSeed), 1, 3598);
        uint256 second = bound(uint256(secondSeed), first + 1, 3599);
        vm.warp(start + first);
        _swap(buy, true, 10_000 ether, false);
        int24 firstTick = hook.observedTick();
        assertApproxEqAbs(int256(firstTick), int256(_observedTick()), 1);
        vm.warp(start + second);
        _swap(!buy, true, 1000 ether, false);
        int24 secondTick = hook.observedTick();
        assertApproxEqAbs(int256(secondTick), int256(_observedTick()), 1);
        int256 integral = int256(firstTick) * int256(second - first) + int256(secondTick) * int256(3600 - second);
        int256 mean = integral / 3600;
        if (integral < 0 && integral % 3600 != 0) --mean;
        vm.warp(start + 3600);
        uint160 expected = TickMath.getSqrtPriceAtTick(int24(mean));
        assertEq(hook.referencePrice(), expected);
        _swap(buy, false, 1000 ether, false);
        assertEq(hook.referencePrice(), expected, "same-block observation changed the completed window");
    }

    function test_firstBatchRequiresOneHourAndInitializedPool() public {
        vm.expectRevert(NUKEHook.BatchTooSoon.selector);
        hook.executeBatch();
        NUKEHook fresh = _deployHook(address(nuke));
        vm.expectRevert(NUKEHook.NotInitialized.selector);
        fresh.executeBatch();
    }

    function test_zeroLiquidityPartialSwapPaysNoFee() public {
        actor.liquidity(key, ModifyLiquidityParams(-12000, 12000, -int256(uint256(LIQUIDITY)), bytes32(0)));
        _swap(true, false, 1000 ether, true);
        assertEq(hook.pending() + hook.pendingBurn(), 0);
    }

    function _noEscapeHatches(bytes memory code) internal pure {
        for (uint256 i; i < code.length; i++) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            require(op != 0xff && op != 0xf4 && op != 0xf2, "forbidden runtime opcode");
        }
    }
}

/// @dev Rerun every economic and oracle test with IMD as currency0.
contract NUKEHookReverseOrderTest is NUKEHookTest {
    function setUp() public override {
        _local(true);
    }
}
