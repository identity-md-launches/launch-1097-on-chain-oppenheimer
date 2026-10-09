// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {HookFixture} from "./helpers/HookFixture.sol";
import {PoolActor} from "./helpers/PoolActor.sol";
import {ClaimActor} from "./helpers/ClaimActor.sol";
import {NUKEHook} from "src/NUKEHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Ghost accounts use core Swap events and actual transfers, never FeeAccrued events.
/// The oracle model never reads the hook's walk: an observation is expected where the real swap
/// engine lands after buying the observation depth (ClaimActor.probeAsk), carried when the pool
/// cannot supply it, then clamped to the band below the model's own mean of the last completed hour.
contract StatefulAccountingHandler is Test {
    using StateLibrary for IPoolManager;
    NUKEHook public immutable hook;
    PoolActor public immutable actor;
    ClaimActor public immutable claims;
    IPoolManager public immutable manager;
    uint256 public immutable start;
    uint256 public imdIn;
    uint256 public nukeIn;
    uint256 public spent;
    uint256 public bought;
    bool public seeded;
    uint256 public swaps;
    uint256 public partialFills;
    uint256 public batches;
    uint256 public cooldownRefusals;
    uint256 public subFloorFills;
    uint256 public sweeps;
    uint256 public donations;
    uint256 public liquidityChanges;
    uint256 public carriedObservations;
    uint256 public clampedObservations;
    bytes32 private constant SWAP_EVENT = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes32 private constant FEE_EVENT = keccak256("FeeAccrued(address,uint256)");

    struct Observation {
        uint256 time;
        int24 tick;
    }
    Observation[] private history;

    /// @dev Extra positions the sequence may open and close: next to spot on both sides, a wide band,
    /// and narrow ranges straddling the first two tick-bitmap word boundaries (15360 and 30720 ticks).
    /// Trades move spot at most 100 ticks per call, so every range stays within the hook's 16-step walk.
    int24[2][5] private ranges = [
        [int24(-660), int24(-600)],
        [int24(600), int24(660)],
        [int24(-30000), int24(30000)],
        [int24(15300), int24(15420)],
        [int24(30660), int24(30780)]
    ];
    uint128[5] public shaped;

    constructor(NUKEHook h, PoolActor a, ClaimActor c) {
        hook = h;
        actor = a;
        claims = c;
        manager = h.poolManager();
        start = block.timestamp;
        history.push(Observation(start, h.observedTick()));
        IERC20(h.IMD()).approve(address(a), type(uint256).max);
        IERC20(Currency.unwrap(h.token())).approve(address(a), type(uint256).max);
        IERC20(h.IMD()).approve(address(c), type(uint256).max);
        IERC20(Currency.unwrap(h.token())).approve(address(c), type(uint256).max);
    }

    function toggleLiquidity() external {
        int256 change = seeded ? -int256(1_000_000 ether) : int256(1_000_000 ether);
        actor.liquidity(hook.poolKey(), ModifyLiquidityParams(-12000, 12000, change, bytes32(0)));
        seeded = !seeded;
        ++liquidityChanges;
        _unobserved();
    }

    /// @dev Open or close one of the extra positions; the mirrored range keeps both orderings symmetric.
    function shapeLiquidity(uint8 slotSeed, bool add, uint80 liquiditySeed) external {
        uint256 slot = bound(uint256(slotSeed), 0, ranges.length - 1);
        int24 lower = ranges[slot][0];
        int24 upper = ranges[slot][1];
        if (!hook.tokenIs0()) (lower, upper) = (-upper, -lower);
        uint128 amount;
        if (add) {
            // At or above 1e18 liquidity one wei of NUKE moves the sqrt price by less than a tick, so the
            // rounding edge where a segment's floor-rounded amount equals the depth exactly (the hook
            // prices the fill inside the segment, the engine crosses to the tick) stays within one tick.
            amount = uint128(bound(uint256(liquiditySeed), 1e18, 1e22));
            shaped[slot] += amount;
        } else {
            amount = shaped[slot];
            if (amount == 0) return;
            shaped[slot] = 0;
        }
        actor.liquidity(
            hook.poolKey(),
            ModifyLiquidityParams(lower, upper, add ? int256(uint256(amount)) : -int256(uint256(amount)), bytes32(0))
        );
        ++liquidityChanges;
        _unobserved();
    }

    function donate(bool paired, bool asClaim, uint80 seed) external {
        Currency c = paired ? Currency.wrap(hook.IMD()) : hook.token();
        uint256 amount = bound(uint256(seed), 0, 1000 ether);
        if (asClaim) claims.deposit(c, amount, address(hook));
        else assertTrue(IERC20(Currency.unwrap(c)).transfer(address(hook), amount));
        if (paired) imdIn += amount;
        else nukeIn += amount;
        ++donations;
        _unobserved();
    }

    function trade(bool buy, bool exactInput, uint80 amountSeed, uint8 limitSeed) external {
        uint256 amount = bound(uint256(amountSeed), 1, 1000 ether);
        bool zeroForOne = buy != hook.tokenIs0();
        (uint160 spot, int24 tick,,) = manager.getSlot0(hook.poolId());
        // Even without liquidity, walk only a bounded number of ticks per call.
        int24 distance = int24(int256(bound(uint256(limitSeed), 1, 100)));
        uint160 limit = TickMath.getSqrtPriceAtTick(tick + (zeroForOne ? -distance : distance));
        // After crossing downward, core can report tick t-1 at the exact sqrt price of t.
        // A one-tick reverse move must still set a limit strictly above that spot price.
        if (!zeroForOne && limit <= spot) limit = TickMath.getSqrtPriceAtTick(tick + distance + 1);
        _trade(buy, exactInput, amount, limit);
    }

    /// @dev A market order large enough to move the price by whole bands. Its limit is 50000 ticks away,
    /// inside the ±100000-tick region the sequence explores, so a spot pushed through empty liquidity
    /// stays within the hook's 16-step walk of every position and the engine comparison remains exact.
    function dump(bool buy, uint88 amountSeed) external {
        bool zeroForOne = buy != hook.tokenIs0();
        (uint160 spot, int24 tick,,) = manager.getSlot0(hook.poolId());
        int24 target = zeroForOne ? tick - 50000 : tick + 50000;
        if (target < -100000) target = -100000;
        if (target > 100000) target = 100000;
        uint160 limit = TickMath.getSqrtPriceAtTick(target);
        if (zeroForOne ? limit >= spot : limit <= spot) return; // Parked at the edge of the explored region.
        _trade(buy, true, bound(uint256(amountSeed), 10_000 ether, 300_000 ether), limit);
    }

    function _trade(bool buy, bool exactInput, uint256 amount, uint160 limit) private {
        bool zeroForOne = buy != hook.tokenIs0();
        PoolKey memory key = hook.poolKey();
        uint256 burnBefore = hook.pendingBurn();
        vm.recordLogs();
        BalanceDelta net = claims.swap(
            key, SwapParams(zeroForOne, exactInput ? -int256(amount) : int256(amount), limit), false, false
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        uint256 nukeFee;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(manager) || logs[i].topics[0] != SWAP_EVENT) continue;
            found = true;
            (int128 a0, int128 a1,,,, uint24 lpFee) =
                abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            assertEq(lpFee, 12500);
            bool unspecified0 = exactInput != zeroForOne;
            uint256 fee = _abs(unspecified0 ? a0 : a1) / 100;
            assertEq(int256(net.amount0()), int256(a0) - (unspecified0 ? int256(fee) : int256(0)));
            assertEq(int256(net.amount1()), int256(a1) - (unspecified0 ? int256(0) : int256(fee)));
            if (unspecified0 == hook.tokenIs0()) {
                nukeIn += fee;
                nukeFee = fee;
            } else {
                imdIn += fee;
            }
            if (_abs(unspecified0 ? a1 : a0) < amount) ++partialFills;
        }
        assertTrue(found, "missing core swap");
        assertEq(hook.pendingBurn() - burnBefore, nukeFee);
        // The hook observed before its fee claim was minted and before the swapper settled, so the
        // depth it looked for came from the manager's pre-swap NUKE balance and its pre-swap claims.
        uint256 held = claims.tokenHeldBeforeSettlement();
        uint256 priorClaims = claims.tokenClaimsBeforeSettlement() - nukeFee;
        _expectObservation((held > priorClaims ? held - priorClaims : 0) / hook.DEPTH_DIVISOR(), false);
        ++swaps;
    }

    function advanceTime(uint16 seed) external {
        vm.warp(block.timestamp + bound(uint256(seed), 0, 10800));
        _unobserved();
    }

    function batch() external {
        uint256 available = hook.pending();
        uint256 budget = available / 4;
        uint256 previousBatch = hook.lastBatch();
        uint256 beforeBurn = hook.pendingBurn();
        uint256 beforeDead = hook.token().balanceOf(hook.DEAD());
        (uint160 beforePrice, int24 beforeTick,,) = manager.getSlot0(hook.poolId());
        uint128 beforeLiquidity = manager.getLiquidity(hook.poolId());
        // A funded attempt observes the resting state before it swaps. That observation is what a
        // later one carries when the swap leaves nothing purchasable behind, so model it first.
        int24 preObservation;
        bool preOnEdge;
        if (budget != 0) {
            (, bool filled, bool onTick) = _simulatedAsk(hook.observationDepth());
            preObservation = expectedObservation(hook.observationDepth());
            preOnEdge = filled && onTick;
        }
        vm.recordLogs();
        try hook.executeBatch() returns (uint256 used, uint256 received) {
            assertGe(block.timestamp - previousBatch, 3600);
            assertLe(used, budget, "batch exceeded budget");
            assertEq(hook.pending(), available - used);
            assertEq(hook.pendingBurn(), beforeBurn, "batch charged itself");
            assertEq(hook.token().balanceOf(hook.DEAD()) - beforeDead, received);
            if (used > 0) {
                assertGt(received, 0, "batch spent IMD without buying NUKE");
            } else {
                assertEq(received, 0);
                (uint160 afterPrice, int24 afterTick,,) = manager.getSlot0(hook.poolId());
                assertEq(afterPrice, beforePrice, "empty batch changed price");
                assertEq(afterTick, beforeTick, "empty batch changed tick");
                assertEq(manager.getLiquidity(hook.poolId()), beforeLiquidity);
            }
            // Only a fill of at least 1% of the budget commits the hourly slot.
            if (used * hook.MIN_FILL_DIVISOR() >= budget && budget != 0) {
                assertEq(hook.lastBatch(), block.timestamp, "qualifying fill left the interval open");
            } else {
                assertEq(hook.lastBatch(), previousBatch, "sub-floor or empty batch consumed cooldown");
                if (used > 0) ++subFloorFills;
            }
            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 i; i < logs.length; ++i) {
                assertFalse(
                    logs[i].emitter == address(hook) && logs[i].topics[0] == FEE_EVENT, "batch emitted a hook fee"
                );
            }
            spent += used;
            bought += received;
            // A zero budget exits before any observation. A funded attempt observes the resting
            // state first and, when its swap buys anything, again after it; a rolled-back swap keeps
            // the first. Both happen now, so only the last one carries weight in the integral.
            if (budget != 0) {
                history.push(Observation(block.timestamp, preObservation));
                _expectObservation(hook.observationDepth(), preOnEdge);
            } else {
                _unobserved();
            }
            ++batches;
        } catch (bytes memory reason) {
            assertEq(reason, abi.encodeWithSelector(NUKEHook.BatchTooSoon.selector));
            assertLt(block.timestamp - previousBatch, 3600);
            assertEq(hook.pending(), available);
            assertEq(hook.lastBatch(), previousBatch);
            ++cooldownRefusals;
            _unobserved();
        }
    }

    function sweep() external {
        uint256 expected = hook.pendingBurn();
        uint256 paired = hook.pending();
        uint256 previousBatch = hook.lastBatch();
        uint256 beforeDead = hook.token().balanceOf(hook.DEAD());
        assertEq(hook.sweep(), expected);
        assertEq(hook.token().balanceOf(hook.DEAD()) - beforeDead, expected);
        assertEq(hook.pendingBurn(), 0);
        assertEq(hook.pending(), paired);
        assertEq(hook.lastBatch(), previousBatch);
        ++sweeps;
        _unobserved();
    }

    function forgedCallback(bool afterSwap) external {
        PoolKey memory key = hook.poolKey();
        SwapParams memory params = SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1);
        vm.expectRevert(NUKEHook.OnlyPoolManager.selector);
        if (afterSwap) hook.afterSwap(address(hook), key, params, BalanceDelta.wrap(1), "");
        else hook.beforeSwap(address(hook), key, params, "");
        _unobserved();
    }

    /// @dev The tick the hook currently integrates, as last confirmed by the model.
    function lastObservedTick() public view returns (int24) {
        return history[history.length - 1].tick;
    }

    /// @dev Independent slow model: the time-weighted mean tick over the last complete hour.
    function expectedMeanTick() public view returns (int24) {
        uint256 completedHours = (block.timestamp - start) / 3600;
        if (completedHours == 0) return history[0].tick;
        uint256 end = start + completedHours * 3600;
        uint256 begin = end - 3600;
        int256 integral;
        for (uint256 i; i < history.length; ++i) {
            uint256 left = history[i].time > begin ? history[i].time : begin;
            uint256 right = i + 1 < history.length ? history[i + 1].time : end;
            if (right > end) right = end;
            if (right > left) integral += int256(history[i].tick) * int256(right - left);
        }
        int256 mean = integral / 3600;
        if (integral < 0 && integral % 3600 != 0) --mean;
        return int24(mean);
    }

    function expectedReference() external view returns (uint160) {
        return TickMath.getSqrtPriceAtTick(expectedMeanTick());
    }

    /// @dev Where the real swap engine lands after buying `depth` NUKE from the current resting state.
    function simulatedAsk(uint256 depth) public returns (int24 tick, bool filled) {
        (tick, filled,) = _simulatedAsk(depth);
    }

    /// @dev `onTick` marks a landing exactly on a tick's sqrt price: the engine crosses to the tick when
    /// the segment's floor-rounded amount equals what remains, where the hook prices the fill from the
    /// amount instead. Both are valid readings of the same state, at most one tick apart.
    function _simulatedAsk(uint256 depth) private returns (int24 tick, bool filled, bool onTick) {
        uint160 price;
        (price, filled) = claims.probeAsk(hook.poolKey(), depth);
        if (filled) {
            tick = TickMath.getTickAtSqrtPrice(price);
            onTick = TickMath.getSqrtPriceAtTick(tick) == price;
        }
    }

    /// @dev The tick the model expects the hook to have observed for the current pool state and `depth`.
    function expectedObservation(uint256 depth) public returns (int24 expected) {
        (int24 tick, bool filled) = simulatedAsk(depth);
        expected = filled ? tick : lastObservedTick();
        int24 band = hook.BAND_TICKS();
        int24 mean = expectedMeanTick();
        int24 cheapest = hook.tokenIs0() ? mean - band : mean + band;
        if (hook.tokenIs0() ? expected < cheapest : expected > cheapest) expected = cheapest;
    }

    /// @dev `carriedMayBeOffByOne`: the observation a carry would repeat was itself modelled on the edge.
    function _expectObservation(uint256 depth, bool carriedMayBeOffByOne) private {
        (int24 tick, bool filled, bool onTick) = _simulatedAsk(depth);
        int24 expected = expectedObservation(depth);
        if (!filled) ++carriedObservations;
        else if (expected != tick) ++clampedObservations;
        int24 actual = hook.observedTick();
        if ((filled && onTick) || (!filled && carriedMayBeOffByOne)) {
            assertApproxEqAbs(int256(actual), int256(expected), 1, "observation differs from the executable ask");
        } else {
            assertEq(actual, expected, "observation differs from the executable ask");
        }
        // Integrate what the hook actually recorded, so the time-weighting check stays exact.
        history.push(Observation(block.timestamp, actual));
        _askViewMatchesEngine();
    }

    /// @dev Nothing but a swap or a funded batch may move the observed tick.
    function _unobserved() private {
        assertEq(hook.observedTick(), lastObservedTick(), "observed tick moved without a swap");
        _askViewMatchesEngine();
    }

    /// @dev The hook's tick walk must agree with the swap engine on whether the resting depth is
    /// purchasable and, if so, on the exact price it would be bought at.
    function _askViewMatchesEngine() private {
        (uint160 ask, bool found) = hook.askPrice();
        (uint160 landed, bool filled) = claims.probeAsk(hook.poolKey(), hook.observationDepth());
        assertEq(found, filled, "askPrice disagrees with the engine on whether the depth is for sale");
        if (!found) return;
        int24 landedTick = TickMath.getTickAtSqrtPrice(landed);
        if (TickMath.getSqrtPriceAtTick(landedTick) == landed) {
            // Engine crossed to the tick on an exact-amount segment; the hook priced inside it.
            assertApproxEqAbs(
                int256(TickMath.getTickAtSqrtPrice(ask)), int256(landedTick), 1, "askPrice differs from the engine"
            );
            if (hook.tokenIs0()) assertLe(ask, landed + 1, "askPrice beyond the engine's landing");
            else assertGe(ask + 1, landed, "askPrice beyond the engine's landing");
        } else {
            assertEq(ask, landed, "askPrice differs from where the engine lands");
        }
    }

    function _abs(int128 value) private pure returns (uint256) {
        return uint256(value < 0 ? -int256(value) : int256(value));
    }
}

