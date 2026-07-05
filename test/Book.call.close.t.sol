// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {EverlastingBook} from "../src/EverlastingBook.sol";
import {MockCoverVault} from "../src/mocks/MockCoverVault.sol";
import {MockOracle} from "../src/MockOracle.sol";
import {MockVol} from "../src/mocks/MockVol.sol";

/// @title BookCallCloseTest
/// @notice Tests for EverlastingBook COVERED_CALL close/settle, migrated to the autonomous mark
///         (Task 5). A WINNING call is created by DRIVING THE ORACLE UP (fairMark(CALL) rises with
///         spot); a LOSING call by driving it down. Marks are read back and PnL is asserted RELATIVE
///         to the actual computed marks (no hardcoded mark literals).
///   - winning close sells cover (I3) and pays g from physical vault.poolUsdc()
///   - conservation check: vault.poolUsdc() == poolFree + putEscrow + Σ traderCollateral
///   - M3 safety: no double-credit from sellCover's return value
///   - T7 ceil-to-tick: a sub-tick gain sells exactly ONE tick, poolFree never eroded
///   - losing close floors at collateral (auto-settle floor; no underflow)
///   - settle fires on netLossUsdc > collateral (I2 markLoss case a funding-only predicate misses)
///   - settle reverts "solvent" when net loss ≤ collateral
///   - netWritten decremented symmetrically on close and settle
contract BookCallCloseTest is Test {
    MockCoverVault  vault;
    MockOracle      oracle;
    MockVol         mockVol;
    EverlastingBook book;

    address constant ALICE = address(0xA11CE);

    uint256 constant KPUT      = 100e18;
    uint256 constant WPUT      =  50e18;
    uint256 constant KCALL     = 120e18;
    uint256 constant HYPE_PX   = 100e18;  // $100 / HYPE (WAD) — vault cover-sale price (fixed)
    uint256 constant TICK      = 1e16;    // 0.01 HYPE = 1e16 WAD (szDecimals=2)

    EverlastingBook.Side private constant CALL = EverlastingBook.Side.COVERED_CALL;
    EverlastingBook.Side private constant PUT  = EverlastingBook.Side.PUT;

    uint8 private constant CALL_U = 1;

    function setUp() public {
        vault  = new MockCoverVault();
        oracle = new MockOracle();
        mockVol = new MockVol();
        book   = new EverlastingBook(
            vault, oracle, address(this),
            KPUT, WPUT, KCALL,
            10_000e18, 10_000e18,
            mockVol
        );

        oracle.set(100e18);        // spot $100 — call OTM (Kcall=120); intrinsic=0
        vault.setMockPx(HYPE_PX);  // $100/HYPE (cover-sale price, kept fixed)

        // Seed vault: 50,000 USDC pool + 100 HYPE cover (value $10,000)
        vault.pullUsdc(address(0), 50_000e6); // poolUsdc = 50_000e6
        vault.buyCover(100e18, 10_000e6);     // poolUsdc = 40_000e6, coverHype = 100e18

        vm.warp(1);
        book.accrue(CALL); // establish the autonomous mark at S=100

        // address(this) deposits 10e6 and opens 1 HYPE position at the computed entry mark.
        book.deposit(CALL, 10e6);  // traderCollateral[CALL][this] = 10e6
        book.openLong(CALL, 1e18); // netWritten = 1e18; entryMark = computed fair value
    }

    // ── helpers ────────────────────────────────────────────────────────────────

    function _mark(EverlastingBook.Side side) internal view returns (uint256 m) {
        (m,,,,) = book.sideState(uint8(side));
    }

    function _entryMark(address t) internal view returns (uint256 em) {
        (, em,) = book.positions(CALL_U, t);
    }

    /// @dev Recompute the exact cover-sale for a gain `g` (6dp) at the fixed vault px (mirrors src).
    function _sellFor(uint256 g) internal view returns (uint256 sellHype, uint256 proceeds) {
        uint256 px = vault.spotPxUsdc();
        uint256 hypeForG = (g * 1e12) * 1e18 / px;
        sellHype = ((hypeForG + TICK - 1) / TICK) * TICK; // ceil-to-tick
        proceeds = sellHype * px / 1e18 / 1e12;           // _toUsdc(sellHype*px/1e18)
    }

    // ── PUT placeholder reverts ───────────────────────────────────────────────

    function test_close_put_reverts_no_position() public {
        vm.expectRevert(bytes("no position"));
        book.close(PUT);
    }

    function test_settle_put_reverts_no_position() public {
        vm.expectRevert(bytes("no position"));
        book.settle(PUT, address(this));
    }

    // ── Winning close: I3 cover sale + M3 conservation ───────────────────────

    /// @dev Oracle up 100→110: fairMark(CALL) rises → trader wins g; cover sold to fund it.
    function test_winning_close_sells_cover_and_pays_trader() public {
        uint256 entry = _entryMark(address(this));
        oracle.set(110e18);        // same block ⇒ no funding
        book.accrue(CALL);
        uint256 exit = _mark(CALL);
        assertGt(exit, entry, "mark rose with spot (winning)");

        uint256 g = 1e18 * (exit - entry) / 1e18 / 1e12;
        assertGt(g, 0, "positive gain");
        (uint256 sellHype, uint256 proceeds) = _sellFor(g);

        uint256 coverBefore = vault.coverHype();
        uint256 poolBefore  = vault.poolUsdc();
        uint256 colBefore   = book.traderCollateral(CALL_U, address(this));

        book.close(CALL);

        assertEq(vault.coverHype(), coverBefore - sellHype, "cover sold = ceil-to-tick(hypeForG)");
        assertEq(vault.poolUsdc(),  poolBefore + proceeds,  "poolUsdc += cover-sale proceeds");
        assertEq(book.traderCollateral(CALL_U, address(this)), colBefore + g, "trader paid g");
        (uint256 qty,,) = book.positions(CALL_U, address(this));
        assertEq(qty, 0, "position deleted");
        (,,,, uint256 netW) = book.sideState(CALL_U);
        assertEq(netW, 0, "netWritten=0 after close");
    }

    /// @dev Conservation + M3 no-double-credit: pool rises by the cover-sale proceeds ONLY (not by 2·g).
    function test_winning_close_conservation_no_double_credit() public {
        uint256 entry = _entryMark(address(this));
        oracle.set(110e18);
        book.accrue(CALL);
        uint256 g = 1e18 * (_mark(CALL) - entry) / 1e18 / 1e12;
        (, uint256 proceeds) = _sellFor(g);

        uint256 poolBefore = vault.poolUsdc();
        book.close(CALL);
        uint256 poolAfter = vault.poolUsdc();

        assertEq(poolAfter, poolBefore + proceeds, "pool += proceeds only (no double-credit)");

        // Conservation identity against the contract's OWN ledgers (not a tautology).
        assertEq(
            poolAfter,
            book.poolFree() + book.putEscrow() + book.totalCollateral(),
            "conservation: poolUsdc == poolFree + putEscrow + totalCollateral"
        );
        assertEq(
            book.totalCollateral(),
            book.traderCollateral(CALL_U, address(this)),
            "totalCollateral == sum traderCollateral (single actor)"
        );
    }

    // ── Winning close: sub-tick gain rounds UP to one tick (T7 tick-dust fix) ──

    /// @dev T7 tick-dust fix: a gain worth LESS than 0.01 HYPE at the current px sells exactly ONE
    ///      tick (ceil-to-tick), NOT zero. Proceeds P ≥ g, so poolFree() is replenished and NEVER
    ///      eroded — the pool keeps the sub-tick excess (P − g) as FREE USDC.
    ///
    ///      Neutral-close the setUp position (g=0, no cover sold), then open 0.1 HYPE and win a tiny
    ///      amount by nudging spot up. g < 1 USDC ⇒ hypeForG < one tick ⇒ ceils UP to exactly 1e16.
    function test_winning_close_sub_tick_gain_rounds_up_one_tick() public {
        // Neutral-close the setUp position (mark unchanged → g=0 → NO cover sold).
        book.close(CALL);
        assertEq(book.traderCollateral(CALL_U, address(this)), 10e6, "neutral close: collateral unchanged");

        book.openLong(CALL, 0.1e18); // reuse existing collateral; entry = current mark at S=100
        uint256 entry = _entryMark(address(this));

        oracle.set(110e18);
        book.accrue(CALL);
        uint256 g = 0.1e18 * (_mark(CALL) - entry) / 1e18 / 1e12;
        assertGt(g, 0, "positive sub-tick gain");

        (uint256 sellHype, uint256 proceeds) = _sellFor(g);
        assertEq(sellHype, TICK, "sub-tick gain ceils to exactly one tick");
        assertEq(proceeds, 1e6,  "one tick of $100 HYPE = 1 USDC proceeds");
        assertGt(proceeds, g,    "proceeds >= payout (poolFree never eroded)");

        uint256 coverBefore    = vault.coverHype();
        uint256 poolBefore     = vault.poolUsdc();
        uint256 totalColBefore = book.totalCollateral();

        book.close(CALL);

        assertEq(vault.coverHype(), coverBefore - TICK, "sub-tick gain sells exactly one tick");
        assertEq(vault.poolUsdc(),  poolBefore + proceeds, "poolUsdc += proceeds");
        assertEq(book.totalCollateral(), totalColBefore + g, "totalCollateral += g only");
        assertEq(
            vault.poolUsdc(),
            book.poolFree() + book.putEscrow() + book.totalCollateral(),
            "conservation holds after ceil-to-tick close"
        );
    }

    // ── Losing close ──────────────────────────────────────────────────────────

    /// @dev Normal loss: oracle down 100→90 → mark falls; l ≤ collateral; no cover sold.
    function test_losing_close_normal() public {
        uint256 entry = _entryMark(address(this));
        oracle.set(90e18);
        book.accrue(CALL);
        uint256 exit = _mark(CALL);
        assertLt(exit, entry, "mark fell with spot (losing)");
        uint256 l = 1e18 * (entry - exit) / 1e18 / 1e12;
        assertLe(l, 10e6, "loss within collateral");

        uint256 poolBefore = vault.poolUsdc();
        uint256 colBefore  = book.traderCollateral(CALL_U, address(this));

        book.close(CALL);

        assertEq(book.traderCollateral(CALL_U, address(this)), colBefore - l, "collateral reduced by l");
        assertEq(vault.poolUsdc(),  poolBefore, "pool unchanged on loss (l accrues to pool free)");
        assertEq(vault.coverHype(), 100e18,      "cover unchanged on loss");
        (uint256 qty,,) = book.positions(CALL_U, address(this));
        assertEq(qty, 0, "position deleted");
        (,,,, uint256 netW) = book.sideState(CALL_U);
        assertEq(netW, 0, "netWritten=0");
    }

    /// @dev Auto-settle floor: accumulated funding makes l > collateral. Spot unchanged so the mark
    ///      stays constant and funding = mark·periods; after enough periods fundingU > collateral(10e6),
    ///      so l floors to collateral and traderCollateral → 0 with no underflow.
    function test_losing_close_floors_at_collateral() public {
        // Fold 100 periods of funding at the unchanged mark.
        vm.warp(block.timestamp + 100 * book.FUNDING_PERIOD());
        book.accrue(CALL);

        assertGt(
            book.netLossUsdc(CALL, address(this)),
            book.traderCollateral(CALL_U, address(this)),
            "funding drove loss over collateral"
        );

        book.close(CALL);

        assertEq(book.traderCollateral(CALL_U, address(this)), 0, "collateral zeroed (floor)");
        (uint256 qty,,) = book.positions(CALL_U, address(this));
        assertEq(qty, 0, "position deleted after floor close");
        (,,,, uint256 netW) = book.sideState(CALL_U);
        assertEq(netW, 0, "netWritten=0");
    }

    // ── settle ────────────────────────────────────────────────────────────────

    /// @dev settle reverts "solvent" when netLossUsdc ≤ collateral (no funding, mark unchanged).
    function test_settle_reverts_solvent() public {
        vm.expectRevert(bytes("solvent"));
        book.settle(CALL, address(this));
    }

    /// @dev settle reverts "no position" for an address with no open position.
    function test_settle_reverts_no_position() public {
        vm.expectRevert(bytes("no position"));
        book.settle(CALL, address(0xDEAD));
    }

    /// @dev I2 markLoss insolvency: funding alone == collateral, but markLoss pushes netLoss over it —
    ///      the case a funding-only predicate would miss (keeper lockout). ALICE opens with collateral
    ///      == IM (= qty·entryMark), so one period of funding exactly equals her collateral; then a
    ///      downward mark move adds markLoss, making netLoss > collateral while funding alone is not.
    function test_settle_fires_mark_loss_insolvency() public {
        uint256 markC0 = _mark(CALL);           // S=100 entry mark
        uint256 im     = 1e18 * markC0 / 1e18 / 1e12; // IM = _toUsdc(qty·mark)

        vm.prank(ALICE);
        book.deposit(CALL, im);                 // collateral == IM exactly
        vm.prank(ALICE);
        book.openLong(CALL, 1e18);              // entryMark = markC0, entryCumFunding = 0

        // One funding period at unchanged spot ⇒ cumFunding += markC0 ⇒ fundingU == im == collateral.
        vm.warp(block.timestamp + book.FUNDING_PERIOD());
        book.accrue(CALL);
        // Same-block downward move adds markLoss without extra funding.
        oracle.set(95e18);
        book.accrue(CALL);

        uint256 aliceCol     = book.traderCollateral(CALL_U, ALICE);
        uint256 netLoss      = book.netLossUsdc(CALL, ALICE);
        uint256 fundingAlone = book.pendingFunding(CALL, ALICE) / 1e12;

        assertEq(fundingAlone, aliceCol, "funding alone == collateral (old predicate: no-fire)");
        assertLe(fundingAlone, aliceCol, "funding alone does NOT exceed collateral");
        assertGt(netLoss, aliceCol,      "markLoss pushes netLoss over collateral -> insolvent");

        book.settle(CALL, ALICE);

        (uint256 qty,,) = book.positions(CALL_U, ALICE);
        assertEq(qty, 0, "alice position deleted after force-close");
        assertEq(book.traderCollateral(CALL_U, ALICE), 0, "alice collateral zeroed (floor)");
    }

    /// @dev settle fires on funding-driven insolvency (2 periods; funding > collateral).
    ///      netWritten decrements for alice while address(this) stays open.
    function test_settle_fires_funding_insolvency() public {
        uint256 markC0 = _mark(CALL);
        uint256 im     = 1e18 * markC0 / 1e18 / 1e12;

        vm.prank(ALICE);
        book.deposit(CALL, im);
        vm.prank(ALICE);
        book.openLong(CALL, 1e18);              // netWritten = 2e18 (this + alice)

        // 2 periods at unchanged mark ⇒ fundingU = 2·im > collateral(im).
        vm.warp(block.timestamp + 2 * book.FUNDING_PERIOD());
        book.accrue(CALL);

        assertGt(book.netLossUsdc(CALL, ALICE), book.traderCollateral(CALL_U, ALICE), "insolvent");

        book.settle(CALL, ALICE);

        (uint256 qty,,) = book.positions(CALL_U, ALICE);
        assertEq(qty, 0, "alice position cleared");
        (,,,, uint256 netW) = book.sideState(CALL_U);
        assertEq(netW, 1e18, "netWritten = 1e18 (address(this) still open)");
    }

    // ── netWritten symmetry ───────────────────────────────────────────────────

    function test_netWritten_zero_after_winning_close() public {
        oracle.set(110e18);
        book.accrue(CALL);
        book.close(CALL);
        (,,,, uint256 netW) = book.sideState(CALL_U);
        assertEq(netW, 0);
    }

    function test_netWritten_zero_after_losing_close() public {
        oracle.set(90e18);
        book.accrue(CALL);
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
