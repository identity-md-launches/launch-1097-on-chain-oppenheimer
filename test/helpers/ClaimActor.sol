// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NUKEHook} from "src/NUKEHook.sol";

/// @dev A test router that can settle using backed ERC-6909 claims instead of wallet tokens.
/// It also records the manager state the hook saw inside afterSwap (before the router settled),
/// and can probe, through the real swap engine, the price at which a given depth of NUKE is
/// purchasable: the probe swaps and then reverts its own unlock, so nothing persists.
contract ClaimActor is IUnlockCallback {
    using StateLibrary for IPoolManager;

    IPoolManager public immutable manager;
    uint256 public pairReserveBeforeSettlement;
    uint256 public pairFeesBeforeSettlement;
    uint256 public tokenFeesBeforeSettlement;
    /// @dev NUKE held by the manager when the hook observed; the swapper had not settled yet.
    uint256 public tokenHeldBeforeSettlement;
    /// @dev The hook's NUKE claims right after the swap, including the fee claim minted after its observation.
    uint256 public tokenClaimsBeforeSettlement;

    error Probe(uint160 sqrtPriceX96, uint256 bought);

    constructor(IPoolManager m) {
        manager = m;
    }

    function deposit(Currency currency, uint256 amount, address recipient) external {
        manager.unlock(abi.encode(uint8(0), abi.encode(msg.sender, currency, amount, recipient)));
    }

    function swap(PoolKey memory key, SwapParams memory params, bool payClaims, bool takeClaims)
        external
        returns (BalanceDelta)
    {
        return abi.decode(
            manager.unlock(abi.encode(uint8(1), abi.encode(msg.sender, key, params, payClaims, takeClaims))),
            (BalanceDelta)
        );
    }

    /// @notice Where the pool's price lands after buying exactly `depth` NUKE from its current state.
    /// @dev Runs the real swap engine, no price limit, then reverts the unlock. `filled` is false when
    /// the pool could not supply the whole depth, in which case the price is where the swap stopped.
    function probeAsk(PoolKey memory key, uint256 depth) external returns (uint160 sqrtPriceX96, bool filled) {
        if (depth == 0) return (0, false);
        (uint160 spot,,,) = manager.getSlot0(key.toId());
        bool buyIsZeroForOne = !NUKEHook(address(key.hooks)).tokenIs0();
        // Nothing lies beyond the legal price range, so a spot parked there has nothing for sale.
        if (buyIsZeroForOne ? spot <= TickMath.MIN_SQRT_PRICE + 1 : spot >= TickMath.MAX_SQRT_PRICE - 1) {
            return (0, false);
        }
        try manager.unlock(abi.encode(uint8(2), abi.encode(key, depth))) {
            revert("probe must not persist");
        } catch (bytes memory reason) {
            require(reason.length == 4 + 64 && bytes4(reason) == Probe.selector, "probe failed for another reason");
            uint256 bought;
            assembly ("memory-safe") {
                sqrtPriceX96 := mload(add(reason, 36))
                bought := mload(add(reason, 68))
            }
            filled = bought == depth;
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (uint8 operation, bytes memory args) = abi.decode(data, (uint8, bytes));
        if (operation == 0) {
            (address depositor, Currency currency, uint256 amount, address recipient) =
                abi.decode(args, (address, Currency, uint256, address));
            _pay(currency, depositor, amount);
            manager.mint(recipient, currency.toId(), amount);
            return "";
        }
        if (operation == 2) {
            (PoolKey memory probeKey, uint256 depth) = abi.decode(args, (PoolKey, uint256));
            NUKEHook probed = NUKEHook(address(probeKey.hooks));
            bool zeroForOne = !probed.tokenIs0();
            BalanceDelta probeDelta = manager.swap(
                probeKey,
                SwapParams(
                    zeroForOne, int256(depth), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                ),
                ""
            );
            (uint160 landed,,,) = manager.getSlot0(probeKey.toId());
            // The hook fee is charged on the unspecified (IMD) side, so the NUKE output is the raw fill.
            revert Probe(landed, uint256(int256(probed.tokenIs0() ? probeDelta.amount0() : probeDelta.amount1())));
        }
        (address payer, PoolKey memory key, SwapParams memory params, bool payClaims, bool takeClaims) =
            abi.decode(args, (address, PoolKey, SwapParams, bool, bool));
        BalanceDelta delta = manager.swap(key, params, "");
        NUKEHook hook = NUKEHook(address(key.hooks));
        pairReserveBeforeSettlement = IERC20(hook.IMD()).balanceOf(address(manager));
        pairFeesBeforeSettlement = hook.pending();
        tokenFeesBeforeSettlement = hook.pendingBurn();
        tokenHeldBeforeSettlement = IERC20(Currency.unwrap(hook.token())).balanceOf(address(manager));
        tokenClaimsBeforeSettlement = manager.balanceOf(address(hook), hook.token().toId());
        _settle(key.currency0, payer, delta.amount0(), payClaims, takeClaims);
        _settle(key.currency1, payer, delta.amount1(), payClaims, takeClaims);
        return abi.encode(delta);
    }

    function _settle(Currency c, address payer, int128 delta, bool payClaims, bool takeClaims) private {
        if (delta < 0) {
            uint256 amount = uint256(-int256(delta));
            if (payClaims) manager.burn(payer, c.toId(), amount);
            else _pay(c, payer, amount);
        } else if (delta > 0) {
            if (takeClaims) manager.mint(payer, c.toId(), uint128(delta));
            else manager.take(c, payer, uint128(delta));
        }
    }

    function _pay(Currency c, address payer, uint256 amount) private {
        manager.sync(c);
        require(IERC20(Currency.unwrap(c)).transferFrom(payer, address(manager), amount), "payment failed");
        manager.settle();
    }
}
