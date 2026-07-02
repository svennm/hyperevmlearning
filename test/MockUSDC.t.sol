// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../src/MockUSDC.sol";

contract MockUSDCTest is Test {
    MockUSDC usdc;
    function setUp() public { usdc = new MockUSDC(); }

    function test_decimalsIsSix() public view { assertEq(usdc.decimals(), 6); }
    function test_mint() public {
        usdc.mint(address(0xBEEF), 1_000_000); // 1 USDC
        assertEq(usdc.balanceOf(address(0xBEEF)), 1_000_000);
    }
}
