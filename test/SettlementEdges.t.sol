// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture, TestPair} from "./helpers/HookFixture.sol";
import {PoolActor} from "./helpers/PoolActor.sol";
import {ClaimActor} from "./helpers/ClaimActor.sol";
import {NUKE} from "src/NUKE.sol";
import {NUKEHook} from "src/NUKEHook.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract SettlementEdgesTest is HookFixture {
    using StateLibrary for IPoolManager;

    function setUp() public virtual {
        _local(false);
    }

    function test_failedInputSettlementRollsBackFeesPriceAndOracle() public {
        _swap(false, true, 1000 ether, false);
        uint256 pending = hook.pending();
        uint256 burn = hook.pendingBurn();
        (uint160 price,,,) = manager.getSlot0(key.toId());
        vm.warp(start + 1800);
        IERC20(IMD).approve(address(actor), 0);
        bool tokenIs0 = hook.tokenIs0();
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(actor), 0, 10_000 ether)
        );
        actor.swap(
            key,
            SwapParams(!tokenIs0, -10_000 ether, tokenIs0 ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1)
        );
        (uint160 afterPrice,,,) = manager.getSlot0(key.toId());
        assertEq(afterPrice, price);
        assertEq(hook.pending(), pending);
        assertEq(hook.pendingBurn(), burn);
        vm.warp(start + 3600);
        assertEq(hook.referencePrice(), TickMath.getSqrtPriceAtTick(TickMath.getTickAtSqrtPrice(price)));
        IERC20(IMD).approve(address(actor), type(uint256).max);
        _swap(true, true, 1000 ether, false);
        _settled();
    }

    function test_failedSweepPreservesClaimsAndCanBeRetried() public {
        _swap(true, true, 1000 ether, false);
        nuke.transfer(address(hook), 7 ether);
        uint256 claims = manager.balanceOf(address(hook), uint160(address(nuke)));
        uint256 expected = hook.pendingBurn();
        // Fail the donation transfer after the earlier claim redemption has already succeeded.
        vm.mockCallRevert(address(nuke), abi.encodeCall(IERC20.transfer, (DEAD, 7 ether)), hex"deadbeef");
        vm.expectRevert(); // Currency wraps the token's failed transfer.
        hook.sweep();
        assertEq(manager.balanceOf(address(hook), uint160(address(nuke))), claims);
        assertEq(hook.pendingBurn(), expected);
        assertEq(nuke.balanceOf(DEAD), 0);
        _settled();
        vm.clearMockedCalls();
        assertEq(hook.sweep(), expected);
        assertEq(nuke.balanceOf(DEAD), expected);
        assertEq(hook.pendingBurn(), 0);
        _settled();
    }

    function test_failedBatchRestoresCooldownClaimsAndOracleThenRetries() public {
        _swap(false, true, 1000 ether, false);
        IERC20(IMD).transfer(address(hook), 1000 ether);
        uint256 pending = hook.pending();
        uint256 claims = manager.balanceOf(address(hook), uint160(IMD));
        uint256 ref;
        vm.warp(start + 3600);
        ref = hook.referencePrice();
        (uint160 price,,,) = manager.getSlot0(key.toId());
        // The batch burns some claims before paying the remaining input from wallet funds.
        vm.mockCallRevert(IMD, abi.encodeWithSelector(IERC20.transfer.selector, address(manager)), hex"deadbeef");
        vm.expectRevert();
        hook.executeBatch();
        assertEq(hook.lastBatch(), start);
        assertEq(hook.pending(), pending);
        assertEq(manager.balanceOf(address(hook), uint160(IMD)), claims);
        assertEq(hook.referencePrice(), ref);
        (uint160 afterPrice,,,) = manager.getSlot0(key.toId());
        assertEq(afterPrice, price);
        assertEq(nuke.balanceOf(DEAD), 0);
        _settled();
        vm.clearMockedCalls();
        (uint256 spent, uint256 bought) = hook.executeBatch();
        assertEq(spent, pending / 4);
        assertGt(bought, 0);
        assertEq(hook.pending(), pending - spent);
        assertEq(nuke.balanceOf(DEAD), bought);
        _settled();
    }

    function test_claimSettledSwapsKeepWalletsUnchangedAndChargeActualFill() public {
        ClaimActor router = new ClaimActor(manager);
        nuke.approve(address(router), type(uint256).max);
        IERC20(IMD).approve(address(router), type(uint256).max);
        router.deposit(key.currency0, 10_000 ether, address(this));
        router.deposit(key.currency1, 10_000 ether, address(this));
        manager.setOperator(address(router), true);
        for (uint256 i; i < 8; ++i) {
            bool buy = i & 1 != 0;
            bool exactInput = i & 2 != 0;
            bool zeroForOne = buy != hook.tokenIs0();
            bool limited = i >= 4;
            uint256 amount = limited ? 100_000 ether : 1000 ether;
            (, int24 tick,,) = manager.getSlot0(key.toId());
            uint160 limit = limited
                ? TickMath.getSqrtPriceAtTick(tick + (zeroForOne ? int24(-10) : int24(10)))
                : (zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
            uint256 wallet0 = key.currency0.balanceOf(address(this));
            uint256 wallet1 = key.currency1.balanceOf(address(this));
            uint256 claims0 = manager.balanceOf(address(this), key.currency0.toId());
            uint256 claims1 = manager.balanceOf(address(this), key.currency1.toId());
            uint256 pending0 = manager.balanceOf(address(hook), key.currency0.toId());
            uint256 pending1 = manager.balanceOf(address(hook), key.currency1.toId());
            uint256 snapshot = vm.snapshotState();
            (BalanceDelta raw, BalanceDelta walletNet) = _swap(buy, exactInput, amount, limited);
            assertTrue(vm.revertToState(snapshot));
            BalanceDelta claimsNet = router.swap(
                key, SwapParams(zeroForOne, exactInput ? -int256(amount) : int256(amount), limit), true, true
            );
            assertEq(BalanceDelta.unwrap(claimsNet), BalanceDelta.unwrap(walletNet));
            assertEq(key.currency0.balanceOf(address(this)), wallet0);
            assertEq(key.currency1.balanceOf(address(this)), wallet1);
            assertEq(
                int256(manager.balanceOf(address(this), key.currency0.toId())) - int256(claims0), claimsNet.amount0()
            );
            assertEq(
                int256(manager.balanceOf(address(this), key.currency1.toId())) - int256(claims1), claimsNet.amount1()
            );
            assertEq(
                manager.balanceOf(address(hook), key.currency0.toId()) - pending0,
                uint256(int256(raw.amount0()) - int256(claimsNet.amount0()))
            );
            assertEq(
                manager.balanceOf(address(hook), key.currency1.toId()) - pending1,
                uint256(int256(raw.amount1()) - int256(claimsNet.amount1()))
            );
            _settled();
        }
    }

    function test_budgetDustAccumulatesUntilOneUnitCanBeSpent() public {
        vm.warp(start + 3600);
        for (uint256 i = 1; i < 4; ++i) {
            IERC20(IMD).transfer(address(hook), 1);
            (uint256 dustSpent, uint256 dustBought) = hook.executeBatch();
            assertEq(dustSpent + dustBought, 0);
            assertEq(hook.pending(), i);
            assertEq(hook.lastBatch(), start);
        }
        IERC20(IMD).transfer(address(hook), 397);
        (uint256 spent, uint256 bought) = hook.executeBatch();
        assertEq(spent, 100);
        assertGt(bought, 0);
        assertEq(hook.pending(), 300);
        assertEq(nuke.balanceOf(DEAD), bought);
        _settled();
    }

    function test_batchWorksWithAdditionalProtocolFee() public {
        manager.setProtocolFeeController(address(this));
        manager.setProtocolFee(key, uint24(1000 | (1000 << 12)));
        IERC20(IMD).transfer(address(hook), 10_000 ether);
        vm.warp(start + 3600);
        (uint256 spent, uint256 bought) = hook.executeBatch();
        assertEq(spent, 2500 ether);
        assertGt(bought, 0);
        assertEq(nuke.balanceOf(DEAD), bought);
        assertEq(hook.pendingBurn(), 0);
        assertGt(manager.protocolFeesAccrued(Currency.wrap(IMD)), 0);
        (,,, uint24 lpFee) = manager.getSlot0(key.toId());
        assertEq(lpFee, 12500);
        _settled();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_largestRepresentableRequestsPartiallyFill(bool buy, bool exactInput, uint8 distance) public {
        uint256 maximum = uint256(type(int256).max);
        // Solve x + floor(x/100) <= int256.max without overflowing a multiplication by 100.
        uint256 boundary = (maximum / 101) * 100 + (maximum % 101 < 100 ? maximum % 101 : 99);
        _swap(buy, exactInput, boundary - uint256(distance), true);
        bool direction = buy != hook.tokenIs0();
        vm.prank(address(manager));
        vm.expectRevert(NUKEHook.UnrepresentableFee.selector);
        hook.beforeSwap(
            address(actor),
            key,
            SwapParams(direction, exactInput ? -int256(boundary + 1) : int256(boundary + 1), Q96),
            ""
        );
    }
}

contract SettlementEdgesReverseOrderTest is SettlementEdgesTest {
    function setUp() public override {
        _local(true);
    }
}

contract FreshPoolClaimsTest is HookFixture {
    ClaimActor internal router;

    function setUp() public virtual {
        router = _seedOnlyNUKE(false);
    }

    function _seedOnlyNUKE(bool tokenAbove) internal returns (ClaimActor freshRouter) {
        manager = IPoolManager(address(new PoolManager(address(this))));
        vm.etch(IMD, address(new TestPair()).code);
        TestPair(IMD).mint(address(this), 1_000_000 ether);
        do {
            nuke = new NUKE();
        } while ((address(nuke) > IMD) != tokenAbove);
        hook = _deployHook(address(nuke));
        key = hook.poolKey();
        actor = new PoolActor(manager);
        nuke.approve(address(actor), type(uint256).max);
        IERC20(IMD).approve(address(actor), type(uint256).max);
        start = block.timestamp;
        manager.initialize(key, Q96);
        actor.liquidity(
            key,
            ModifyLiquidityParams(
                hook.tokenIs0() ? int24(0) : int24(-12000),
                hook.tokenIs0() ? int24(12000) : int24(0),
                int256(uint256(LIQUIDITY)),
                bytes32(0)
            )
        );
        assertEq(IERC20(IMD).balanceOf(address(manager)), 0, "seed must contain only NUKE");
        assertGt(nuke.balanceOf(address(manager)), 0);
        freshRouter = new ClaimActor(manager);
        IERC20(IMD).approve(address(freshRouter), type(uint256).max);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_firstBuyAccruesBeforeInputArrives(bool exactInput, uint64 seed) public {
        uint256 amount = bound(uint256(seed), 1 ether, 10 ether);
        bool direction = !hook.tokenIs0();
        BalanceDelta net = router.swap(
            key,
            SwapParams(
                direction,
                exactInput ? -int256(amount) : int256(amount),
                direction ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            false,
            false
        );
        assertEq(router.pairReserveBeforeSettlement(), 0);
        if (exactInput) {
            assertGt(router.tokenFeesBeforeSettlement(), 0);
            assertEq(router.pairFeesBeforeSettlement(), 0);
            uint256 output = uint256(int256(hook.tokenIs0() ? net.amount0() : net.amount1()));
            assertEq(hook.pendingBurn(), (output + hook.pendingBurn()) / 100);
            assertEq(hook.sweep(), router.tokenFeesBeforeSettlement());
        } else {
            uint256 input = _abs(hook.tokenIs0() ? net.amount1() : net.amount0());
            assertGt(router.pairFeesBeforeSettlement(), 0);
            assertEq(router.tokenFeesBeforeSettlement(), 0);
            assertEq(hook.pending(), (input - hook.pending()) / 100);
            assertEq(IERC20(IMD).balanceOf(address(manager)), input);
            vm.warp(start + 3600);
            (uint256 spent, uint256 bought) = hook.executeBatch();
            assertGt(spent, 0);
            assertGt(bought, 0);
            assertEq(nuke.balanceOf(DEAD), bought);
        }
        _settled();
    }
}

contract FreshPoolClaimsReverseOrderTest is FreshPoolClaimsTest {
    function setUp() public override {
        router = _seedOnlyNUKE(true);
    }
}
