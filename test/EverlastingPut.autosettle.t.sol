// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {Test} from "forge-std/Test.sol";
import {EverlastingMarket} from "../src/EverlastingMarket.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockOracle} from "../src/MockOracle.sol";

contract PutAutoSettleTest is Test {
    EverlastingMarket put; MockUSDC usdc; MockOracle oracle;
    address trader = address(0xA11CE);
    function setUp() public {
        usdc = new MockUSDC(); oracle = new MockOracle();
        put = new EverlastingMarket(usdc, oracle, EverlastingMarket.Side.PUT, 48e18, 48e18, address(this));
        oracle.set(48e18);
        usdc.mint(address(this), 1_000_000e6); usdc.approve(address(put), type(uint256).max);
        put.lpDeposit(500_000e6); put.postMark(6e18);
        usdc.mint(trader, 1_000e6);
        vm.prank(trader); usdc.approve(address(put), type(uint256).max);
        vm.prank(trader); put.deposit(48e6);
        vm.prank(trader); put.openLong(1e18);
    }
    function test_settle_revertsWhenSolvent() public {
        vm.expectRevert(bytes("solvent"));
        put.settle(trader);
    }
    function test_settle_closesWhenFundingExceedsCollateral() public {
        // accrue many periods of funding > 48 collateral (6/period → >8 periods)
        for (uint256 i = 0; i < 9; i++) { vm.warp(block.timestamp + 3600); put.postMark(6e18); }
        assertGt(put.pendingFunding(trader) / 1e12, put.traderCollateral(trader));
        put.settle(trader); // anyone
        (uint256 q,,) = put.positions(trader); assertEq(q, 0);
        assertEq(put.traderCollateral(trader), 0); // drained to pool
        assertEq(put.poolLocked(), 0);
    }
}
