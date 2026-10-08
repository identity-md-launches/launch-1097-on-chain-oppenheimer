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
    uint256 public sweeps;
    uint256 public donations;
    uint256 public liquidityChanges;
    bytes32 private constant SWAP_EVENT = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes32 private constant FEE_EVENT = keccak256("FeeAccrued(address,uint256)");

    struct Observation {
        uint256 time;
        int24 tick;
    }
    Observation[] private history;

    constructor(NUKEHook h, PoolActor a, ClaimActor c) {
        hook = h;
        actor = a;
        claims = c;
        manager = h.poolManager();
        start = block.timestamp;
        history.push(Observation(start, 0));
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
    }

    function donate(bool paired, bool asClaim, uint80 seed) external {
        Currency c = paired ? Currency.wrap(hook.IMD()) : hook.token();
        uint256 amount = bound(uint256(seed), 0, 1000 ether);
        if (asClaim) claims.deposit(c, amount, address(hook));
        else assertTrue(IERC20(Currency.unwrap(c)).transfer(address(hook), amount));
        if (paired) imdIn += amount;
        else nukeIn += amount;
        ++donations;
    }

    function trade(bool buy, bool exactInput, uint80 amountSeed, uint8 limitSeed) external {
        uint256 amount = bound(uint256(amountSeed), 1, 1000 ether);
        bool zeroForOne = buy != hook.tokenIs0();
        PoolKey memory key = hook.poolKey();
        (uint160 spot, int24 tick,,) = manager.getSlot0(key.toId());
        // Even without liquidity, walk only a bounded number of ticks per call.
        int24 distance = int24(int256(bound(uint256(limitSeed), 1, 100)));
        uint160 limit = TickMath.getSqrtPriceAtTick(tick + (zeroForOne ? -distance : distance));
        // After crossing downward, core can report tick t-1 at the exact sqrt price of t.
        // A one-tick reverse move must still set a limit strictly above that spot price.
        if (!zeroForOne && limit <= spot) limit = TickMath.getSqrtPriceAtTick(tick + distance + 1);
        vm.recordLogs();
        BalanceDelta net = actor.swap(key, SwapParams(zeroForOne, exactInput ? -int256(amount) : int256(amount), limit));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
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
            if (unspecified0 == hook.tokenIs0()) nukeIn += fee;
            else imdIn += fee;
            if (_abs(unspecified0 ? a1 : a0) < amount) ++partialFills;
        }
        assertTrue(found, "missing core swap");
        _recordPrice();
        ++swaps;
    }

    function advanceTime(uint16 seed) external {
        vm.warp(block.timestamp + bound(uint256(seed), 0, 10800));
    }

    function batch() external {
        uint256 available = hook.pending();
        uint256 previousBatch = hook.lastBatch();
        uint256 beforeBurn = hook.pendingBurn();
        uint256 beforeDead = hook.token().balanceOf(hook.DEAD());
        vm.recordLogs();
        try hook.executeBatch() returns (uint256 used, uint256 received) {
            assertGe(block.timestamp - previousBatch, 3600);
            assertLe(used, available / 4, "batch exceeded budget");
            assertEq(hook.pending(), available - used);
            assertEq(hook.pendingBurn(), beforeBurn, "batch charged itself");
            assertEq(hook.token().balanceOf(hook.DEAD()) - beforeDead, received);
            if (used > 0) assertEq(hook.lastBatch(), block.timestamp);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 i; i < logs.length; ++i) {
                assertFalse(
                    logs[i].emitter == address(hook) && logs[i].topics[0] == FEE_EVENT, "batch emitted a hook fee"
                );
            }
            spent += used;
            bought += received;
            _recordPrice();
            ++batches;
        } catch (bytes memory reason) {
            assertEq(reason, abi.encodeWithSelector(NUKEHook.BatchTooSoon.selector));
            assertLt(block.timestamp - previousBatch, 3600);
            assertEq(hook.pending(), available);
            assertEq(hook.lastBatch(), previousBatch);
            ++cooldownRefusals;
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
    }

    function forgedCallback(bool afterSwap) external {
        PoolKey memory key = hook.poolKey();
        SwapParams memory params = SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1);
        vm.expectRevert(NUKEHook.OnlyPoolManager.selector);
        if (afterSwap) hook.afterSwap(address(hook), key, params, BalanceDelta.wrap(1), "");
        else hook.beforeSwap(address(hook), key, params, "");
    }

    /// @dev Independent slow model: integrate timestamped price segments over the last complete hour.
    function expectedReference() external view returns (uint160) {
        uint256 completedHours = (block.timestamp - start) / 3600;
        if (completedHours == 0) return uint160(1 << 96);
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
        return TickMath.getSqrtPriceAtTick(int24(mean));
    }

    function _recordPrice() private {
        (, int24 tick,,) = manager.getSlot0(hook.poolKey().toId());
        history.push(Observation(block.timestamp, tick));
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
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.trade.selector;
        selectors[1] = handler.donate.selector;
        selectors[2] = handler.advanceTime.selector;
        selectors[3] = handler.batch.selector;
        selectors[4] = handler.sweep.selector;
        selectors[5] = handler.toggleLiquidity.selector;
        selectors[6] = handler.forgedCallback.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 96
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_accountingAndReferenceSurviveArbitrarySequences() public view virtual {
        assertEq(hook.pending() + handler.spent(), handler.imdIn());
        assertEq(hook.pendingBurn() + nuke.balanceOf(DEAD), handler.nukeIn() + handler.bought());
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
        handler.toggleLiquidity();
        handler.advanceTime(3600);
        handler.batch();
        handler.sweep();
        invariant_accountingAndReferenceSurviveArbitrarySequences();
        assertGt(handler.partialFills(), 0);
        assertGt(handler.cooldownRefusals(), 0);
        assertGt(handler.spent(), 0);
        assertGt(handler.bought(), 0);
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