contract StatefulAccountingTest is HookFixture {
    using StateLibrary for IPoolManager;
    StatefulAccountingHandler internal handler;
    ClaimActor internal claims;

    function setUp() public virtual {
        _prepare(false);
    }

    function _prepare(bool tokenAbove) internal {
        _local(tokenAbove);
        actor.liquidity(key, ModifyLiquidityParams(-12000, 12000, -int256(uint256(LIQUIDITY)), bytes32(0)));
        claims = new ClaimActor(manager);
        handler = new StatefulAccountingHandler(hook, actor, claims);
        nuke.transfer(address(handler), 10_000_000 ether);
        IERC20(IMD).transfer(address(handler), 10_000_000 ether);
        handler.toggleLiquidity();
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.trade.selector;
        selectors[1] = handler.donate.selector;
        selectors[2] = handler.advanceTime.selector;
        selectors[3] = handler.batch.selector;
        selectors[4] = handler.sweep.selector;
        selectors[5] = handler.toggleLiquidity.selector;
        selectors[6] = handler.forgedCallback.selector;
        selectors[7] = handler.shapeLiquidity.selector;
        selectors[8] = handler.dump.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 96
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_accountingAndReferenceSurviveArbitrarySequences() public view virtual {
        assertEq(hook.pending() + handler.spent(), handler.imdIn());
        assertEq(hook.pendingBurn() + nuke.balanceOf(DEAD), handler.nukeIn() + handler.bought());
        assertEq(hook.observedTick(), handler.lastObservedTick(), "observed tick differs from the model");
        assertEq(hook.referencePrice(), handler.expectedReference(), "reference differs from timestamp history");
        assertEq(nuke.totalSupply(), 1e27);
        assertEq(_heldByKnownAccounts(IERC20(address(nuke))), 1e27, "NUKE physically disappeared");
        assertEq(_heldByKnownAccounts(IERC20(IMD)), 1e27, "IMD physically disappeared");
        assertLe(manager.balanceOf(address(hook), uint160(IMD)), IERC20(IMD).balanceOf(address(manager)));
        assertLe(manager.balanceOf(address(hook), uint160(address(nuke))), nuke.balanceOf(address(manager)));
        _settled();
    }

    function test_handlerExercisesPartialFillsDonationsCooldownAndLiquidityRecovery() public {
        handler.batch();
        handler.donate(true, true, 1000 ether);
        handler.donate(false, false, 1000 ether);
        handler.trade(true, false, 1000 ether, 1);
        handler.trade(false, true, 1000 ether, 1);
        handler.toggleLiquidity();
        handler.advanceTime(3600);
        handler.batch();
        assertEq(handler.spent(), 0);
        assertEq(hook.lastBatch(), start, "no-liquidity attempt consumed cooldown");
        handler.toggleLiquidity();
        // Restored liquidity must allow a retry at the very same timestamp.
        handler.batch();
        handler.sweep();
        invariant_accountingAndReferenceSurviveArbitrarySequences();
        assertGt(handler.partialFills(), 0);
        assertGt(handler.cooldownRefusals(), 0);
        assertGt(handler.spent(), 0);
        assertGt(handler.bought(), 0);
        assertEq(hook.lastBatch(), start + 3600, "a full fill must commit the interval");
    }

    function test_handlerRetainsObservationAcrossEmptyRegionMovement() public {
        handler.trade(true, true, 1000 ether, 100);
        int24 observed = hook.observedTick();
        (, int24 liquidTick,,) = manager.getSlot0(key.toId());
        assertTrue(observed != 0 && liquidTick != 0, "setup needs a nonzero observation");
        // The executable ask sits on the expensive side of the raw spot tick.
        if (hook.tokenIs0()) assertGe(observed, liquidTick);
        else assertLe(observed, liquidTick);
        handler.advanceTime(900);
        handler.toggleLiquidity();
        handler.trade(false, true, 1, 100);
        (, int24 emptyTick,,) = manager.getSlot0(key.toId());
        assertTrue(emptyTick != liquidTick, "setup must move through empty liquidity");
        assertEq(manager.getLiquidity(key.toId()), 0);
        assertEq(hook.observedTick(), observed, "an empty-region move was observed");
        assertEq(handler.carriedObservations(), 1);
        handler.advanceTime(2700);
        assertEq(hook.referencePrice(), TickMath.getSqrtPriceAtTick(observed));
        invariant_accountingAndReferenceSurviveArbitrarySequences();

        handler.advanceTime(7200);
        assertEq(hook.referencePrice(), TickMath.getSqrtPriceAtTick(observed));
        invariant_accountingAndReferenceSurviveArbitrarySequences();
    }

    function test_handlerZeroBudgetDoesNotObserveRestoredLiquidity() public {
        handler.toggleLiquidity();
        handler.trade(true, true, 1, 100);
        handler.toggleLiquidity();
        assertEq(manager.getLiquidity(key.toId()), LIQUIDITY);
        (, int24 restoredTick,,) = manager.getSlot0(key.toId());
        assertTrue(restoredTick != 0, "setup needs a changed, unobserved spot");
        assertEq(hook.observedTick(), 0, "the empty-region move must not have been observed");
        handler.advanceTime(3600);
        handler.batch();
        handler.advanceTime(3600);
        assertEq(hook.referencePrice(), Q96, "zero-budget attempt sampled a new tick");
        invariant_accountingAndReferenceSurviveArbitrarySequences();

        // A funded batch observes the restored executable price and buys tokens.
        handler.donate(true, true, 1000 ether);
        handler.batch();
        assertGt(handler.spent(), 0);
        assertGt(handler.bought(), 0);
        int24 observed = hook.observedTick();
        (int24 simulated, bool filled) = handler.simulatedAsk(hook.observationDepth());
        assertTrue(filled);
        assertEq(observed, simulated, "post-batch observation is not the executable ask");
        assertTrue(observed != 0);
        handler.advanceTime(3600);
        assertEq(hook.referencePrice(), TickMath.getSqrtPriceAtTick(observed));
        invariant_accountingAndReferenceSurviveArbitrarySequences();
    }

    function test_handlerFundedZeroOutputBatchRetainsRestingObservation() public {
        handler.toggleLiquidity();
        handler.trade(true, true, 1, 100);
        handler.toggleLiquidity();
        (, int24 restoredTick,,) = manager.getSlot0(key.toId());
        assertTrue(restoredTick != 0);
        (int24 restingAsk, bool filled) = handler.simulatedAsk(hook.observationDepth());
        assertTrue(filled);
        assertTrue(restingAsk != 0);
        handler.advanceTime(3600);
        handler.donate(true, true, 4); // One wei of budget cannot buy any NUKE after the LP fee.
        handler.batch();
        assertEq(handler.spent(), 0);
        assertEq(handler.bought(), 0);
        assertEq(hook.pending(), 4);
        assertEq(hook.lastBatch(), start);
        // The swap rolls back, but the observation taken before it remains valid.
        assertEq(hook.observedTick(), restingAsk);
        handler.advanceTime(3600);
        assertEq(hook.referencePrice(), TickMath.getSqrtPriceAtTick(restingAsk));
        invariant_accountingAndReferenceSurviveArbitrarySequences();
    }

    function test_handlerCanReverseAtAnEmptyTickBitmapBoundary() public {
        handler.toggleLiquidity();
        bool downwardBuy = !hook.tokenIs0();
        handler.trade(!downwardBuy, true, 1, 100);
        handler.trade(downwardBuy, true, 1, 100);
        (uint160 spot, int24 tick,,) = manager.getSlot0(key.toId());
        assertEq(spot, Q96);
        assertEq(tick, -1);
        handler.trade(!downwardBuy, false, 1, 1);
        assertEq(hook.pending() + hook.pendingBurn(), 0);
        invariant_accountingAndReferenceSurviveArbitrarySequences();
    }

    /// @dev A large sale observes the band floor, not the executable ask; a large buy is not banded.
    function test_handlerClampsCheapObservationsToTheBandOnly() public {
        handler.advanceTime(1);
        handler.trade(false, true, 1000 ether, 100);
        assertEq(handler.clampedObservations(), 0, "a 100-tick move must not be clamped");
        handler.dump(false, 250_000 ether); // Sells roughly 4350 ticks deep: beyond one band.
        assertEq(handler.clampedObservations(), 1, "a sale beyond the band was not clamped");
        (, int24 spotTick,,) = manager.getSlot0(key.toId());
        int24 band = hook.BAND_TICKS();
        if (hook.tokenIs0()) {
            assertLt(spotTick, -band);
            assertEq(hook.observedTick(), -band);
        } else {
            assertGt(spotTick, band);
            assertEq(hook.observedTick(), band);
        }
        handler.advanceTime(3599);
        invariant_accountingAndReferenceSurviveArbitrarySequences();
        // Buying back the same amount moves the price far on the expensive side and is observed as is.
        int24 mean = handler.expectedMeanTick();
        handler.dump(true, 250_000 ether);
        assertEq(handler.clampedObservations(), 1, "an expensive observation was clamped");
        (, spotTick,,) = manager.getSlot0(key.toId());
        if (hook.tokenIs0()) {
            assertGt(hook.observedTick(), mean + band, "a rise beyond the band must be observed as is");
            assertGt(hook.observedTick(), spotTick, "the ask must sit beyond the spot on the expensive side");
        } else {
            assertLt(hook.observedTick(), mean - band, "a rise beyond the band must be observed as is");
            assertLt(hook.observedTick(), spotTick, "the ask must sit beyond the spot on the expensive side");
        }
        handler.advanceTime(3600);
        invariant_accountingAndReferenceSurviveArbitrarySequences();
    }

    /// @dev Positions straddling bitmap word boundaries, with the main position removed so the walk
    /// has to cross empty words and several initialized ticks; the walk and the engine must agree.
    function test_handlerShapedLiquidityKeepsWalkAndEngineInAgreement() public {
        handler.shapeLiquidity(3, true, 1e22);
        handler.shapeLiquidity(4, true, 1e22);
        handler.shapeLiquidity(2, true, 5e21);
        handler.shapeLiquidity(0, true, 1e18);
        handler.shapeLiquidity(1, true, 1e18);
        handler.toggleLiquidity();
        handler.trade(true, false, 1000 ether, 100);
        handler.trade(false, true, 1000 ether, 100);
        handler.advanceTime(1800);
        handler.trade(true, true, 1000 ether, 50);
        handler.shapeLiquidity(2, false, 0); // Only the far ranges and dust remain.
        handler.trade(true, true, 1000 ether, 100);
        handler.dump(true, 100_000 ether); // Crosses the empty words into the far ranges.
        assertGt(handler.carriedObservations() + handler.clampedObservations(), 0);
        handler.advanceTime(1800);
        handler.donate(true, true, 1000 ether);
        handler.batch();
        invariant_accountingAndReferenceSurviveArbitrarySequences();
        assertGt(handler.swaps(), 4);
        assertGt(handler.liquidityChanges(), 6);
    }

    function _heldByKnownAccounts(IERC20 t) private view returns (uint256) {
        return t.balanceOf(address(this)) + t.balanceOf(address(handler)) + t.balanceOf(address(manager))
            + t.balanceOf(address(hook)) + t.balanceOf(DEAD) + t.balanceOf(address(actor))
            + t.balanceOf(address(claims));
    }
}

contract StatefulAccountingReverseOrderTest is StatefulAccountingTest {
    function setUp() public override {
        _prepare(true);
    }

    // Foundry associates inline settings with the concrete contract, not inherited test functions.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 96
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_accountingAndReferenceSurviveArbitrarySequences() public view override {
        super.invariant_accountingAndReferenceSurviveArbitrarySequences();
    }
}
