// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {TickBitmap} from "v4-core/src/libraries/TickBitmap.sol";
import {BitMath} from "v4-core/src/libraries/BitMath.sol";
import {LiquidityMath} from "v4-core/src/libraries/LiquidityMath.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @notice Immutable, single-pool NUKE/IMD fee collection and permissionless batch buybacks.
/// @dev Fees remain ERC-6909 claims until burned or spent; callbacks never transfer ERC-20s.
contract NUKEHook is IUnlockCallback {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant FEE_BPS = 100;
    uint256 public constant BATCH_BPS = 2500;
    uint256 public constant PRICE_LIMIT_BPS = 300;
    uint256 public constant BATCH_INTERVAL = 3600;
    uint24 public constant LP_FEE = 12500;
    int24 public constant TICK_SPACING = 60;
    uint160 public constant FLAGS = 0x20c4;
    /// @notice An observation must find this share of the manager's NUKE (outside hook claims) for sale: 0.25%.
    uint256 public constant DEPTH_DIVISOR = 400;
    /// @notice An observation may sit at most this far on the cheap side of the last completed hour's mean.
    int24 public constant BAND_TICKS = 2000;
    /// @notice A batch filling less than this share of its budget leaves the interval open: 1%.
    uint256 public constant MIN_FILL_DIVISOR = 100;
    uint256 private constant MAX_WALK_STEPS = 16;
    uint256 private constant Q96 = 1 << 96;
    // floor(sqrt(1.03) * 2**96); rounding makes both directional limits conservative.
    uint256 private constant SQRT_103_X96 = 80407803025877290703249465302;

    IPoolManager public immutable poolManager;
    Currency public immutable token;
    PoolId public immutable poolId;
    bool public immutable tokenIs0;
    bool public initialized;
    uint256 public lastBatch;
    bool private busy;
    uint8 private operation;

    /// @dev Exact tick integral for launch-aligned hourly windows. Fits in one storage slot.
    struct Oracle {
        uint64 epochStart;
        uint64 observedAt;
        int24 tick;
        int24 meanTick;
        int64 integral;
    }
    Oracle private oracle;

    error OnlyPoolManager();
    error InvalidDeployment();
    error InvalidPool();
    error NotInitialized();
    error UnrepresentableFee();
    error BatchTooSoon();
    error ManagerBusy();
    error UnexpectedUnlock();
    error EmptyBatch();

    event FeeAccrued(Currency indexed currency, uint256 amount);
    event Swept(uint256 amount);
    event BatchExecuted(uint256 budget, uint256 spent, uint256 burned, uint160 priceLimit);

    constructor(IPoolManager manager, address launchToken) {
        if (address(manager).code.length == 0 || launchToken.code.length == 0 || launchToken == IMD) {
            revert InvalidDeployment();
        }
        poolManager = manager;
        token = Currency.wrap(launchToken);
        tokenIs0 = launchToken < IMD;
        poolId = poolKey().toId();
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    modifier standalone() {
        if (busy || poolManager.isUnlocked()) revert ManagerBusy();
        busy = true;
        _;
        busy = false;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.afterSwapReturnDelta = true;
    }

    function poolKey() public view returns (PoolKey memory) {
        return PoolKey({
            currency0: tokenIs0 ? token : Currency.wrap(IMD),
            currency1: tokenIs0 ? Currency.wrap(IMD) : token,
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(this))
        });
    }

    function beforeInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        onlyPoolManager
        returns (bytes4)
    {
        if (initialized || PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert InvalidPool();
        initialized = true;
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        oracle = Oracle(uint64(block.timestamp), uint64(block.timestamp), tick, tick, 0);
        // Also enforces a full observation hour before the first batch.
        lastBatch = block.timestamp;
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata params, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // No reserve and no LP fee override. Reject only the unrepresentable int256 domain.
        uint256 magnitude =
            params.amountSpecified < 0 ? uint256(-(params.amountSpecified + 1)) + 1 : uint256(params.amountSpecified);
        if (magnitude > uint256(type(int256).max) - magnitude / 100) revert UnrepresentableFee();
        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        _observe();
        // Core skips self-callbacks; retain the explicit exemption for clarity.
        if (sender == address(this)) return (IHooks.afterSwap.selector, 0);
        bool unspecifiedIs0 = (params.amountSpecified < 0) != params.zeroForOne;
        int256 filled = unspecifiedIs0 ? int256(delta.amount0()) : int256(delta.amount1());
        uint256 fee = uint256(filled < 0 ? -filled : filled) * FEE_BPS / 10_000;
        if (fee != 0) {
            Currency currency = unspecifiedIs0 ? key.currency0 : key.currency1;
            poolManager.mint(address(this), currency.toId(), fee);
            emit FeeAccrued(currency, fee);
        }
        return (IHooks.afterSwap.selector, int128(int256(fee)));
    }

    /// @notice Accrued IMD, including donations and ERC-6909 claims.
    function pending() public view returns (uint256) {
        return poolManager.balanceOf(address(this), uint160(IMD)) + Currency.wrap(IMD).balanceOfSelf();
    }

    /// @notice NUKE awaiting transfer to DEAD, including donations and ERC-6909 claims.
    function pendingBurn() public view returns (uint256) {
        return poolManager.balanceOf(address(this), token.toId()) + token.balanceOfSelf();
    }

    /// @notice Sqrt price X96 from the time-weighted mean observed tick in the last completed hour.
    /// @dev Observations are the price at which observationDepth() NUKE was purchasable, each at most
    /// BAND_TICKS on the cheap side of the previous mean. During warmup this reports the initial
    /// tick price; batches cannot run yet.
    function referencePrice() public view returns (uint160) {
        if (!initialized) return 0;
        return TickMath.getSqrtPriceAtTick(_projectOracle().meanTick);
    }

    /// @notice The tick currently accruing time in the hourly integral: the last observation after its band clamp.
    function observedTick() external view returns (int24) {
        return oracle.tick;
    }

    /// @notice NUKE an observation must find purchasable: 0.25% of the manager's NUKE outside the hook's claims.
    /// @dev Inside afterSwap the swapper has not settled yet, so the balance is the pre-swap one.
    function observationDepth() public view returns (uint256) {
        uint256 held = token.balanceOf(address(poolManager));
        uint256 claims = poolManager.balanceOf(address(this), token.toId());
        return (held > claims ? held - claims : 0) / DEPTH_DIVISOR;
    }

    /// @notice Sqrt price after buying observationDepth() NUKE from the pool's current state.
    /// @dev Walks initialized ticks in the buying direction, as the swap loop would, for at most
    /// MAX_WALK_STEPS. A spot that cannot sell that depth nearby (an empty region, or a dust position
    /// with nothing behind it) is not an executable price and reports found = false.
    function askPrice() public view returns (uint160 sqrtPriceX96, bool found) {
        uint256 need = observationDepth();
        if (need == 0) return (0, false);
        (uint160 sqrtP, int24 tick,,) = poolManager.getSlot0(poolId);
        uint128 liquidity = poolManager.getLiquidity(poolId);
        for (uint256 step; step < MAX_WALK_STEPS; ++step) {
            (int24 next, bool crossing) = _nextTick(tick);
            if (next < TickMath.MIN_TICK) next = TickMath.MIN_TICK;
            if (next > TickMath.MAX_TICK) next = TickMath.MAX_TICK;
            uint160 sqrtNext = TickMath.getSqrtPriceAtTick(next);
            if (liquidity != 0) {
                uint256 avail = tokenIs0
                    ? SqrtPriceMath.getAmount0Delta(sqrtP, sqrtNext, liquidity, false)
                    : SqrtPriceMath.getAmount1Delta(sqrtNext, sqrtP, liquidity, false);
                if (avail >= need) {
                    sqrtPriceX96 = tokenIs0
                        ? SqrtPriceMath.getNextSqrtPriceFromAmount0RoundingUp(sqrtP, liquidity, need, false)
                        : SqrtPriceMath.getNextSqrtPriceFromAmount1RoundingDown(sqrtP, liquidity, need, false);
                    if (sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) sqrtPriceX96 = TickMath.MAX_SQRT_PRICE - 1;
                    return (sqrtPriceX96, true);
                }
                need -= avail;
            }
            if (tokenIs0 ? next >= TickMath.MAX_TICK : next <= TickMath.MIN_TICK) break;
            sqrtP = sqrtNext;
            if (crossing) {
                (, int128 net) = poolManager.getTickLiquidity(poolId, next);
                liquidity = LiquidityMath.addDelta(liquidity, tokenIs0 ? net : -net);
            }
            tick = tokenIs0 ? next : next - 1;
        }
        return (0, false);
    }

    /// @notice Maximum adverse 3% movement from both the reference and the executable spot price.
    function batchPriceLimit() public view returns (uint160) {
        uint160 ref = referencePrice();
        if (ref == 0) return 0;
        // Only a spot that can actually sell the observation depth is an executable market price,
        // and it may only tighten the hourly bound, never relax it. An empty region or a dust
        // position does not count, so a batch can still cross it into real liquidity.
        (uint160 ask, bool found) = askPrice();
        if (found && (tokenIs0 ? ask < ref : ask > ref)) ref = ask;
        uint256 limit =
            tokenIs0 ? FullMath.mulDiv(ref, SQRT_103_X96, Q96) : FullMath.mulDivRoundingUp(ref, Q96, SQRT_103_X96);
        if (limit <= TickMath.MIN_SQRT_PRICE) return TickMath.MIN_SQRT_PRICE + 1;
        if (limit >= TickMath.MAX_SQRT_PRICE) return TickMath.MAX_SQRT_PRICE - 1;
        return uint160(limit);
    }

    /// @notice Anyone may redeem NUKE claims and transfer all held NUKE to DEAD.
    function sweep() external standalone returns (uint256 burned) {
        operation = 1;
        burned = abi.decode(poolManager.unlock(""), (uint256));
        operation = 0;
        emit Swept(burned);
    }

    /// @notice Spend at most 25% of pending IMD; leave unfilled input available for later batches.
    /// @dev Empty budgets or a spot price already beyond the limit are harmless no-ops.
    function executeBatch() external standalone returns (uint256 spent, uint256 burned) {
        if (!initialized) revert NotInitialized();
        if (block.timestamp - lastBatch < BATCH_INTERVAL) revert BatchTooSoon();
        uint256 budget = pending() / 4;
        // Core's BalanceDelta is int128. A smaller batch is always within the 25% cap.
        if (budget > uint256(uint128(type(int128).max))) budget = uint256(uint128(type(int128).max));
        if (budget == 0) return (0, 0);
        _observe();
        uint160 limit = batchPriceLimit();
        (uint160 spot,,,) = poolManager.getSlot0(poolId);
        if (tokenIs0 ? spot >= limit : spot <= limit) return (0, 0);
        operation = 2;
        try poolManager.unlock(abi.encode(budget, limit)) returns (bytes memory result) {
            (spent, burned) = abi.decode(result, (uint256, uint256));
        } catch (bytes memory reason) {
            // Roll back a swap that bought nothing, including any rounded input fee.
            // Other manager/settlement failures must still propagate to the caller.
            if (reason.length != 4 || bytes4(reason) != EmptyBatch.selector) {
                assembly ("memory-safe") { revert(add(reason, 32), mload(reason)) }
            }
            operation = 0;
            return (0, 0);
        }
        operation = 0;
        // A fill below 1% of the budget is dust parked inside the limit, not a batch: it keeps what it
        // bought but leaves the hourly slot available, so no cheap fill can consume the interval.
        if (spent * MIN_FILL_DIVISOR >= budget) lastBatch = block.timestamp;
        emit BatchExecuted(budget, spent, burned, limit);
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        if (!busy) revert UnexpectedUnlock();
        if (operation == 1) {
            uint256 claims = poolManager.balanceOf(address(this), token.toId());
            if (claims != 0) {
                poolManager.burn(address(this), token.toId(), claims);
                poolManager.take(token, DEAD, claims);
            }
            uint256 held = token.balanceOfSelf();
            if (held != 0) token.transfer(DEAD, held);
            return abi.encode(claims + held);
        }
        if (operation != 2) revert UnexpectedUnlock();
        (uint256 budget, uint160 limit) = abi.decode(data, (uint256, uint160));
        BalanceDelta delta = poolManager.swap(poolKey(), SwapParams(!tokenIs0, -int256(budget), limit), "");
        uint256 spent = uint256(-int256(tokenIs0 ? delta.amount1() : delta.amount0()));
        uint256 bought = uint256(int256(tokenIs0 ? delta.amount0() : delta.amount1()));
        if (bought == 0) revert EmptyBatch();
        Currency pair = Currency.wrap(IMD);
        uint256 pairClaims = poolManager.balanceOf(address(this), pair.toId());
        uint256 fromClaims = spent < pairClaims ? spent : pairClaims;
        if (fromClaims != 0) poolManager.burn(address(this), pair.toId(), fromClaims);
        if (spent > fromClaims) {
            poolManager.sync(pair);
            pair.transfer(address(poolManager), spent - fromClaims);
            poolManager.settle();
        }
        if (bought != 0) poolManager.take(token, DEAD, bought);
        // PoolManager deliberately skips hooks on swaps initiated by that hook.
        _observe();
        return abi.encode(spent, bought);
    }

    function _observe() private {
        Oracle memory next = _projectOracle();
        // Observe the price at which the observation depth is actually purchasable. Preserve the
        // previous observation when nothing of that size is for sale nearby: moving the spot through
        // empty ticks or into a dust position fills nothing and must not influence future windows.
        (uint160 ask, bool found) = askPrice();
        int24 tick = found ? TickMath.getTickAtSqrtPrice(ask) : next.tick;
        // One observation may move at most BAND_TICKS below the completed hour's mean, so a single
        // block at a cheap tick cannot shift the next reference by the whole 3% limit.
        int24 cheapest = tokenIs0 ? next.meanTick - BAND_TICKS : next.meanTick + BAND_TICKS;
        if (tokenIs0 ? tick < cheapest : tick > cheapest) tick = cheapest;
        next.tick = tick;
        oracle = next;
    }

    /// @dev TickBitmap.nextInitializedTickWithinOneWord over extsload, searching in the NUKE-buying direction.
    function _nextTick(int24 tick) private view returns (int24 next, bool crossing) {
        unchecked {
            int24 compressed = TickBitmap.compress(tick, TICK_SPACING);
            if (tokenIs0) {
                (int16 wordPos, uint8 bitPos) = TickBitmap.position(++compressed);
                uint256 masked = poolManager.getTickBitmap(poolId, wordPos) & ~((uint256(1) << bitPos) - 1);
                crossing = masked != 0;
                next = crossing
                    ? (compressed + int24(uint24(BitMath.leastSignificantBit(masked) - bitPos))) * TICK_SPACING
                    : (compressed + int24(uint24(type(uint8).max - bitPos))) * TICK_SPACING;
            } else {
                (int16 wordPos, uint8 bitPos) = TickBitmap.position(compressed);
                uint256 masked = poolManager.getTickBitmap(poolId, wordPos)
                    & (type(uint256).max >> (uint256(type(uint8).max) - bitPos));
                crossing = masked != 0;
                next = crossing
                    ? (compressed - int24(uint24(bitPos - BitMath.mostSignificantBit(masked)))) * TICK_SPACING
                    : (compressed - int24(uint24(bitPos))) * TICK_SPACING;
            }
        }
    }

    /// @dev Splits elapsed time at hourly boundaries in O(1), even after years of inactivity.
    /// Only the PREVIOUS tick receives elapsed time; a same-block swap has zero weight.
    function _projectOracle() private view returns (Oracle memory o) {
        o = oracle;
        uint256 boundary = uint256(o.epochStart) + BATCH_INTERVAL;
        if (block.timestamp < boundary) {
            o.integral += int64(int256(o.tick) * int256(block.timestamp - o.observedAt));
        } else {
            int256 integral = int256(o.integral) + int256(o.tick) * int256(boundary - o.observedAt);
            int256 mean = integral / int256(BATCH_INTERVAL);
            // Round toward negative infinity, as in Uniswap's tick TWAP convention.
            if (integral < 0 && integral % int256(BATCH_INTERVAL) != 0) --mean;
            o.meanTick = int24(mean);
            uint256 newStart = boundary + ((block.timestamp - boundary) / BATCH_INTERVAL) * BATCH_INTERVAL;
            if (newStart > boundary) o.meanTick = o.tick;
            o.epochStart = uint64(newStart);
            o.integral = int64(int256(o.tick) * int256(block.timestamp - newStart));
        }
        o.observedAt = uint64(block.timestamp);
    }
}
