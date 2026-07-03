// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {Test} from "forge-std/Test.sol";
import {EverlastingMarket} from "../src/EverlastingMarket.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockOracle} from "../src/MockOracle.sol";
import {MockYieldAdapter} from "../src/MockYieldAdapter.sol";

contract FloatTest is Test {
    EverlastingMarket p; MockUSDC usdc; MockOracle oracle; MockYieldAdapter ya;
    address trader = address(0xA11CE);
    function setUp() public {
        usdc = new MockUSDC(); oracle = new MockOracle(); oracle.set(48e18);
        p = new EverlastingMarket(usdc, oracle, EverlastingMarket.Side.PUT, 48e18, 48e18, address(this));
        ya = new MockYieldAdapter(usdc, address(p));
        usdc.mint(address(this), 2_000_000e6); usdc.approve(address(p), type(uint256).max);
        p.lpDeposit(100_000e6); p.postMark(6e18);
        p.setYieldAdapter(address(ya));
        usdc.mint(trader, 100_000e6); vm.prank(trader); usdc.approve(address(p), type(uint256).max);
    }
    function test_sweep_movesFreeAboveReserve() public {
        p.sweepToYield();
        assertEq(p.poolFree(), 100_000e6 * 2000 / 10_000);       // 20% reserve stays
        assertEq(p.deployedToYield(), 100_000e6 * 8000 / 10_000);// 80% out
        assertEq(ya.balance(), p.deployedToYield());
    }
    function test_floatNeverTouchesLockedOrTrader() public {
        vm.startPrank(trader); p.deposit(48e6); p.openLong(1e18); vm.stopPrank();  // locks $48 escrow
        p.setReserveBps(0);
        p.sweepToYield();
        // locked escrow + trader collateral remain fully in-contract:
        assertEq(usdc.balanceOf(address(p)), p.poolLocked() + p.traderCollateral(trader));
    }
    function test_harvest_routesYieldToFee() public {
        p.sweepToYield();
        usdc.mint(address(this), 500e6); usdc.approve(address(ya), 500e6); ya.accrue(500e6); // +$500 "interest"
        p.harvest();
        assertEq(p.feeAccrued(), 500e6);
        assertEq(ya.balance(), p.deployedToYield());             // only principal remains out
    }
    function test_ensureLiquidity_onLpWithdraw() public {
        p.sweepToYield();                                         // most capital out at yield
        p.lpWithdraw(90_000e6);                                   // exceeds in-contract poolFree -> pulls back
        assertEq(usdc.balanceOf(address(this)), 2_000_000e6 - 100_000e6 + 90_000e6);
    }
    function test_conservation_withFloat() public {
        vm.startPrank(trader); p.deposit(48e6); p.openLong(1e18); vm.stopPrank();
        p.sweepToYield();
        uint256 sum = p.traderCollateral(trader) + p.traderCollateral(address(this));
        // in-contract conservation (deployedToYield left the contract with poolFree):
        assertEq(usdc.balanceOf(address(p)), p.poolFree() + p.poolLocked() + sum + p.feeAccrued());
        assertGe(ya.balance(), p.deployedToYield());             // yield >= 0
    }
}
