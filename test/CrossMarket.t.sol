// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {Test} from "forge-std/Test.sol";
import {EverlastingMarket} from "../src/EverlastingMarket.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockOracle} from "../src/MockOracle.sol";

contract CrossMarketTest is Test {
    EverlastingMarket put; EverlastingMarket call_; MockUSDC usdc; MockOracle oracle;
    address trader = address(0xA11CE);
    function setUp() public {
        usdc = new MockUSDC(); oracle = new MockOracle(); oracle.set(48e18);
        put  = new EverlastingMarket(usdc, oracle, EverlastingMarket.Side.PUT, 48e18, 48e18, address(this));
        call_= new EverlastingMarket(usdc, oracle, EverlastingMarket.Side.CALL, 48e18, 6e18, address(this));
        usdc.mint(address(this), 2_000_000e6); usdc.approve(address(put), type(uint256).max); usdc.approve(address(call_), type(uint256).max);
        put.lpDeposit(500_000e6); call_.lpDeposit(500_000e6);
        put.postMark(6e18); call_.postMark(1e18);
        usdc.mint(trader, 200_000e6);
        vm.startPrank(trader); usdc.approve(address(put), type(uint256).max); usdc.approve(address(call_), type(uint256).max); vm.stopPrank();
    }
    function test_hedgeBothDirections_isolatedPools() public {
        vm.startPrank(trader);
        put.deposit(48e6);  put.openLong(1e18);     // downside hedge
        call_.deposit(6e6); call_.openLong(1e18);   // upside hedge (capped)
        vm.stopPrank();
        // one funding period
        vm.warp(block.timestamp + 3600); put.postMark(6e18); call_.postMark(1e18);
        vm.startPrank(trader); put.close(); call_.close(); vm.stopPrank();
        // each market conserves independently (isolated pools)
        uint256 sP = put.traderCollateral(trader) + put.traderCollateral(address(this));
        uint256 sC = call_.traderCollateral(trader) + call_.traderCollateral(address(this));
        assertEq(usdc.balanceOf(address(put)),  put.poolFree()  + put.poolLocked()  + sP + put.feeAccrued());
        assertEq(usdc.balanceOf(address(call_)),call_.poolFree()+ call_.poolLocked()+ sC + call_.feeAccrued());
    }
}
