// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {NUKEHook} from "../src/NUKEHook.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DustBatchTest is HookFixture {
    using StateLibrary for IPoolManager;

    function setUp() public virtual {
        _local(false);
        IERC20(IMD).transfer(address(hook), 400_000 ether);
        vm.warp(start + 3600);
    }

    function test_zeroOutputBatchRollsBackAndLeavesIntervalAvailable() public {
        BalanceDelta front = _parkInsideLimit(1);
        (uint160 spotBefore, int24 tickBefore,,) = manager.getSlot0(key.toId());
        uint256 pendingBefore = hook.pending();
        uint256 pendingBurnBefore = hook.pendingBurn();
        uint256 burnedBefore = nuke.balanceOf(DEAD);
        uint256 managerIMDBefore = IERC20(IMD).balanceOf(address(manager));

        (uint256 spent, uint256 burned) = hook.executeBatch();
        assertEq(spent, 0);
        assertEq(burned, 0);
        assertEq(hook.pending(), pendingBefore);
        assertEq(hook.pendingBurn(), pendingBurnBefore);
        assertEq(hook.lastBatch(), start);
        assertEq(nuke.balanceOf(DEAD), burnedBefore);
        assertEq(IERC20(IMD).balanceOf(address(manager)), managerIMDBefore);
        (uint160 spotAfter, int24 tickAfter,,) = manager.getSlot0(key.toId());
        assertEq(spotAfter, spotBefore);
        assertEq(tickAfter, tickBefore);
        _settled();

        // Restoring a viable price permits the real buyback in this same timestamp.
        uint256 received = uint256(int256(hook.tokenIs0() ? front.amount0() : front.amount1()));
        actor.swap(
            key,
            SwapParams(
                hook.tokenIs0(),
                -int256(received),
                hook.tokenIs0() ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            )
        );
        (spent, burned) = hook.executeBatch();
        assertGt(spent, 0);
        assertGt(burned, 0);
        assertEq(hook.lastBatch(), block.timestamp);
        _settled();
    }

    function test_tinyPositiveOutputPartialFillConsumesInterval() public {
        _parkInsideLimit(1_000_000);
        uint256 pendingBefore = hook.pending();
        (uint256 spent, uint256 burned) = hook.executeBatch();
        assertGt(spent, 0);
        assertGt(burned, 0);
        assertLt(spent, 100, "test should exercise a tiny real fill");
        assertEq(hook.pending(), pendingBefore - spent);
        assertEq(nuke.balanceOf(DEAD), burned);
        assertEq(hook.lastBatch(), block.timestamp);
        vm.expectRevert(NUKEHook.BatchTooSoon.selector);
        hook.executeBatch();
        _settled();
    }

    function test_batchPropagatesUnrelatedUnlockFailure() public {
        bytes memory failure = abi.encodeWithSignature("UnexpectedSettlementFailure(uint256)", 42);
        vm.mockCallRevert(address(manager), abi.encodeWithSelector(IPoolManager.unlock.selector), failure);
        vm.expectRevert(failure);
        hook.executeBatch();
        assertEq(hook.pending(), 400_000 ether);
        assertEq(hook.lastBatch(), start);
        vm.clearMockedCalls();
        (uint256 spent, uint256 burned) = hook.executeBatch();
        assertGt(spent, 0);
        assertGt(burned, 0);
        _settled();
    }

    function _parkInsideLimit(uint160 margin) private returns (BalanceDelta delta) {
        uint160 limit = hook.batchPriceLimit();
        uint160 nearLimit = hook.tokenIs0() ? limit - margin : limit + margin;
        delta = actor.swap(key, SwapParams(!hook.tokenIs0(), -int256(1_000_000 ether), nearLimit));
        (uint160 spot,,,) = manager.getSlot0(key.toId());
        assertEq(spot, nearLimit);
    }
}

contract DustBatchReverseOrderTest is DustBatchTest {
    function setUp() public override {
        _local(true);
        IERC20(IMD).transfer(address(hook), 400_000 ether);
        vm.warp(start + 3600);
    }
}
