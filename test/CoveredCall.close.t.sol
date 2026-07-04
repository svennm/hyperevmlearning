// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import "forge-std/Test.sol";
import "../src/CoveredCallMarket.sol";
import "../src/MockUSDC.sol";
import "../src/MockOracle.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISpotOracle} from "../src/interfaces/ISpotOracle.sol";

contract CoveredCallCloseTest is Test {
    uint256 constant K = 48e18;
    address constant keeper = address(0xBEEF);
    address constant alice   = address(0xA11CE);

    MockUSDC usdc;
    MockOracle oracle;
    CoveredCallMarket market;

    function setUp() public {
        usdc   = new MockUSDC();
        oracle = new MockOracle();
        // address(this) becomes LP (constructor sets lp = msg.sender)
        market = new CoveredCallMarket(IERC20(address(usdc)), ISpotOracle(address(oracle)), K, keeper);

        oracle.set(50e18); // intrinsic = 2e18

        usdc.mint(alice, 10_000e6);
        usdc.mint(address(this), 200_000e6); // enough for lpDeposit + tests

        vm.prank(alice);
        usdc.approve(address(market), type(uint256).max);
        usdc.approve(address(market), type(uint256).max);

        market.lpDeposit(100_000e6);        // seed pool
        market.increaseCover(5e18);         // cover 5 units

        vm.warp(1);
        vm.prank(keeper);
        market.postMark(5e18);              // mark = 5e18, lastIntrinsic = 2e18

        // alice opens 1 unit: IM = qty*mark/1e18/1e12 = 1e18*5e18/1e18/1e12 = 5e6
        vm.prank(alice);
        market.deposit(5e6);
        vm.prank(alice);
        market.openLong(1e18);              // netWritten = 1e18
    }

    // close() pays mark gain from poolUsdc; collateral rises; poolUsdc falls; netWritten=0; position deleted
    function test_close_markGainPaidFromPoolUsdc() public {
        // Post mark 6e18 at t=2 (age=1 < FUNDING_PERIOD → periods=0 → cumFunding stays 0)
        vm.warp(2);
        vm.prank(keeper);
        market.postMark(6e18);

        uint256 poolBefore = market.poolUsdc();
        uint256 colBefore  = market.traderCollateral(alice); // 5e6

        vm.prank(alice);
        market.close();

        // markGainU = qty*(newMark-entryMark)/1e18/1e12 = 1e18*(6e18-5e18)/1e18/1e12 = 1e6
        // fundingU  = 0 (cumFunding still 0)
        // netU = +1e6 (gain) → pool pays 1e6 to trader
        assertEq(market.traderCollateral(alice), colBefore + 1e6);
        assertEq(market.poolUsdc(), poolBefore - 1e6);
        assertEq(market.netWritten(), 0);
        (uint256 q,,) = market.positions(alice);
        assertEq(q, 0);
    }

    // funding flows trader→pool (net loss for trader)
    function test_close_fundingFlowsToPool() public {
        // 1 period (3600s): cumFunding += (5e18-2e18)*1 = 3e18 → fundingU = 3e6
        vm.warp(1 + 3600);
        vm.prank(keeper);
        market.postMark(5e18); // mark unchanged, within deviation

        uint256 poolBefore = market.poolUsdc();

        vm.prank(alice);
        market.close();

        // markGainU=0, markLossU=0 (mark unchanged), fundingU=3e6
        // netU = -3e6 → l=3e6 ≤ 5e6 → collateral: 5-3=2e6; poolUsdc += 3e6
        assertEq(market.traderCollateral(alice), 2e6);
        assertEq(market.poolUsdc(), poolBefore + 3e6);
        assertEq(market.netWritten(), 0);
        (uint256 q,,) = market.positions(alice);
        assertEq(q, 0);
    }

    // auto-settle floor: loss > collateral floors at 0, no underflow, pool gets collateral
    function test_autoSettle_floorAtZero() public {
        // 2 periods (7200s): cumFunding += (5e18-2e18)*2 = 6e18 → fundingU = 6e6 > collateral=5e6
        vm.warp(1 + 7200);
        vm.prank(keeper);
        market.postMark(5e18); // periods=2

        uint256 poolBefore = market.poolUsdc();
        uint256 colBefore  = market.traderCollateral(alice); // 5e6

        vm.prank(alice);
        market.close();

        // l = 6e6 > colBefore=5e6 → l = 5e6; traderCollateral = 0; poolUsdc += 5e6
        assertEq(market.traderCollateral(alice), 0);
        assertEq(market.poolUsdc(), poolBefore + colBefore);
        assertEq(market.netWritten(), 0);
        (uint256 q,,) = market.positions(alice);
        assertEq(q, 0);
    }

    // settle() reverts "solvent" when pendingFunding ≤ collateral
    function test_settle_revertsIfSolvent() public {
        // cumFunding=0 → pendingFunding(alice)=0 → _toUsdc(0)=0; 0 > 5e6 → false → revert
        vm.expectRevert(bytes("solvent"));
        market.settle(alice);
    }

    // settle() closes when funding > collateral (permissionless)
    function test_settle_closesWhenFundingExceedsCollateral() public {
        vm.warp(1 + 7200);
        vm.prank(keeper);
        market.postMark(5e18); // cumFunding = 6e18 → _toUsdc(6e18)=6e6 > 5e6

        market.settle(alice); // permissionless — anyone can call
        (uint256 q,,) = market.positions(alice);
        assertEq(q, 0);
    }

    // settle() fires on markLoss-driven insolvency even when funding alone ≤ collateral.
    // This is the case the old funding-only predicate missed (keeper lockout → pool eats shortfall).
    function test_settle_catchesMarkLossInsolvency() public {
        // Top alice to 6e6 so funding alone (5e6) stays strictly below collateral.
        vm.prank(alice);
        market.deposit(1e6);
        assertEq(market.traderCollateral(alice), 6e6);

        // period 1: mark 5e18 → 4e18 (−20%). f = oldMark5 − lastIntr2 = 3e18 → cumFunding = 3e18
        vm.warp(3601);
        vm.prank(keeper);
        market.postMark(4e18);

        // period 2: mark 4e18 → 3.2e18 (−20%). f = oldMark4 − lastIntr2 = 2e18 → cumFunding = 5e18
        vm.warp(7201);
        vm.prank(keeper);
        market.postMark(32e17);

        // funding = 1e18·5e18/1e18 = 5e18 → 5e6 ; markLoss = 1e18·(5−3.2)e18/1e18 = 1.8e18 → 1.8e6
        // netLoss = 5e6 + 1.8e6 = 6.8e6 > collateral 6e6 → INSOLVENT,
        // yet funding 5e6 ≤ 6e6 → the old funding-only predicate would have reverted "solvent".
        assertEq(market.pendingFunding(alice) / 1e12, 5e6);
        assertLe(market.pendingFunding(alice) / 1e12, market.traderCollateral(alice)); // old: no-fire
        assertEq(market.netLossUsdc(alice), 6_800_000);
        assertGt(market.netLossUsdc(alice), market.traderCollateral(alice));            // truly insolvent

        // New predicate fires — permissionless force-close succeeds; pool recovers full collateral.
        market.settle(alice);
        (uint256 q,,) = market.positions(alice);
        assertEq(q, 0);
        assertEq(market.traderCollateral(alice), 0);
    }

    // reduceCover reverts "cover<net" if it would drop coverQty below netWritten
    function test_reduceCover_revertsIfBreaksInvariant() public {
        // coverQty=5e18, netWritten=1e18
        // reduce by 5e18: 5-5=0 < 1 → revert "cover<net"
        vm.expectRevert(bytes("cover<net"));
        market.reduceCover(5e18);

        // reduce by 4e18: 5-4=1 == netWritten=1 → OK (coverQty stays ≥ netWritten)
        market.reduceCover(4e18);
        assertEq(market.coverQty(), 1e18);
    }

    // openLong(0) reverts "qty=0"
    function test_zeroQty_revertsOpenLong() public {
        vm.prank(alice);
        vm.expectRevert(bytes("qty=0"));
        market.openLong(0);
    }

    // increaseCover(0) reverts "qty=0"
    function test_zeroQty_revertsIncreaseCover() public {
        vm.expectRevert(bytes("qty=0"));
        market.increaseCover(0);
    }
}
