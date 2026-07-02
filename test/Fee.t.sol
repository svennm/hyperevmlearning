// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {Test} from "forge-std/Test.sol";
import {EverlastingMarket} from "../src/EverlastingMarket.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockOracle} from "../src/MockOracle.sol";

contract FeeTest is Test {
    EverlastingMarket p; MockUSDC usdc; MockOracle oracle;
    address trader = address(0xA11CE);
    function setUp() public {
        usdc = new MockUSDC(); oracle = new MockOracle(); oracle.set(48e18);
        p = new EverlastingMarket(usdc, oracle, EverlastingMarket.Side.PUT, 48e18, 48e18, address(this));
        usdc.mint(address(this), 1_000_000e6); usdc.approve(address(p), type(uint256).max);
        p.lpDeposit(500_000e6);
        p.setProtocolFeeBps(1000);               // 10%
        p.postMark(6e18);
        usdc.mint(trader, 100_000e6); vm.prank(trader); usdc.approve(address(p), type(uint256).max);
    }
    function test_setFee_ownerOnly() public {
        vm.prank(trader); vm.expectRevert(bytes("only owner")); p.setProtocolFeeBps(500);
    }
    function test_setFee_capEnforced() public {
        vm.expectRevert(bytes("fee too high")); p.setProtocolFeeBps(2001);
    }
    function test_fee_takes10pctOfFunding_onClose() public {
        vm.startPrank(trader); p.deposit(48e6); p.openLong(1e18); vm.stopPrank();
        // accrue 1 period of funding: f = mark - lastIntrinsic = 6 - 0 = 6 per unit
        vm.warp(block.timestamp + 3600); p.postMark(6e18);
        uint256 fundingU = 6e6;                  // qty=1 * 6 wad -> $6
        vm.prank(trader); p.close();
        assertEq(p.feeAccrued(), fundingU * 1000 / 10_000);  // $0.60
    }
    function test_conservation_includesFee() public {
        vm.startPrank(trader); p.deposit(48e6); p.openLong(1e18); vm.stopPrank();
        vm.warp(block.timestamp + 3600); p.postMark(6e18);
        vm.prank(trader); p.close();
        uint256 sum = p.traderCollateral(trader) + p.traderCollateral(address(this));
        assertEq(usdc.balanceOf(address(p)), p.poolFree() + p.poolLocked() + sum + p.feeAccrued());
    }
    function test_withdrawFees_ownerOnly() public {
        test_fee_takes10pctOfFunding_onClose();
        vm.prank(trader); vm.expectRevert(bytes("only owner")); p.withdrawFees(trader, 1);
        uint256 fa = p.feeAccrued(); p.withdrawFees(address(this), fa);
        assertEq(p.feeAccrued(), 0);
    }
}
