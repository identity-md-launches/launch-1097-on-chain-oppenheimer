// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {ClaimActor} from "./helpers/ClaimActor.sol";

/// @notice Opt in via forge test --fork-url <RPC> --fork-block-number <block>.
/// @dev No env reads, URL, keys or live network requirement in the default suite.
contract MainnetForkTest is HookFixture {
    using StateLibrary for IPoolManager;

    function setUp() public {
        try vm.activeFork() returns (uint256) {}
        catch {
            vm.skip(true);
            return;
        }
        require(block.chainid == 1, "Ethereum mainnet required");
        manager = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
        require(address(manager).code.length != 0 && IMD.code.length != 0, "use a block after both deployments");
        assertEq(IERC20Metadata(IMD).decimals(), 18);
        assertEq(IERC20Metadata(IMD).symbol(), "IMD");
        deal(IMD, address(this), 1_000_000_000 ether);
        _launch(false);
    }

    function test_mainnetAllDirectionsAndPartialFills() public {
        for (uint256 i; i < 8; i++) {
            _swap(i & 1 != 0, i & 2 != 0, i < 4 ? 1000 ether : 100_000 ether, i >= 4);
        }
    }

    function test_mainnetBatchAndBurn() public {
        _swap(false, true, 10_000 ether, false);
        _swap(true, true, 1000 ether, false);
        uint256 fees = hook.pendingBurn();
        assertGt(fees, 0);
        assertEq(hook.sweep(), fees);
        assertEq(nuke.balanceOf(DEAD), fees);
        uint256 paired = hook.pending();
        vm.warp(start + 3600);
        (uint256 spent, uint256 burned) = hook.executeBatch();
        assertGt(spent, 0);
        assertLe(spent, paired / 4);
        assertEq(nuke.balanceOf(DEAD), fees + burned);
        assertEq(hook.pending(), paired - spent);
        _settled();
    }

    function test_mainnetClaimDonationPartiallySpentThenRetried() public {
        ClaimActor claims = new ClaimActor(manager);
        IERC20(IMD).approve(address(claims), type(uint256).max);
        // Real IMD backs these manager claims; no storage fabrication of claim balances.
        claims.deposit(Currency.wrap(IMD), 1_000_000 ether, address(hook));
        nuke.transfer(address(hook), 7 ether);
        assertEq(hook.pending(), 1_000_000 ether);
        assertEq(hook.sweep(), 7 ether);
        vm.warp(start + 3600);
        uint160 limit = hook.batchPriceLimit();
        (uint256 spent, uint256 burned) = hook.executeBatch();
        assertGt(spent, 0);
        assertLt(spent, 250_000 ether, "must exercise a partial batch");
        assertGt(burned, 0);
        (uint160 spot,,,) = manager.getSlot0(key.toId());
        assertEq(spot, limit);
        assertEq(hook.pending(), 1_000_000 ether - spent);
        assertEq(manager.balanceOf(address(hook), uint160(IMD)), hook.pending());
        assertEq(nuke.balanceOf(DEAD), 7 ether + burned);
        vm.warp(start + 7200);
        (uint256 nextSpent, uint256 nextBurned) = hook.executeBatch();
        assertGt(nextSpent, 0, "remaining claims must be reusable");
        assertGt(nextBurned, 0);
        assertEq(hook.pending(), 1_000_000 ether - spent - nextSpent);
        assertEq(nuke.balanceOf(DEAD), 7 ether + burned + nextBurned);
        _settled();
    }
}
