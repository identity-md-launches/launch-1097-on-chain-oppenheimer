// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {NUKE} from "../../src/NUKE.sol";
import {NUKEHook} from "../../src/NUKEHook.sol";
import {PoolActor} from "./PoolActor.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TestPair is ERC20 {
    constructor() ERC20("Test pair", "IMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

abstract contract HookFixture is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint160 internal constant Q96 = 1 << 96;
    uint128 internal constant LIQUIDITY = 1_000_000 ether;
    bytes32 internal constant SWAP_EVENT =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    IPoolManager internal manager;
    NUKE internal nuke;
    NUKEHook internal hook;
    PoolActor internal actor;
    PoolKey internal key;
    uint256 internal start;

    function _local(bool tokenAbove) internal {
        manager = IPoolManager(address(new PoolManager(address(this))));
        vm.etch(IMD, address(new TestPair()).code);
        TestPair(IMD).mint(address(this), 1_000_000_000 ether);
        _launch(tokenAbove);
    }

    function _launch(bool tokenAbove) internal {
        // Both orderings use genuine constructor-deployed tokens.
        do {
            nuke = new NUKE();
        } while ((address(nuke) > IMD) != tokenAbove);
        hook = _deployHook(address(nuke));
        actor = new PoolActor(manager);
        nuke.approve(address(actor), type(uint256).max);
        IERC20(IMD).approve(address(actor), type(uint256).max);
        key = hook.poolKey();
        start = block.timestamp;
        manager.initialize(key, Q96);
        actor.liquidity(key, ModifyLiquidityParams(-12000, 12000, int256(uint256(LIQUIDITY)), bytes32(0)));
    }

    function _deployHook(address t) internal returns (NUKEHook result) {
        bytes memory init = abi.encodePacked(type(NUKEHook).creationCode, abi.encode(manager, t));
        bytes32 hash = keccak256(init);
        for (uint256 i; i < 300_000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hash)))));
            if (uint160(predicted) & 0x3fff != 0x20c4 || predicted.code.length != 0) continue;
            address deployed;
            assembly ("memory-safe") { deployed := create2(0, add(init, 32), mload(init), salt) }
            require(deployed == predicted, "CREATE2 failed");
            return NUKEHook(deployed);
        }
        revert("salt search exhausted");
    }

    function _swap(bool buy, bool exactInput, uint256 amount, bool limited)
        internal
        returns (BalanceDelta raw, BalanceDelta net)
    {
        bool zeroForOne = buy != hook.tokenIs0();
        (uint160 spot, int24 tick,,) = manager.getSlot0(key.toId());
        uint160 limit = limited
            ? TickMath.getSqrtPriceAtTick(tick + (zeroForOne ? int24(-10) : int24(10)))
            : (zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
        require(zeroForOne ? limit < spot : limit > spot);
        SwapParams memory params = SwapParams(zeroForOne, exactInput ? -int256(amount) : int256(amount), limit);
        uint256 pendingBefore = hook.pending();
        uint256 burnBefore = hook.pendingBurn();
        uint256 balance0 = key.currency0.balanceOf(address(this));
        uint256 balance1 = key.currency1.balanceOf(address(this));
        vm.recordLogs();
        net = actor.swap(key, params);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_EVENT) {
                (int128 a0, int128 a1,,,, uint24 fee) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                raw = toBalanceDelta(a0, a1);
                assertEq(fee, 12500, "LP fee changed");
                found = true;
            }
        }
        assertTrue(found, "real manager swap missing");
        bool unspecified0 = exactInput != zeroForOne;
        int256 filled = unspecified0 ? raw.amount0() : raw.amount1();
        uint256 feeAmount = uint256(filled < 0 ? -filled : filled) / 100;
        assertEq(int256(net.amount0()), int256(raw.amount0()) - (unspecified0 ? int256(feeAmount) : int256(0)));
        assertEq(int256(net.amount1()), int256(raw.amount1()) - (unspecified0 ? int256(0) : int256(feeAmount)));
        bool feeInToken = unspecified0 == hook.tokenIs0();
        assertEq(hook.pending() - pendingBefore, feeInToken ? 0 : feeAmount);
        assertEq(hook.pendingBurn() - burnBefore, feeInToken ? feeAmount : 0);
        assertEq(int256(key.currency0.balanceOf(address(this))) - int256(balance0), int256(net.amount0()));
        assertEq(int256(key.currency1.balanceOf(address(this))) - int256(balance1), int256(net.amount1()));
        uint256 specifiedFill = _abs(unspecified0 ? raw.amount1() : raw.amount0());
        if (limited) assertLt(specifiedFill, amount, "not a limited fill");
        else assertEq(specifiedFill, amount, "full fill expected");
        _settled();
    }

    /// @dev The tick the hook records for the current pool state: where observationDepth() NUKE is purchasable.
    function _observedTick() internal view returns (int24) {
        (uint160 ask, bool found) = hook.askPrice();
        require(found, "no observable ask at this spot");
        return TickMath.getTickAtSqrtPrice(ask);
    }

    function _settled() internal view {
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency1), 0);
        assertFalse(manager.isUnlocked());
    }

    function _abs(int128 a) internal pure returns (uint256) {
        return uint256(a < 0 ? -int256(a) : int256(a));
    }
}
