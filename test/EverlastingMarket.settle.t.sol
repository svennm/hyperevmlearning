// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {EverlastingMarket} from "../src/EverlastingMarket.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockOracle} from "../src/MockOracle.sol";

/// @title EverlastingMarket.settle.t.sol
/// @notice Regression for the settle-predicate fix: settle() must gate on the FULL net loss
///         (funding + markLoss − markGain), not funding alone. Constructs a mark-loss-insolvent long
///         put where funding < collateral < funding + markLoss — the exact state the old funding-only
///         predicate could NOT settle, leaving the shortfall stuck on the pool. Deployer is both LP
///         and keeper here (so the test can post marks directly).
contract EverlastingMarketSettleTest is Test {
    EverlastingMarket mkt;
    MockUSDC usdc;
    MockOracle oracle;

    address trader = address(0x7111);

    function setUp() public {
        usdc   = new MockUSDC();
        oracle = new MockOracle();
        // PUT, K = W = 100 (fully-collateralized put); keeper = this test contract.
        mkt = new EverlastingMarket(usdc, oracle, EverlastingMarket.Side.PUT, 100e18, 100e18, address(this));
        usdc.mint(address(this), 1_000_000e6);
        usdc.approve(address(mkt), type(uint256).max);
        mkt.lpDeposit(500_000e6); // pool-free for the escrow lock
    }

    function test_markLossInsolvent_settleable_afterFix() public {
        // 1) spot == K → put intrinsic 0; seed mark high (option bought expensive).
        oracle.set(100e18);
        mkt.postMark(100e18);                 // mark=100, lastIntrinsic=0

        // 2) trader opens 1.0 with collateral == IM (= qty·W = 100 USDC).
        usdc.mint(trader, 100e6);
        vm.startPrank(trader);
        usdc.approve(address(mkt), type(uint256).max);
        mkt.deposit(100e6);
        mkt.openLong(1e18);                   // entryMark=100, entryCumFunding=0, escrow 100e6
        vm.stopPrank();

        // 3) mark collapses toward intrinsic via the recoverable-staleness re-seed (bypasses the
        //    20% deviation cap; no funding on a stale gap): mark 100 → 2. markLoss now ≈ 98.
        vm.warp(block.timestamp + 7201);      // > MAX_MARK_AGE ⇒ stale re-seed, no funding
        mkt.postMark(2e18);                   // mark=2, lastIntrinsic=0, cumFunding still 0

        // 4) accrue 2 periods of SMALL funding at the now-low rate (f = mark − intrinsic = 2/period).
        vm.warp(block.timestamp + 7200);      // exactly 2 periods, still fresh
        mkt.postMark(2e18);                   // cumFunding += 2·2 = 4  ⇒ funding = 4 USDC

        // ── The gap the fix closes ────────────────────────────────────────────────
        uint256 collateral = mkt.traderCollateral(trader);
        assertEq(collateral, 100e6, "collateral");
        uint256 fundingOnly = mkt.pendingFunding(trader) / 1e12; // _toUsdc
        assertEq(fundingOnly, 4e6, "funding alone");
        assertLt(fundingOnly, collateral, "old predicate: funding <= collateral (would NOT settle)");
        assertEq(mkt.netLossUsdc(trader), 102e6, "full net loss = markLoss(98) + funding(4)");
        assertGt(mkt.netLossUsdc(trader), collateral, "new predicate: net loss > collateral (settles)");

        // 5) permissionless settle now succeeds (old funding-only code reverts "solvent").
        mkt.settle(trader);
        (uint256 q,,) = mkt.positions(trader);
        assertEq(q, 0, "position closed by settle");
        assertEq(mkt.traderCollateral(trader), 0, "collateral consumed (loss floored at collateral)");
    }

    /// @notice The OLD funding-only predicate would revert here — pinned so a regression is loud.
    ///         We can't call the removed code, but we assert the exact state (funding <= collateral)
    ///         under which the old `require(fundingU > collateral)` reverted "solvent".
    function test_fundingOnlyPredicateWouldHaveReverted() public {
        oracle.set(100e18);
        mkt.postMark(100e18);
        usdc.mint(trader, 100e6);
        vm.startPrank(trader);
        usdc.approve(address(mkt), type(uint256).max);
        mkt.deposit(100e6);
        mkt.openLong(1e18);
        vm.stopPrank();
        vm.warp(block.timestamp + 7201);
        mkt.postMark(2e18);
        vm.warp(block.timestamp + 7200);
        mkt.postMark(2e18);
        // funding (4) <= collateral (100): the old `fundingU > traderCollateral` was FALSE → "solvent".
        assertLe(mkt.pendingFunding(trader) / 1e12, mkt.traderCollateral(trader));
    }
}
