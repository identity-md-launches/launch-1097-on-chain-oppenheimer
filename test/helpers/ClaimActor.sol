// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NUKEHook} from "src/NUKEHook.sol";

/// @dev A test router that can settle using backed ERC-6909 claims instead of wallet tokens.
contract ClaimActor is IUnlockCallback {
    IPoolManager public immutable manager;
    uint256 public pairReserveBeforeSettlement;
    uint256 public pairFeesBeforeSettlement;
    uint256 public tokenFeesBeforeSettlement;

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
        (address payer, PoolKey memory key, SwapParams memory params, bool payClaims, bool takeClaims) =
            abi.decode(args, (address, PoolKey, SwapParams, bool, bool));
        BalanceDelta delta = manager.swap(key, params, "");
        NUKEHook hook = NUKEHook(address(key.hooks));
        pairReserveBeforeSettlement = IERC20(hook.IMD()).balanceOf(address(manager));
        pairFeesBeforeSettlement = hook.pending();
        tokenFeesBeforeSettlement = hook.pendingBurn();
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
