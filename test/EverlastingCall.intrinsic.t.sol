// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {Test} from "forge-std/Test.sol";
import {EverlastingMarket} from "../src/EverlastingMarket.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockOracle} from "../src/MockOracle.sol";

contract CallIntrinsicTest is Test {
    EverlastingMarket call_; MockUSDC usdc; MockOracle oracle;
    uint256 constant K = 48e18; uint256 constant KHI = 54e18; uint256 constant W = KHI - K; // 6e18
    function setUp() public {
        usdc = new MockUSDC(); oracle = new MockOracle();
        call_ = new EverlastingMarket(usdc, oracle, EverlastingMarket.Side.CALL, K, W, address(this));
    }
    function test_call_otm_isZero() public { oracle.set(45e18); assertEq(call_.intrinsicWad(), 0); }
    function test_call_atk_isZero() public { oracle.set(48e18); assertEq(call_.intrinsicWad(), 0); }
    function test_call_inRamp() public { oracle.set(50e18); assertEq(call_.intrinsicWad(), 2e18); }
    function test_call_cappedAtW_atKhi() public { oracle.set(54e18); assertEq(call_.intrinsicWad(), W); }
    function test_call_cappedAtW_aboveKhi() public { oracle.set(80e18); assertEq(call_.intrinsicWad(), W); }
}
