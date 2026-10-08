// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {NUKE} from "../src/NUKE.sol";

contract NUKETest is Test {
    NUKE token;

    function setUp() public {
        token = new NUKE();
    }

    function test_entireFixedSupplyBelongsToDeployer() public view {
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
        assertEq(token.decimals(), 18);
        assertEq(token.name(), "On-Chain Oppenheimer");
        assertEq(token.symbol(), "NUKE");
    }

    function test_factoryCanTransferAllAllocationsWithoutTax() public {
        address pool = makeAddr("pool recipient");
        address distributor = makeAddr("merkle distributor");
        token.transfer(pool, 9e26);
        token.transfer(distributor, 1e26);
        assertEq(token.balanceOf(pool), 9e26);
        assertEq(token.balanceOf(distributor), 1e26);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_noAdministrativeSupplyMutation() public {
        string[5] memory names = [
            "mint(address,uint256)",
            "setOwner(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "setMinter(address)"
        ];
        for (uint256 i; i < names.length; i++) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(names[i], address(this), 1 ether));
            assertFalse(ok);
            assertEq(token.totalSupply(), 1e27);
        }
    }

    function test_transferFailuresAndAllowance() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        vm.expectRevert();
        token.transfer(address(0), 1 ether);
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(bob, 1 ether);
        token.approve(alice, 42 ether);
        vm.prank(alice);
        token.transferFrom(address(this), bob, 42 ether);
        assertEq(token.balanceOf(bob), 42 ether);
        assertEq(token.allowance(address(this), alice), 0);
        vm.prank(alice);
        vm.expectRevert();
        token.transferFrom(address(this), bob, 1);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_conservation(uint256 amount) public {
        amount = bound(amount, 0, 1e27);
        address recipient = makeAddr("recipient");
        token.transfer(recipient, amount);
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(address(this)), 1e27 - amount);
        assertEq(token.totalSupply(), 1e27);
    }
}
