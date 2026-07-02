// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {Test} from "forge-std/Test.sol";
import {EverlastingMarket} from "../src/EverlastingMarket.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockOracle} from "../src/MockOracle.sol";

contract PutCloseTest is Test {
    EverlastingMarket put; MockUSDC usdc; MockOracle oracle;
    address trader = address(0xA11CE);
    function setUp() public {
        usdc = new MockUSDC(); oracle = new MockOracle();
        put = new EverlastingMarket(usdc, oracle, EverlastingMarket.Side.PUT, 48e18, 48e18, address(this));
        oracle.set(48e18);
        usdc.mint(address(this), 1_000_000e6); usdc.approve(address(put), type(uint256).max);
        put.lpDeposit(500_000e6);
        put.postMark(6e18);
        usdc.mint(trader, 1_000e6);
        vm.prank(trader); usdc.approve(address(put), type(uint256).max);
        vm.prank(trader); put.deposit(48e6);
        vm.prank(trader); put.openLong(1e18);
    }
    function test_close_flatMark_traderPaysFunding() public {
        vm.warp(block.timestamp + 3600);
        put.postMark(6e18);                    // funding += 6 (time value), mark unchanged
        uint256 poolBefore = put.poolFree();
        vm.prank(trader); put.close();
        // trader owed funding = 1 * 6 = $6 → col 48 - 6 = 42; escrow released to pool
        assertEq(put.traderCollateral(trader), 42e6);
        assertEq(put.poolLocked(), 0);
        assertEq(put.poolFree(), poolBefore + 48e6 + 6e6); // escrow back + funding
        (uint256 q,,) = put.positions(trader); assertEq(q, 0);
    }
    function test_close_markRose_traderGainsFromPool() public {
        // HYPE drops → put more valuable → mark up (long profits), within dev/K bounds
        oracle.set(45e18);                     // intrinsic 3
        vm.warp(block.timestamp + 3600);
        put.postMark(7e18);                    // +16% ≤ 20%; funding used PRE mark (6-0)=6
        vm.prank(trader); put.close();
        // markPnL = 1*(7-6)=+$1 ; funding = 1*(6)=$6 → net -5 → col 43
        assertEq(put.traderCollateral(trader), 43e6);
    }
}
