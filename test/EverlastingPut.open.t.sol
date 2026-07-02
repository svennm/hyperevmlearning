// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {Test} from "forge-std/Test.sol";
import {EverlastingMarket} from "../src/EverlastingMarket.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockOracle} from "../src/MockOracle.sol";

contract PutOpenTest is Test {
    EverlastingMarket put; MockUSDC usdc; MockOracle oracle;
    address trader = address(0xA11CE);
    function setUp() public {
        usdc = new MockUSDC(); oracle = new MockOracle();
        put = new EverlastingMarket(usdc, oracle, EverlastingMarket.Side.PUT, 48e18, 48e18, address(this));
        oracle.set(48e18);
        // LP funds pool
        usdc.mint(address(this), 100_000e6); usdc.approve(address(put), type(uint256).max);
        put.lpDeposit(100_000e6);
        put.postMark(6e18); // ATM put ~ time value; mark <= K holds
        // trader funds margin
        usdc.mint(trader, 100_000e6);
        vm.prank(trader); usdc.approve(address(put), type(uint256).max);
    }
    function test_openLong_locksEscrowAndIM() public {
        vm.startPrank(trader);
        put.deposit(48e6);           // IM for qty=1 put = K = $48
        put.openLong(1e18);          // 1 put
        vm.stopPrank();
        (uint256 qty,,) = put.positions(trader);
        assertEq(qty, 1e18);
        assertEq(put.poolLocked(), 48e6);          // escrow = qty*K
        assertEq(put.traderCollateral(trader), 48e6);
    }
    function test_openLong_revertsInsufficientIM() public {
        vm.startPrank(trader);
        put.deposit(10e6);
        vm.expectRevert(bytes("open: IM"));
        put.openLong(1e18);
        vm.stopPrank();
    }
    function test_openLong_revertsPoolCantCover() public {
        // drain pool below one escrow
        put.lpWithdraw(100_000e6 - 10e6);
        vm.startPrank(trader);
        put.deposit(48e6);
        vm.expectRevert(bytes("open: pool escrow"));
        put.openLong(1e18);
        vm.stopPrank();
    }

    // AUDIT F6: trader withdraw() coverage
    function test_withdraw_happyPath() public {
        vm.startPrank(trader);
        put.deposit(48e6);
        put.withdraw(20e6);
        vm.stopPrank();
        assertEq(put.traderCollateral(trader), 28e6);
        assertEq(usdc.balanceOf(trader), 100_000e6 - 48e6 + 20e6);
    }
    function test_withdraw_revertsWithOpenPosition() public {
        vm.startPrank(trader);
        put.deposit(48e6);
        put.openLong(1e18);
        vm.expectRevert(bytes("close first"));
        put.withdraw(1e6);
        vm.stopPrank();
    }
    function test_withdraw_revertsInsufficient() public {
        vm.startPrank(trader);
        put.deposit(10e6);
        vm.expectRevert(bytes("insufficient"));
        put.withdraw(20e6);
        vm.stopPrank();
    }

    // AUDIT F5: opens are paused while the mark is stale (close/settle are NOT gated)
    function test_openLong_revertsWhenMarkStale() public {
        vm.warp(block.timestamp + put.MAX_MARK_AGE() + 1);
        vm.startPrank(trader);
        put.deposit(48e6);
        vm.expectRevert(bytes("stale mark"));
        put.openLong(1e18);
        vm.stopPrank();
    }
}
