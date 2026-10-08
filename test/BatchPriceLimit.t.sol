// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract BatchPriceLimitTest is HookFixture {
    using StateLibrary for IPoolManager;

    function setUp() public virtual {
        _local(false);
    }

    function test_staleReferenceRoundTripLosesAfterFees() public {
        _roundTrip(true);
    }

    function test_freshReferenceRoundTripControlLosesAfterFees() public {
        _roundTrip(false);
    }

    function _roundTrip(bool priceDrop) internal {
        IERC20(IMD).transfer(address(hook), 400_000 ether);
        vm.warp(start + 3600);
        if (priceDrop) _trade(false, 60_000 ether);
        assertEq(hook.referencePrice(), Q96);

        address trader = makeAddr("round trip trader");
        IERC20(IMD).transfer(trader, 30_000 ether);
        vm.startPrank(trader);
        IERC20(IMD).approve(address(actor), type(uint256).max);
        nuke.approve(address(actor), type(uint256).max);
        _trade(true, 30_000 ether);
        (uint256 spent, uint256 burned) = hook.executeBatch();
        _trade(false, nuke.balanceOf(trader));
        vm.stopPrank();

        if (priceDrop) {
            assertGt(spent, 0, "buyback must remain usable below the stale reference");
            assertGt(burned, 0);
        } else {
            assertEq(spent + burned, 0, "front leg crossed the reference bound");
        }
        assertLt(IERC20(IMD).balanceOf(trader), 30_000 ether, "round trip extracted buyback funds");
        assertEq(nuke.balanceOf(trader), 0);
        _settled();
    }

    /// @dev Falling spot must tighten the price limit throughout the incomplete hour.
    function testFuzz_batchEndsWithinThreePercentOfSpot(uint96 sellSeed, uint16 timeSeed) public {
        IERC20(IMD).transfer(address(hook), 400_000 ether);
        vm.warp(start + bound(uint256(timeSeed), 3600, 7199));
        uint160 originalLimit = hook.batchPriceLimit();
        _trade(false, bound(uint256(sellSeed), 1 ether, 100_000 ether));
        assertEq(hook.referencePrice(), Q96, "same-block sell changed completed reference");
        (uint160 spot,,,) = manager.getSlot0(key.toId());
        uint160 limit = hook.batchPriceLimit();
        if (hook.tokenIs0()) assertLt(limit, originalLimit);
        else assertGt(limit, originalLimit);
        uint256 adverseSqrtRatio =
            hook.tokenIs0() ? FullMath.mulDiv(limit, 1e18, spot) : FullMath.mulDiv(spot, 1e18, limit);
        uint256 adversePriceRatio = FullMath.mulDiv(adverseSqrtRatio, adverseSqrtRatio, 1e18);
        assertLe(adversePriceRatio, 1.03e18);
        assertApproxEqAbs(adversePriceRatio, 1.03e18, 3);

        uint256 accrued = hook.pending();
        (uint256 spent, uint256 burned) = hook.executeBatch();
        assertGt(spent, 0);
        assertLt(spent, accrued / 4, "expected price-limited partial fill");
        assertGt(burned, 0);
        (uint160 finalSpot,,,) = manager.getSlot0(key.toId());
        assertEq(finalSpot, limit);
        assertEq(hook.pending(), accrued - spent);
        assertEq(nuke.balanceOf(DEAD), burned);
        _settled();
    }

    function _trade(bool buy, uint256 amount) internal {
        bool zeroForOne = buy != hook.tokenIs0();
        actor.swap(
            key,
            SwapParams(
                zeroForOne, -int256(amount), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            )
        );
    }
}

contract BatchPriceLimitReverseOrderTest is BatchPriceLimitTest {
    function setUp() public override {
        _local(true);
    }
}
