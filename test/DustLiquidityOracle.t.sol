// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Observations must be backed by NUKE actually for sale, so dust liquidity in an empty
/// region cannot move the hourly reference or stand in for the executable spot price.
contract DustLiquidityOracleTest is HookFixture {
    using StateLibrary for IPoolManager;

    function setUp() public virtual {
        _local(false);
    }

    /// @dev Launch shape: one NUKE-only position above the opening price, nothing on the IMD side.
    function _launchShape() internal {
        actor.liquidity(key, ModifyLiquidityParams(-12000, 12000, -int256(uint256(LIQUIDITY)), bytes32(0)));
        int24 lower = hook.tokenIs0() ? int24(0) : int24(-12000);
        int24 upper = hook.tokenIs0() ? int24(12000) : int24(0);
        actor.liquidity(key, ModifyLiquidityParams(lower, upper, int256(uint256(LIQUIDITY)), bytes32(0)));
        IERC20(IMD).transfer(address(hook), 1000 ether);
    }

    /// @dev A 1 wei IMD position at the extreme usable ticks, then a 1 wei sell that parks spot in it.
    function _dustPush(int128 dustLiquidity) internal returns (int24 parkedTick) {
        int24 lower = hook.tokenIs0() ? int24(-887220) : int24(887160);
        int24 upper = hook.tokenIs0() ? int24(-887160) : int24(887220);
        BalanceDelta added = actor.liquidity(key, ModifyLiquidityParams(lower, upper, dustLiquidity, bytes32(0)));
        assertEq(hook.tokenIs0() ? added.amount0() : added.amount1(), 0, "dust position should hold no NUKE");
        assertGe(hook.tokenIs0() ? -added.amount1() : -added.amount0(), 1, "dust position should cost about 1 wei");
        uint160 limit = TickMath.getSqrtPriceAtTick(hook.tokenIs0() ? int24(-887190) : int24(887190));
        uint256 accruedBefore = hook.pending() + hook.pendingBurn();
        int24 observedBefore = hook.observedTick();
        BalanceDelta sold = actor.swap(key, SwapParams(hook.tokenIs0(), -1, limit));
        assertEq(hook.tokenIs0() ? sold.amount1() : sold.amount0(), 0, "the push must fill nothing on the IMD side");
        assertEq(hook.pending() + hook.pendingBurn(), accruedBefore, "the push must pay no fee");
        assertEq(hook.observedTick(), observedBefore, "the push changed the observed tick");
        (, parkedTick,,) = manager.getSlot0(key.toId());
        assertEq(manager.getLiquidity(key.toId()), uint128(uint256(int256(dustLiquidity))));
        (, bool found) = hook.askPrice();
        assertFalse(found, "a dust position with nothing behind it reported an executable price");
    }

    function _realBuy() internal {
        actor.swap(
            key,
            SwapParams(
                !hook.tokenIs0(),
                -int256(100 ether),
                hook.tokenIs0() ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1
            )
        );
        assertEq(manager.getLiquidity(key.toId()), LIQUIDITY, "buy did not land in the launch position");
    }

    /// @dev Reported scenario: one block parked at tick -887161 / 887160 via a 1e18-liquidity dust position.
    function test_dustLiquidityTickPushDoesNotBlockBuyback() public {
        _launchShape();
        vm.warp(start + 100);
        int24 parked = _dustPush(1e18);
        assertEq(parked, hook.tokenIs0() ? int24(-887161) : int24(887160));
        vm.warp(start + 112);
        _realBuy();
        int24 realTick = hook.observedTick();
        vm.warp(start + 3600);
        // Only the initial tick (112 s) and the real observed tick (3488 s) enter the window.
        int256 integral = int256(realTick) * 3488;
        int256 mean = integral / 3600;
        if (integral < 0 && integral % 3600 != 0) --mean;
        assertEq(hook.referencePrice(), TickMath.getSqrtPriceAtTick(int24(mean)), "dust tick entered the reference");
        uint256 deadBefore = nuke.balanceOf(DEAD);
        vm.prank(makeAddr("permissionless keeper"));
        (uint256 spent, uint256 burned) = hook.executeBatch();
        assertEq(spent, 250 ether, "buyback blocked by a free dust-liquidity tick push");
        assertGt(burned, 0);
        assertEq(nuke.balanceOf(DEAD) - deadBefore, burned);
        assertEq(hook.pending(), 750 ether);
        assertEq(hook.lastBatch(), start + 3600);
        _settled();
    }

    function test_controlWithoutPushGivesSameReference() public {
        _launchShape();
        vm.warp(start + 112);
        _realBuy();
        int24 realTick = hook.observedTick();
        vm.warp(start + 3600);
        int256 integral = int256(realTick) * 3488;
        int256 mean = integral / 3600;
        if (integral < 0 && integral % 3600 != 0) --mean;
        assertEq(hook.referencePrice(), TickMath.getSqrtPriceAtTick(int24(mean)));
        (uint256 spent, uint256 burned) = hook.executeBatch();
        assertEq(spent, 250 ether);
        assertGt(burned, 0);
    }

    /// @dev Reported scenario, second half: liquidity 1 plus one NUKE sold into it used to tighten the
    /// limit to the dust spot, buy a few wei and consume the cooldown. Now the dust is not an
    /// executable price: the batch crosses it and fills the whole budget from real liquidity.
    function test_dustAskDoesNotCapLimitOrConsumeCooldownCheaply() public {
        _launchShape();
        vm.warp(start + 3600);
        _dustPush(1);
        uint160 limitBefore = hook.batchPriceLimit();
        actor.swap(
            key,
            SwapParams(
                hook.tokenIs0(),
                -int256(1 ether),
                hook.tokenIs0() ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            )
        );
        assertEq(hook.batchPriceLimit(), limitBefore, "dust spot tightened the batch limit");
        (uint256 spent, uint256 burned) = hook.executeBatch();
        assertEq(spent, 250 ether, "batch stopped inside the dust position");
        assertGt(burned, 200 ether);
        assertEq(manager.getLiquidity(key.toId()), LIQUIDITY, "batch did not reach the launch position");
        assertEq(hook.lastBatch(), start + 3600);
        _settled();
    }

    /// @dev A cheaper ask that really offers the observation depth is observed, and the batch buys it.
    function test_backedDiscountedAskIsObservedAndBoughtFirst() public {
        _launchShape();
        uint256 depth = hook.observationDepth();
        int24 lower = hook.tokenIs0() ? int24(-660) : int24(600);
        int24 upper = hook.tokenIs0() ? int24(-600) : int24(660);
        vm.warp(start + 1);
        actor.liquidity(key, ModifyLiquidityParams(lower, upper, 2e24, bytes32(0)));
        uint160 parkLimit = TickMath.getSqrtPriceAtTick(hook.tokenIs0() ? int24(-650) : int24(650));
        BalanceDelta sold = actor.swap(key, SwapParams(hook.tokenIs0(), -int256(6000 ether), parkLimit));
        uint256 offered = uint256(-int256(hook.tokenIs0() ? sold.amount0() : sold.amount1()));
        assertGt(offered, 2 * depth, "setup must offer more than the observation depth");
        (uint160 ask, bool found) = hook.askPrice();
        assertTrue(found, "a backed ask was not observed");
        int24 askTick = TickMath.getTickAtSqrtPrice(ask);
        assertTrue(askTick >= lower && askTick <= upper, "ask observed outside the discounted position");
        vm.warp(start + 3600);
        uint160 ref = hook.referencePrice();
        if (hook.tokenIs0()) assertLt(ref, Q96);
        else assertGt(ref, Q96);
        uint256 deadBefore = nuke.balanceOf(DEAD);
        uint256 budget = hook.pending() / 4;
        (uint256 spent, uint256 burned) = hook.executeBatch();
        assertEq(spent, budget);
        // At the ~6% discount the batch buys more NUKE per IMD than the 0.987 a control batch gets at par.
        assertGt(burned, spent);
        assertEq(nuke.balanceOf(DEAD) - deadBefore, burned);
        _settled();
    }

    /// @dev One observation may move at most BAND_TICKS below the completed hour's mean; the next hour follows.
    function test_observationBandLimitsHourlyDrop() public {
        vm.warp(start + 1);
        uint256 sold = 250_000 ether;
        actor.swap(
            key,
            SwapParams(
                hook.tokenIs0(),
                -int256(sold),
                hook.tokenIs0() ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            )
        );
        int24 trueTick = _observedTick();
        int24 band = hook.BAND_TICKS();
        // The sale moved the price roughly 4350 ticks: more than one band, less than two.
        if (hook.tokenIs0()) assertLt(trueTick, -band, "setup must drop beyond the band");
        else assertGt(trueTick, band, "setup must rise beyond the band");
        int24 clamped = hook.tokenIs0() ? -band : band;
        assertEq(hook.observedTick(), clamped, "first observation was not clamped to the band");
        vm.warp(start + 3600);
        int256 integral = int256(clamped) * 3599;
        int256 mean = integral / 3600;
        if (integral < 0 && integral % 3600 != 0) --mean;
        assertEq(hook.referencePrice(), TickMath.getSqrtPriceAtTick(int24(mean)), "band did not clamp");
        // Each later window may move another band below its predecessor's mean, so the oracle
        // follows a genuine drop at BAND_TICKS per hour and reaches the true tick in two more.
        vm.warp(start + 3601);
        _swap(true, true, 1 ether, false);
        int24 secondClamp = hook.tokenIs0() ? int24(mean) - band : int24(mean) + band;
        assertEq(hook.observedTick(), secondClamp, "second observation was not clamped to the band");
        vm.warp(start + 7200);
        integral = int256(clamped) * 1 + int256(secondClamp) * 3599;
        mean = integral / 3600;
        if (integral < 0 && integral % 3600 != 0) --mean;
        assertEq(hook.referencePrice(), TickMath.getSqrtPriceAtTick(int24(mean)), "second window did not follow");
        vm.warp(start + 7201);
        _swap(true, true, 1 ether, false);
        int24 adopted = hook.observedTick();
        assertApproxEqAbs(int256(adopted), int256(trueTick), 3, "true tick not reached once inside the band");
        if (hook.tokenIs0()) assertGt(adopted, int24(mean) - band);
        else assertLt(adopted, int24(mean) + band);
    }

    /// @dev A move within the band is tracked exactly (control for the clamp).
    function test_observationWithinBandIsTrackedExactly() public {
        vm.warp(start + 1);
        actor.swap(
            key,
            SwapParams(
                hook.tokenIs0(),
                -int256(50_000 ether),
                hook.tokenIs0() ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            )
        );
        int24 trueTick = hook.observedTick();
        // The callback observed the depth before the 50k NUKE sold in settled; the resting view is close.
        assertApproxEqAbs(int256(trueTick), int256(_observedTick()), 10);
        int24 band = hook.BAND_TICKS();
        if (hook.tokenIs0()) assertGt(trueTick, -band);
        else assertLt(trueTick, band);
        vm.warp(start + 3600);
        int256 integral = int256(trueTick) * 3599;
        int256 mean = integral / 3600;
        if (integral < 0 && integral % 3600 != 0) --mean;
        assertEq(hook.referencePrice(), TickMath.getSqrtPriceAtTick(int24(mean)));
    }
}

contract DustLiquidityOracleReverseOrderTest is DustLiquidityOracleTest {
    function setUp() public override {
        _local(true);
    }
}
