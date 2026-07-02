// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {Test} from "forge-std/Test.sol";
import {EverlastingMarket} from "../src/EverlastingMarket.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockOracle} from "../src/MockOracle.sol";

contract PutMathTest is Test {
    EverlastingMarket put; MockUSDC usdc; MockOracle oracle;
    function setUp() public {
        usdc = new MockUSDC(); oracle = new MockOracle();
        put = new EverlastingMarket(usdc, oracle, EverlastingMarket.Side.PUT, 48e18, 48e18, address(this)); // K=$48
    }
    function test_intrinsic_ITM() public { oracle.set(40e18); assertEq(put.intrinsicWad(), 8e18); }
    function test_intrinsic_OTM() public { oracle.set(60e18); assertEq(put.intrinsicWad(), 0); }
}
