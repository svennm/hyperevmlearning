// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {Test} from "forge-std/Test.sol";
import {EverlastingPut} from "../src/EverlastingPut.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockOracle} from "../src/MockOracle.sol";

contract PutPoolTest is Test {
    EverlastingPut put; MockUSDC usdc; MockOracle oracle;
    function setUp() public {
        usdc = new MockUSDC(); oracle = new MockOracle();
        put = new EverlastingPut(usdc, oracle, 48e18, address(this));
        usdc.mint(address(this), 1_000e6);
        usdc.approve(address(put), type(uint256).max);
    }
    function test_lpDepositWithdraw() public {
        put.lpDeposit(500e6);
        assertEq(put.poolFree(), 500e6);
        assertEq(usdc.balanceOf(address(put)), 500e6);
        put.lpWithdraw(200e6);
        assertEq(put.poolFree(), 300e6);
        assertEq(usdc.balanceOf(address(this)), 700e6);
    }
    function test_lpWithdraw_revertsOverFree() public {
        put.lpDeposit(100e6);
        vm.expectRevert(bytes("pool: insufficient free"));
        put.lpWithdraw(200e6);
    }
}
