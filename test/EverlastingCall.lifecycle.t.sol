// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {Test} from "forge-std/Test.sol";
import {EverlastingMarket} from "../src/EverlastingMarket.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockOracle} from "../src/MockOracle.sol";

contract CallLifecycleTest is Test {
    EverlastingMarket c; MockUSDC usdc; MockOracle oracle;
    uint256 constant K = 48e18; uint256 constant W = 6e18; // K_hi = 54
    address trader = address(0xA11CE);
    function setUp() public {
        usdc = new MockUSDC(); oracle = new MockOracle(); oracle.set(48e18);
        c = new EverlastingMarket(usdc, oracle, EverlastingMarket.Side.CALL, K, W, address(this));
        usdc.mint(address(this), 100_000e6); usdc.approve(address(c), type(uint256).max);
        c.lpDeposit(100_000e6);
        c.postMark(1e18);                       // time value; mark <= W holds
        usdc.mint(trader, 100_000e6);
        vm.prank(trader); usdc.approve(address(c), type(uint256).max);
    }
    function test_open_locksEscrowEqualsW() public {
        vm.startPrank(trader);
        c.deposit(6e6);                          // IM for qty=1 call = W = $6
        c.openLong(1e18);
        vm.stopPrank();
        assertEq(c.poolLocked(), 6e6);           // escrow = qty*W
        (uint256 qty,,) = c.positions(trader); assertEq(qty, 1e18);
    }
    function test_funding_accruesMarkMinusIntrinsic() public {
        vm.startPrank(trader); c.deposit(6e6); c.openLong(1e18); vm.stopPrank();
        // one funding period elapses, spot flat (intrinsic 0), mark 1e18 -> funding = 1e18/unit
        vm.warp(block.timestamp + 3600);
        c.postMark(1e18);
        assertEq(c.pendingFunding(trader), 1e18);
    }
    function test_close_paysMarkGainBoundedByEscrow() public {
        vm.startPrank(trader); c.deposit(6e6); c.openLong(1e18); vm.stopPrank();
        // mark rises to cap; trader closes. gain <= escrow (W). No funding elapsed.
        // Warp past MAX_MARK_AGE so postMark takes the stale-gap path (skips deviation
        // check + funding accumulation), allowing the mark to jump to W = 6e18.
        vm.warp(block.timestamp + c.MAX_MARK_AGE() + 1);
        c.postMark(6e18);                        // mark == W (upper guard boundary)
        uint256 before = c.traderCollateral(trader);
        vm.prank(trader); c.close();
        assertGt(c.traderCollateral(trader), before);        // realized mark gain
        assertLe(c.traderCollateral(trader) - before, 6e6);  // bounded by escrow=W
    }
}
