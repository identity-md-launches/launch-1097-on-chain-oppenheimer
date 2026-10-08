// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract OracleLiquidityTest is HookFixture {
    using StateLibrary for IPoolManager;

    function setUp() public virtual {
        _local(false);
    }

    function test_zeroLiquidityTickDoesNotEnterHourlyReference() public {
        int24 activeTick = _emptyRegionExcursion();
        vm.warp(start + 3600);
        int256 integral = int256(activeTick) * 3488;
        int256 mean = integral / 3600;
        if (integral < 0 && integral % 3600 != 0) --mean;
        assertEq(
            hook.referencePrice(), TickMath.getSqrtPriceAtTick(int24(mean)), "empty-region tick poisoned reference"
        );
    }

    function test_zeroLiquidityExcursionDoesNotDisablePermissionlessBuyback() public {
        _emptyRegionExcursion();
        IERC20(IMD).transfer(address(hook), 1000 ether);
        uint256 pendingBurnBefore = hook.pendingBurn();
        uint256 deadBefore = nuke.balanceOf(DEAD);
        vm.warp(start + 3600);
        vm.prank(makeAddr("permissionless keeper"));
        (uint256 spent, uint256 burned) = hook.executeBatch();
        assertEq(spent, 250 ether, "empty-region tick disabled buyback");
        assertGt(burned, 0);
        assertEq(nuke.balanceOf(DEAD) - deadBefore, burned);
        assertEq(hook.pending(), 750 ether);
        assertEq(hook.pendingBurn(), pendingBurnBefore);
        assertEq(hook.lastBatch(), start + 3600);
        _settled();
    }

    function test_batchTraversesEmptyRegionUsingLiquidReference() public {
        _moveIntoEmptyRegion();
        IERC20(IMD).transfer(address(hook), 1000 ether);
        vm.warp(start + 3600);
        assertEq(hook.referencePrice(), Q96, "empty-region tick changed reference");
        uint256 deadBefore = nuke.balanceOf(DEAD);
        vm.prank(makeAddr("permissionless keeper"));
        (uint256 spent, uint256 burned) = hook.executeBatch();
        assertEq(spent, 250 ether, "empty spot prevented crossing into liquidity");
        assertGt(burned, 0);
        assertEq(nuke.balanceOf(DEAD) - deadBefore, burned);
        assertEq(hook.pending(), 750 ether);
        assertEq(manager.getLiquidity(key.toId()), LIQUIDITY);
        assertEq(hook.lastBatch(), start + 3600);
        _settled();
    }

    function test_batchLeavingLiquidityKeepsPreviousLiquidTick() public {
        _nukeOnlyPosition(60);
        vm.warp(start + 100);
        _swap(true, true, 100 ether, false);
        (, int24 activeTick,,) = manager.getSlot0(key.toId());
        assertEq(manager.getLiquidity(key.toId()), LIQUIDITY);
        assertTrue(activeTick != 0, "setup needs a nonzero liquid tick");
        IERC20(IMD).transfer(address(hook), 100_000 ether);
        vm.warp(start + 3600);
        uint256 deadBefore = nuke.balanceOf(DEAD);
        (uint256 spent, uint256 burned) = hook.executeBatch();
        assertGt(spent, 0);
        assertLt(spent, 25_000 ether, "batch did not exhaust narrow position");
        assertGt(burned, 0);
        assertEq(nuke.balanceOf(DEAD) - deadBefore, burned);
        assertEq(hook.pending(), 100_000 ether - spent);
        assertEq(manager.getLiquidity(key.toId()), 0, "batch did not leave liquidity");
        (, int24 emptyTick,,) = manager.getSlot0(key.toId());
        assertTrue(emptyTick != activeTick, "batch did not move slot0");
        vm.warp(start + 7200);
        assertEq(hook.referencePrice(), TickMath.getSqrtPriceAtTick(activeTick), "batch recorded empty-region tick");
        _settled();
    }

    function _emptyRegionExcursion() internal returns (int24 activeTick) {
        _moveIntoEmptyRegion();
        vm.warp(start + 112);
        _swap(true, true, 100 ether, false);
        assertEq(manager.getLiquidity(key.toId()), LIQUIDITY, "buy did not restore active liquidity");
        (, activeTick,,) = manager.getSlot0(key.toId());
    }

    function _nukeOnlyPosition(int24 width) internal {
        actor.liquidity(key, ModifyLiquidityParams(-12000, 12000, -int256(uint256(LIQUIDITY)), bytes32(0)));
        int24 lower = hook.tokenIs0() ? int24(0) : -width;
        int24 upper = hook.tokenIs0() ? width : int24(0);
        BalanceDelta added =
            actor.liquidity(key, ModifyLiquidityParams(lower, upper, int256(uint256(LIQUIDITY)), bytes32(0)));
        assertEq(hook.tokenIs0() ? added.amount1() : added.amount0(), 0, "position must contain only NUKE");
    }

    function _moveIntoEmptyRegion() internal {
        _nukeOnlyPosition(12000);
        vm.warp(start + 100);
        bool zeroForOne = hook.tokenIs0();
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        BalanceDelta empty = actor.swap(key, SwapParams(zeroForOne, -1, limit));
        assertEq(BalanceDelta.unwrap(empty), 0, "empty-region sell filled");
        assertEq(manager.getLiquidity(key.toId()), 0, "empty-region liquidity is nonzero");
        (uint160 emptyPrice,,,) = manager.getSlot0(key.toId());
        assertEq(emptyPrice, limit, "empty-region sell did not reach extreme price");
        assertEq(hook.pending() + hook.pendingBurn(), 0, "empty sell accrued a fee");
        _settled();
    }
}

contract OracleLiquidityReverseOrderTest is OracleLiquidityTest {
    function setUp() public override {
        _local(true);
    }
}
