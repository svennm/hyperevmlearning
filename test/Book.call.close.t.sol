// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {EverlastingBook} from "../src/EverlastingBook.sol";
import {MockCoverVault} from "../src/mocks/MockCoverVault.sol";
import {MockOracle} from "../src/MockOracle.sol";

/// @title BookCallCloseTest
/// @notice Tests for EverlastingBook COVERED_CALL close/settle (Task 5):
///   - winning close sells cover (I3) and pays g from physical vault.poolUsdc()
///   - conservation check: vault.poolUsdc() == pool-free + Σ traderCollateral after winning close
///   - M3 safety: no double-credit from sellCover's return value
///   - losing close floors at collateral (auto-settle floor; no underflow)
///   - settle fires on netLossUsdc > collateral (I2 markLoss case: funding alone ≤ collateral)
///   - settle reverts "solvent" when net loss ≤ collateral
///   - netWritten decremented symmetrically on close and settle
///   - sub-tick dust tolerated: flooredHype=0 → no sellCover; pool covers payout directly
contract BookCallCloseTest is Test {
    MockCoverVault  vault;
    MockOracle      oracle;
    EverlastingBook book;

    address constant ALICE = address(0xA11CE);

    uint256 constant KPUT      = 100e18;
    uint256 constant WPUT      =  50e18;
    uint256 constant KCALL     = 120e18;
    uint256 constant INIT_MARK = 5e18;
    uint256 constant HYPE_PX   = 100e18;  // $100 / HYPE (WAD)
    uint256 constant FUNDING_PERIOD = 3600;
    uint256 constant MAX_MARK_AGE   = 7200;

    EverlastingBook.Side private constant CALL = EverlastingBook.Side.COVERED_CALL;
    EverlastingBook.Side private constant PUT  = EverlastingBook.Side.PUT;

    // Numeric shorthand for mapping key (uint8(COVERED_CALL) == 1)
    uint8 private constant CALL_U = 1;

    function setUp() public {
        vault  = new MockCoverVault();
        oracle = new MockOracle();
        book   = new EverlastingBook(
            vault, oracle, address(this),
            KPUT, WPUT, KCALL,
            10_000e18, 10_000e18
        );

        oracle.set(100e18);        // spot $100 — call OTM (Kcall=120); intrinsic=0
        vault.setMockPx(HYPE_PX); // $100/HYPE

        // Seed vault: 50,000 USDC pool + 100 HYPE cover (value $10,000)
        vault.pullUsdc(address(0), 50_000e6); // poolUsdc = 50_000e6
        vault.buyCover(100e18, 10_000e6);     // poolUsdc = 40_000e6, coverHype = 100e18

        // Post initial mark at t=1; isFresh=false (first mark → no deviation/funding checks)
        vm.warp(1);
        book.postMark(CALL, INIT_MARK); // mark=5e18, lastIntrinsic=0

        // address(this) deposits 10e6 and opens 1 HYPE position
        // IM = _toUsdc(1e18 × 5e18 / 1e18) = 5e6 ≤ 10e6 ✓
        book.deposit(CALL, 10e6);  // traderCollateral[CALL][this] = 10e6; poolUsdc = 40_010e6
        book.openLong(CALL, 1e18); // netWritten = 1e18; position stored at mark=5e18
    }

    // ── PUT placeholder reverts ───────────────────────────────────────────────

    /// @dev PUT is enabled (T6). With no PUT position, close(PUT) hits the no-position guard.
    function test_close_put_reverts_no_position() public {
        vm.expectRevert(bytes("no position"));
        book.close(PUT);
    }

    /// @dev PUT is enabled (T6). With no PUT position, settle(PUT) hits the no-position guard.
    function test_settle_put_reverts_no_position() public {
        vm.expectRevert(bytes("no position"));
        book.settle(PUT, address(this));
    }

    // ── Winning close: I3 cover sale + M3 conservation ───────────────────────

    /// @dev Mark rises 5→6: g=1e6; hypeForG=0.01 HYPE (1 tick); cover sold; trader paid.
    function test_winning_close_sells_cover_and_pays_trader() public {
        // Post mark 6e18 (within 20% deviation from 5e18); no funding period elapsed
        vm.warp(2);
        book.postMark(CALL, 6e18);

        uint256 coverBefore = vault.coverHype();                         // 100e18
        uint256 poolBefore  = vault.poolUsdc();                          // 40_010e6
        uint256 colBefore   = book.traderCollateral(CALL_U, address(this)); // 10e6

        // g = _toUsdc(1e18*(6e18-5e18)/1e18) = 1e6
        // hypeForG = (1e6*1e12)*1e18/100e18 = 1e16 WAD = 0.01 HYPE (exactly 1 tick)
        // flooredHype = 1e16 → vault.sellCover(1e16) → coverHype -= 1e16, poolUsdc += 1e6
        book.close(CALL);

        // Cover reduced by exactly 1 tick (0.01 HYPE = 1e16 WAD)
        assertEq(vault.coverHype(), coverBefore - 1e16, "cover sold by 1 tick");
        // Pool increased by usdcFromSell = _toUsdc(1e16*100e18/1e18) = 1e6
        assertEq(vault.poolUsdc(),  poolBefore + 1e6,   "poolUsdc += usdcFromSell");
        // Trader credited g
        assertEq(book.traderCollateral(CALL_U, address(this)), colBefore + 1e6, "trader paid g");
        // Position cleared
        (uint256 qty,,) = book.positions(CALL_U, address(this));
        assertEq(qty, 0, "position deleted");
        // netWritten back to zero
        (,,,, uint256 netW) = book.sideState(CALL_U);
        assertEq(netW, 0, "netWritten=0 after close");
    }

    /// @dev Conservation check + M3 no-double-credit:
    ///      vault.poolUsdc() must equal poolBefore + usdcFromSell (NOT poolBefore + 2*g).
    ///      Double-credit would occur if sellCover's return value were used to credit an additional
    ///      ledger entry on top of what vault.sellCover() already added to vault.poolUsdc().
    function test_winning_close_conservation_no_double_credit() public {
        vm.warp(2);
        book.postMark(CALL, 6e18);

        uint256 poolBefore = vault.poolUsdc(); // 40_010e6

        book.close(CALL);

        uint256 poolAfter    = vault.poolUsdc();
        uint256 traderCol    = book.traderCollateral(CALL_U, address(this));

        // usdcFromSell = _toUsdc(1e16 * 100e18 / 1e18) = 1e6 (same as g here)
        // Correct: poolAfter = 40_011e6. Double-credit bug: poolAfter = 40_012e6.
        assertEq(poolAfter, poolBefore + 1e6, "pool += usdcFromSell only (no double-credit)");

        // Conservation identity against the contract's OWN ledgers (not a tautology): the physical
        // pool balance must equal poolFree() + putEscrow + totalCollateral, and totalCollateral must
        // equal the live sum of per-trader collateral. A phantom pool mutation or a Σ drift breaks this.
        assertEq(
            poolAfter,
            book.poolFree() + book.putEscrow() + book.totalCollateral(),
            "conservation: poolUsdc == poolFree + putEscrow + totalCollateral"
        );
        assertEq(book.totalCollateral(), traderCol, "totalCollateral == sum traderCollateral (single actor)");
    }

    // ── Winning close: sub-tick gain rounds UP to one tick (T7 tick-dust fix) ──

    /// @dev T7 tick-dust fix: a gain worth LESS than 0.01 HYPE at current spot now sells exactly
    ///      ONE tick (ceil-to-tick), NOT zero (the old floor). Proceeds P ≥ g, so poolFree() is
    ///      replenished and NEVER eroded — the pool keeps the sub-tick excess (P − g) as FREE USDC.
    ///      The old floor-to-0 path left the gain unfunded by cover and slowly bled poolFree().
    ///
    ///      Setup: close the setUp position (neutral, g=0), then open 0.1 HYPE.
    ///      Mark 5→6: g = _toUsdc(0.1e18*(6-5)/1e18) = 1e5 USDC.
    ///      hypeForG = (1e5*1e12)*1e18/100e18 = 1e15 WAD < 0.01 HYPE (1e16 WAD) → ceils UP to 1e16.
    ///      sellCover(1e16) → coverHype -= 1e16, poolUsdc += P = _toUsdc(1e16*100e18/1e18) = 1e6.
    ///      Trader is credited g = 1e5; the pool keeps P − g = 9e5 as pool-free USDC.
    function test_winning_close_sub_tick_gain_rounds_up_one_tick() public {
        // Neutral-close the setUp position (mark unchanged → g=0, l=0). g=0 → NO cover sold.
        book.close(CALL);
        assertEq(book.traderCollateral(CALL_U, address(this)), 10e6, "neutral close: collateral unchanged");

        // Deposit extra IM for 0.1 HYPE; IM = _toUsdc(0.1e18*5e18/1e18) = 5e5
        book.deposit(CALL, 2e6);
        book.openLong(CALL, 0.1e18); // 1e17 WAD

        vm.warp(2);
        book.postMark(CALL, 6e18);

        uint256 coverBefore    = vault.coverHype();   // 100e18
        uint256 poolBefore     = vault.poolUsdc();    // 40_012e6
        uint256 totalColBefore = book.totalCollateral();

        book.close(CALL);

        // g = 1e5 USDC; hypeForG = 1e15 WAD; ceilHype = 1e16 (exactly one tick) → sellCover(1e16)
        assertEq(vault.coverHype(), coverBefore - 1e16, "sub-tick gain sells exactly one tick");
        // Proceeds P = 1e6 credited to the pool; trader paid only g = 1e5
        assertEq(vault.poolUsdc(), poolBefore + 1e6, "poolUsdc += P (1e6 proceeds)");
        assertEq(book.traderCollateral(CALL_U, address(this)), 12e6 + 1e5, "trader paid g=1e5");
        // poolFree() GREW by P − g = 9e5 (never eroded): ΔpoolUsdc(+1e6) − ΔtotalCollateral(+1e5)
        assertEq(book.totalCollateral(), totalColBefore + 1e5, "totalCollateral += g only");
        assertEq(
            vault.poolUsdc(),
            book.poolFree() + book.putEscrow() + book.totalCollateral(),
            "conservation holds after ceil-to-tick close"
        );
    }

    // ── Losing close ──────────────────────────────────────────────────────────

    /// @dev Normal loss: mark falls 5→4; l=1e6 ≤ collateral=10e6; no cover sold.
    function test_losing_close_normal() public {
        vm.warp(MAX_MARK_AGE + 2); // stale mark → bypass deviation guard
        book.postMark(CALL, 4e18); // intrinsic=0, so any mark ≥ 0 accepted

        uint256 poolBefore = vault.poolUsdc();  // 40_010e6
        uint256 colBefore  = book.traderCollateral(CALL_U, address(this)); // 10e6

        book.close(CALL);

        // l = _toUsdc(1e18*(5e18-4e18)/1e18) = 1e6; no cover sold
        assertEq(book.traderCollateral(CALL_U, address(this)), colBefore - 1e6, "collateral reduced by l");
        assertEq(vault.poolUsdc(),  poolBefore,    "pool unchanged on loss (l accrues to pool free)");
        assertEq(vault.coverHype(), 100e18,         "cover unchanged on loss");
        (uint256 qty,,) = book.positions(CALL_U, address(this));
        assertEq(qty, 0, "position deleted");
        (,,,, uint256 netW) = book.sideState(CALL_U);
        assertEq(netW, 0, "netWritten=0");
    }

    /// @dev Auto-settle floor: accumulated funding makes l > collateral.
    ///      3 periods at mark=5e18 (intrinsic=0): cumFunding=15e18; fundingU=15e6 > collateral=10e6.
    ///      l floored to 10e6; traderCollateral → 0; no underflow.
    function test_losing_close_floors_at_collateral() public {
        // Period 1: warp 3600s, re-post same mark
        vm.warp(3601);
        book.postMark(CALL, 5e18); // periods=1; cumFunding += 5e18

        // Period 2
        vm.warp(7201);
        book.postMark(CALL, 5e18); // cumFunding += 5e18 → 10e18

        // Period 3
        vm.warp(10801);
        book.postMark(CALL, 5e18); // cumFunding += 5e18 → 15e18

        uint256 colBefore = book.traderCollateral(CALL_U, address(this));
        assertEq(colBefore, 10e6, "pre-close collateral");

        book.close(CALL);

        // fundingU = _toUsdc(1e18*15e18/1e18) = 15e6; markGainU=0; l=15e6 > 10e6 → floor to 10e6
        assertEq(book.traderCollateral(CALL_U, address(this)), 0, "collateral zeroed (floor)");
        (uint256 qty,,) = book.positions(CALL_U, address(this));
        assertEq(qty, 0, "position deleted after floor close");
        (,,,, uint256 netW) = book.sideState(CALL_U);
        assertEq(netW, 0, "netWritten=0");
    }

    // ── settle ────────────────────────────────────────────────────────────────

    /// @dev settle reverts "solvent" when netLossUsdc ≤ collateral.
    ///      Fresh setup: no funding, mark unchanged → netLossUsdc=0 ≤ 10e6.
    function test_settle_reverts_solvent() public {
        vm.expectRevert(bytes("solvent"));
        book.settle(CALL, address(this));
    }

    /// @dev settle reverts "no position" for an address with no open position.
    function test_settle_reverts_no_position() public {
        vm.expectRevert(bytes("no position"));
        book.settle(CALL, address(0xDEAD));
    }

    /// @dev I2 markLoss insolvency: funding alone ≤ collateral, but markLoss + funding > collateral.
    ///      This is the case a funding-only predicate would miss (keeper lockout).
    ///
    ///      alice deposits 5e6 (= IM exactly) and opens 1 HYPE at mark=5e18.
    ///      After 1 period: mark drops to 4e18 (−20%, boundary of deviation guard).
    ///        cumFunding = 5e18 → fundingU = 5e6 (= collateral, NOT > collateral)
    ///        markLossU  = _toUsdc(1e18*(5e18-4e18)/1e18) = 1e6
    ///        netLossUsdc = 6e6 > collateral 5e6 → INSOLVENT
    ///      Old funding-only check (pendingFunding/1e12 > collateral) → 5e6 > 5e6 → FALSE (misses it).
    function test_settle_fires_mark_loss_insolvency() public {
        // Fund and open alice's position (address(this) already has a position from setUp)
        vm.prank(ALICE);
        book.deposit(CALL, 5e6); // MockCoverVault.pullUsdc ignores `from`; poolUsdc += 5e6
        vm.prank(ALICE);
        book.openLong(CALL, 1e18); // entryMark=5e18, entryCumFunding=0

        // One funding period: cumFunding accumulates mark(5e18) - lastIntrinsic(0) = 5e18
        vm.warp(3601);
        book.postMark(CALL, 4e18); // mark drops by exactly 20%; cumFunding += 5e18*1

        // Verify predicates
        uint256 aliceCol     = book.traderCollateral(CALL_U, ALICE);
        uint256 netLoss      = book.netLossUsdc(CALL, ALICE);
        uint256 fundingAlone = book.pendingFunding(CALL, ALICE) / 1e12;

        assertEq(aliceCol,     5e6, "alice collateral");
        assertEq(fundingAlone, 5e6, "funding alone = collateral (old predicate: no-fire)");
        assertLe(fundingAlone, aliceCol, "funding alone does NOT exceed collateral");
        assertEq(netLoss, 6e6,          "full netLossUsdc = 6e6 (markLoss pushes it over)");
        assertGt(netLoss, aliceCol,     "truly insolvent -> settle fires");

        // settle is permissionless; anyone can call
        book.settle(CALL, ALICE);

        (uint256 qty,,) = book.positions(CALL_U, ALICE);
        assertEq(qty, 0, "alice position deleted after force-close");
        assertEq(book.traderCollateral(CALL_U, ALICE), 0, "alice collateral zeroed (loss=6e6>5e6, floor)");
    }

    /// @dev settle fires on funding-driven insolvency (2 periods; funding > collateral).
    ///      netWritten decrements for both address(this) and alice independently.
    function test_settle_fires_funding_insolvency() public {
        // alice opens 1 HYPE (IM=5e6; deposit exactly IM)
        vm.prank(ALICE);
        book.deposit(CALL, 5e6);
        vm.prank(ALICE);
        book.openLong(CALL, 1e18); // netWritten = 2e18 (this + alice)

        // 2 periods: cumFunding = 5e18 + 5e18 = 10e18 → fundingU = 10e6 > alice's 5e6
        vm.warp(3601);
        book.postMark(CALL, 5e18); // period 1: cumFunding = 5e18

        vm.warp(7201);
        book.postMark(CALL, 5e18); // period 2: cumFunding = 10e18

        assertGt(book.netLossUsdc(CALL, ALICE), book.traderCollateral(CALL_U, ALICE), "insolvent");

        book.settle(CALL, ALICE);

        (uint256 qty,,) = book.positions(CALL_U, ALICE);
        assertEq(qty, 0, "alice position cleared");

        (,,,, uint256 netW) = book.sideState(CALL_U);
        assertEq(netW, 1e18, "netWritten = 1e18 (address(this) still open)");
    }

    // ── netWritten symmetry ───────────────────────────────────────────────────

    /// @dev Winning close and losing close both decrement netWritten to 0.
    ///      (Each sub-test is self-contained via fork or sequential state.)
    function test_netWritten_zero_after_winning_close() public {
        vm.warp(2);
        book.postMark(CALL, 6e18);
        book.close(CALL);
        (,,,, uint256 netW) = book.sideState(CALL_U);
        assertEq(netW, 0);
    }

    function test_netWritten_zero_after_losing_close() public {
        vm.warp(MAX_MARK_AGE + 2);
        book.postMark(CALL, 4e18);
        book.close(CALL);
        (,,,, uint256 netW) = book.sideState(CALL_U);
        assertEq(netW, 0);
    }

    // ── Close with no position reverts ────────────────────────────────────────

    function test_close_reverts_no_position() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(bytes("no position"));
        book.close(CALL);
    }
}
