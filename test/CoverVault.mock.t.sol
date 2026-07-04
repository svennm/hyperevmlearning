// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import "forge-std/Test.sol";
import "../src/mocks/MockCoverVault.sol";
import "../src/interfaces/ICoverVault.sol";

/// @notice Unit tests for MockCoverVault — the collateral-adapter seam (Task 1).
///         Covers: buy usdc→hype at px; sell with szDecimals=2 floor + dust; coverEquity;
///         payoutUsdc / pullUsdc ledger moves; no-negative-balance guard reverts.
contract CoverVaultMockTest is Test {
    MockCoverVault vault;

    uint256 constant PX       = 20e18;    // $20/HYPE, WAD
    uint256 constant WAD      = 1e18;
    uint256 constant POOL_SEED = 1000e6;  // 1000 USDC seed (6dp)

    function setUp() public {
        vault = new MockCoverVault();
        vault.setMockPx(PX);
        // Seed the pool via pullUsdc (from address ignored in mock)
        vault.pullUsdc(address(0), POOL_SEED);
    }

    // ── buyCover: debit poolUsdc, credit coverHype ────────────────────────────

    function test_buyCover_deductsUsdc_creditsHype() public {
        // Buy 1 HYPE at $20 → cost = _toUsdc(1e18 * 20e18 / 1e18) = 20e6
        vault.buyCover(1e18, 20e6);
        assertEq(vault.poolUsdc(),  POOL_SEED - 20e6, "poolUsdc after buy");
        assertEq(vault.coverHype(), 1e18,              "coverHype after buy");
    }

    function test_buyCover_fractional_qty() public {
        // Buy 0.5 HYPE at $20 → cost = _toUsdc(0.5e18 * 20e18 / 1e18) = 10e6
        vault.buyCover(0.5e18, 10e6);
        assertEq(vault.poolUsdc(),  POOL_SEED - 10e6, "pool after 0.5 HYPE buy");
        assertEq(vault.coverHype(), 0.5e18,            "cover after 0.5 HYPE buy");
    }

    function test_buyCover_slippageReverts() public {
        // 1 HYPE costs 20e6; cap at 19e6 → revert
        vm.expectRevert("slippage");
        vault.buyCover(1e18, 19e6);
    }

    function test_buyCover_insufficientPoolReverts() public {
        // 51 HYPE × $20 = 1020e6 > 1000e6 pool → revert
        vm.expectRevert("pool: insufficient");
        vault.buyCover(51e18, type(uint256).max);
    }

    function test_buyCover_zeroQtyReverts() public {
        vm.expectRevert("qty=0");
        vault.buyCover(0, type(uint256).max);
    }

    // ── sellCover: szDecimals=2 floor + dust ─────────────────────────────────

    /// @notice Selling 0.9993 HYPE must sell exactly 0.99 HYPE (floor to 0.01 tick)
    ///         and leave 0.0093 HYPE dust in coverHype.
    function test_sellCover_floors_to_szDecimals_and_leaves_dust() public {
        uint256 hypeIn = 0.9993e18; // 999300000000000000 WAD

        // Buy 0.9993 HYPE first (use type max to avoid slippage friction in setup)
        vault.buyCover(hypeIn, type(uint256).max);
        assertEq(vault.coverHype(), hypeIn, "pre-sell coverHype");

        // Sell 0.9993 → floored to 0.99e18 (99 ticks of 1e16)
        uint256 usdcOut = vault.sellCover(hypeIn);

        // proceeds: _toUsdc(0.99e18 * 20e18 / 1e18) = _toUsdc(19.8e18) = 19_800000
        assertEq(usdcOut, 19_800000, "sell proceeds (0.99 HYPE at $20)");

        // dust = 0.9993e18 - 0.99e18 = 0.0093e18
        assertEq(vault.coverHype(), 0.0093e18, "dust remaining in coverHype");
    }

    function test_sellCover_exact_tick_no_dust() public {
        vault.buyCover(2e18, type(uint256).max);

        uint256 usdcOut = vault.sellCover(1e18);
        // 1 HYPE is an exact tick: no dust
        assertEq(usdcOut, 20e6,     "proceeds for 1 HYPE");
        assertEq(vault.coverHype(), 1e18, "1 HYPE remaining");
    }

    function test_sellCover_below_min_tick_reverts() public {
        vault.buyCover(1e18, type(uint256).max);
        // 0.009 HYPE = 9e15 WAD < 1e16 (one tick) → floored = 0 → revert
        vm.expectRevert("qty: below min tick");
        vault.sellCover(9e15);
    }

    function test_sellCover_insufficient_cover_reverts() public {
        // No cover in vault
        vm.expectRevert("cover: insufficient");
        vault.sellCover(1e18);
    }

    // ── coverEquityUsdc = coverHype × spotPx ─────────────────────────────────

    function test_coverEquityUsdc_equals_hype_times_px() public {
        vault.buyCover(2.5e18, type(uint256).max);
        // equity = _toUsdc(2.5e18 * 20e18 / 1e18) = _toUsdc(50e18) = 50e6
        assertEq(vault.coverEquityUsdc(), 50e6, "equity 2.5 HYPE at $20");
    }

    function test_coverEquityUsdc_zero_when_empty() public view {
        assertEq(vault.coverEquityUsdc(), 0, "zero equity on empty vault");
    }

    function test_coverEquityUsdc_tracks_price_change() public {
        vault.buyCover(1e18, type(uint256).max);
        assertEq(vault.coverEquityUsdc(), 20e6, "equity at $20");

        vault.setMockPx(40e18); // price doubles
        assertEq(vault.coverEquityUsdc(), 40e6, "equity at $40");
    }

    // ── payoutUsdc / pullUsdc: ledger moves ──────────────────────────────────

    function test_payoutUsdc_deducts_from_pool() public {
        vault.payoutUsdc(address(0xBEEF), 100e6);
        assertEq(vault.poolUsdc(), POOL_SEED - 100e6, "pool after payout");
    }

    function test_payoutUsdc_insufficient_reverts() public {
        vm.expectRevert("pool: insufficient");
        vault.payoutUsdc(address(0xBEEF), POOL_SEED + 1);
    }

    function test_pullUsdc_adds_to_pool() public {
        vault.pullUsdc(address(0xBEEF), 500e6);
        assertEq(vault.poolUsdc(), POOL_SEED + 500e6, "pool after pull");
    }

    // ── Round-trip integrity ──────────────────────────────────────────────────

    function test_buy_then_sell_exact_tick_pool_unchanged() public {
        uint256 poolBefore = vault.poolUsdc();

        vault.buyCover(1e18, type(uint256).max);
        vault.sellCover(1e18);

        // 1 HYPE is an exact tick → zero slippage → pool is fully restored
        assertEq(vault.poolUsdc(),  poolBefore, "pool restored after round-trip");
        assertEq(vault.coverHype(), 0,          "no hype after round-trip");
    }

    /// @notice Verify ICoverVault conformance: MockCoverVault IS-A ICoverVault.
    function test_implements_ICoverVault() public view {
        ICoverVault v = ICoverVault(address(vault));
        // Static type-check (compile-time) plus a trivial runtime call
        assertEq(v.poolUsdc(), POOL_SEED);
    }
}
