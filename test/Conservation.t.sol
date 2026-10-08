// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {PoolActor} from "./helpers/PoolActor.sol";
import {NUKEHook} from "../src/NUKEHook.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ConservationHandler is Test {
    NUKEHook public immutable hook;
    PoolActor public immutable actor;
    IPoolManager public immutable manager;
    uint256 public imdFees;
    uint256 public nukeFees;
    uint256 public imdSpent;
    uint256 public nukeBought;
    uint256 public swaps;
    uint256 public batches;
    uint256 public sweeps;
    bytes32 private constant SWAP_EVENT = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    constructor(NUKEHook h, PoolActor a, IPoolManager m) {
        hook = h;
        actor = a;
        manager = m;
        IERC20(h.IMD()).approve(address(a), type(uint256).max);
        IERC20(Currency.unwrap(h.token())).approve(address(a), type(uint256).max);
    }

    function swap(bool buy, bool exactInput, uint80 amountSeed) external {
        uint256 amount = bound(uint256(amountSeed), 1e8, 500 ether);
        PoolKey memory key = hook.poolKey();
        bool zeroForOne = buy != hook.tokenIs0();
        vm.recordLogs();
        actor.swap(
            key,
            SwapParams(
                zeroForOne,
                exactInput ? -int256(amount) : int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            )
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_EVENT) {
                (int128 a0, int128 a1,,,,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                bool unspecified0 = exactInput != zeroForOne;
                int256 filled = unspecified0 ? a0 : a1;
                uint256 fee = uint256(filled < 0 ? -filled : filled) / 100;
                if (unspecified0 == hook.tokenIs0()) nukeFees += fee;
                else imdFees += fee;
            }
        }
        ++swaps;
    }

    function advanceAndBatch(uint16 secondsSeed) external {
        vm.warp(block.timestamp + bound(uint256(secondsSeed), 3600, 7200));
        (uint256 spent, uint256 bought) = hook.executeBatch();
        imdSpent += spent;
        nukeBought += bought;
        ++batches;
    }

    function sweep() external {
        hook.sweep();
        ++sweeps;
    }
}

contract ConservationTest is HookFixture {
    using TransientStateLibrary for IPoolManager;
    ConservationHandler handler;

    function setUp() public {
        _local(false);
        handler = new ConservationHandler(hook, actor, manager);
        nuke.transfer(address(handler), 1_000_000 ether);
        IERC20(IMD).transfer(address(handler), 1_000_000 ether);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.swap.selector;
        selectors[1] = handler.advanceAndBatch.selector;
        selectors[2] = handler.sweep.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_feesAreConservedAndNoDebtRemains() public view {
        assertEq(hook.pending() + handler.imdSpent(), handler.imdFees());
        assertEq(hook.pendingBurn() + nuke.balanceOf(DEAD), handler.nukeFees() + handler.nukeBought());
        assertEq(nuke.totalSupply(), 1e27);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
        assertEq(nuke.balanceOf(address(hook)), 0);
        assertEq(IERC20(IMD).balanceOf(address(hook)), 0);
    }
}
