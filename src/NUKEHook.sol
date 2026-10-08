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

    /// @notice Sqrt price X96 from the geometric mean tick in the last completed hour.
    /// @dev During warmup this reports the initial tick price; batches cannot run yet.
    function referencePrice() public view returns (uint160) {
        if (!initialized) return 0;
        return TickMath.getSqrtPriceAtTick(_projectOracle().meanTick);
    }

    /// @notice Maximum adverse 3% movement from both the reference and the liquid spot price.
    function batchPriceLimit() public view returns (uint160) {
        uint160 ref = referencePrice();
        if (ref == 0) return 0;
        // An empty-region tick is freely movable and is not an executable market price.
        // Otherwise spot may only tighten the hourly bound, never relax it.
        if (poolManager.getLiquidity(poolId) != 0) {
            (uint160 spot,,,) = poolManager.getSlot0(poolId);
            if (tokenIs0 ? spot < ref : spot > ref) ref = spot;
        }
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
        lastBatch = block.timestamp;
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
        // Preserve the previous observation when a swap ends outside active liquidity.
        // Moving through empty ticks fills nothing and must not influence future windows.
        if (poolManager.getLiquidity(poolId) != 0) (, next.tick,,) = poolManager.getSlot0(poolId);
        oracle = next;
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
