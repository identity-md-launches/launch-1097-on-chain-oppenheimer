// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Test router: resolves every debt/credit against the actual caller's ERC-20 balances.
contract PoolActor is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager m) {
        manager = m;
    }

    function swap(PoolKey memory key, SwapParams memory params) external returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(uint8(0), msg.sender, key, abi.encode(params))), (BalanceDelta));
    }

    function liquidity(PoolKey memory key, ModifyLiquidityParams memory params) external returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(uint8(1), msg.sender, key, abi.encode(params))), (BalanceDelta));
    }

    function attemptDuringUnlock(address target, bytes memory callData) external returns (bytes memory) {
        return manager.unlock(
            abi.encode(
                uint8(2),
                target,
                PoolKey(Currency.wrap(address(0)), Currency.wrap(address(0)), 0, 0, IHooks(address(0))),
                callData
            )
        );
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (uint8 op, address payer, PoolKey memory key, bytes memory params) =
            abi.decode(data, (uint8, address, PoolKey, bytes));
        if (op == 2) {
            (bool ok, bytes memory result) = payer.call(params);
            return abi.encode(ok, result);
        }
        BalanceDelta delta;
        if (op == 0) delta = manager.swap(key, abi.decode(params, (SwapParams)), "");
        else (delta,) = manager.modifyLiquidity(key, abi.decode(params, (ModifyLiquidityParams)), "");
        _settle(key.currency0, payer, delta.amount0());
        _settle(key.currency1, payer, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, address payer, int128 delta) private {
        if (delta < 0) {
            manager.sync(currency);
            require(IERC20(Currency.unwrap(currency)).transferFrom(payer, address(manager), uint256(-int256(delta))));
            manager.settle();
        } else if (delta > 0) {
            manager.take(currency, payer, uint128(delta));
        }
    }
}

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
