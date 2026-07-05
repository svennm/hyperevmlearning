// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {EverlastingBook} from "../src/EverlastingBook.sol";
import {MockCoverVault} from "../src/mocks/MockCoverVault.sol";
import {MockOracle} from "../src/MockOracle.sol";
import {MockVol} from "../src/mocks/MockVol.sol";

/// @title BookAdminTest
/// @notice Task 8 — admin controls (setKeeper, 2-step ownership, pause, emergency unwind),
///         LP-gating enforcement, and a precision round-trip conservation proof. Migrated to the
///         autonomous mark (Task 5): there is no keeper postMark — the mark is the on-chain computed
///         fair value, refreshed permissionlessly via accrue and driven for tests by the oracle.
///
///   Key properties proved:
///     1. setKeeper: owner-gated; updates keeper; emits KeeperChanged. (The keeper no longer gates
///        any price path — the mark is autonomous — so there is no postMark-authority to check.)
///     2. 2-step ownership: transferOwnership sets pendingOwner only; acceptOwnership promotes;
///        stray acceptOwnership reverts; owner unchanged until accept (no single-tx loss).
///     3. Pause: blocks openLong on BOTH sides; all exit paths (close/settle/withdraw/lpWithdraw/
///        accrue/deposit) work while paused — pause is NOT a fund trap.
///     4. emergencyUnwindCover: owner + paused only; sells tick-floored cover; sub-tick dust stays.
///     5. lpDeposit/lpWithdraw: onlyOwner (T8 M3 fix — closes the permissionless-LP withdrawal gap).
///     6. Precision round-trip: pool equity (poolFree + putEscrow + coverEquityUsdc) changes by
///        exactly the trader's net pnl over a buy-cover → openLong → accrue → close sequence. The
///        mark is moved by the ORACLE (cover px kept fixed), so no op creates or destroys value
///        (±1 unit USDC tolerance for _toUsdc truncation).
contract BookAdminTest is Test {
    MockCoverVault  vault;
    MockOracle      oracle;
    MockVol         mockVol;
    EverlastingBook book;

    address constant ALICE   = address(0xA11CE);
    address constant BOB     = address(0xB0B);
    address constant KEEPER  = address(0xBEEF);
    address constant NEW_OWN = address(0xDEAD);

    uint256 constant KPUT     = 100e18;
    uint256 constant WPUT     =  50e18;
    uint256 constant KCALL    = 120e18;
    uint256 constant HYPE_PX  = 100e18;

    EverlastingBook.Side private constant CALL = EverlastingBook.Side.COVERED_CALL;
    EverlastingBook.Side private constant PUT  = EverlastingBook.Side.PUT;
    uint8 private constant CALL_U = 1;

    // ── Declare all events for vm.expectEmit ─────────────────────────────────
    event KeeperChanged(address indexed oldKeeper, address indexed newKeeper);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event EmergencyUnwind(uint256 hypeWad);
    event LpDeposited(address indexed lp, uint256 amt);
    event LpWithdrawn(address indexed lp, uint256 amt);

    function setUp() public {
        vault  = new MockCoverVault();
        oracle = new MockOracle();
        mockVol = new MockVol();
        book   = new EverlastingBook(
            vault, oracle, KEEPER,
            KPUT, WPUT, KCALL,
            10_000e18, 10_000e18,
            mockVol
        );
        oracle.set(HYPE_PX);
        vault.setMockPx(HYPE_PX);
        vm.warp(1);

        // Seed: 500 USDC pool-free + 500 HYPE cover (cost 50_000 USDC). Owner = address(this).
        book.lpDeposit(500_000e6);
        vault.buyCover(500e18, type(uint256).max); // costs 50_000e6, poolFree → 450_000e6
    }

    // ── Internal helpers ──────────────────────────────────────────────────────

    /// @dev Pool total equity: free USDC + locked put escrow + mark-to-market value of cover HYPE.
    function _equity() internal view returns (uint256) {
        return book.poolFree() + book.putEscrow() + vault.coverEquityUsdc();
    }

    function _mark(EverlastingBook.Side side) internal view returns (uint256 m) {
        (m,,,,) = book.sideState(uint8(side));
    }

    // ── setKeeper ────────────────────────────────────────────────────────────

    function test_setKeeper_reverts_nonOwner() public {
        vm.prank(ALICE);
        vm.expectRevert(bytes("only owner"));
        book.setKeeper(address(0x9999));
    }

    function test_setKeeper_reverts_zero() public {
        vm.expectRevert(bytes("keeper=0"));
        book.setKeeper(address(0));
    }

    function test_setKeeper_updates_and_emits() public {
        address newK = address(0xCAFE);
        vm.expectEmit(true, true, false, false, address(book));
        emit KeeperChanged(KEEPER, newK);
        book.setKeeper(newK);
        assertEq(book.keeper(), newK, "keeper updated");
    }

    // ── 2-step ownership ─────────────────────────────────────────────────────

    function test_transferOwnership_reverts_nonOwner() public {
        vm.prank(ALICE);
        vm.expectRevert(bytes("only owner"));
        book.transferOwnership(ALICE);
    }

    function test_transferOwnership_sets_pending_emits() public {
        vm.expectEmit(true, true, false, false, address(book));
        emit OwnershipTransferStarted(address(this), NEW_OWN);
        book.transferOwnership(NEW_OWN);

        assertEq(book.pendingOwner(), NEW_OWN, "pendingOwner set");
        assertEq(book.owner(), address(this), "owner unchanged until accept");
    }

    function test_acceptOwnership_promotes_emits() public {
        book.transferOwnership(NEW_OWN);

        vm.expectEmit(true, true, false, false, address(book));
        emit OwnershipTransferred(address(this), NEW_OWN);
        vm.prank(NEW_OWN);
        book.acceptOwnership();

        assertEq(book.owner(), NEW_OWN, "owner promoted");
        assertEq(book.pendingOwner(), address(0), "pending cleared");
    }

    function test_stray_acceptOwnership_reverts() public {
        book.transferOwnership(NEW_OWN);

        vm.prank(ALICE); // not the pending owner
        vm.expectRevert(bytes("not pending"));
        book.acceptOwnership();

        assertEq(book.owner(), address(this), "owner unchanged after stray accept");
    }

    function test_no_single_tx_ownership_loss() public {
        // After transferOwnership alone, the owner can still exercise owner powers.
        book.transferOwnership(NEW_OWN);
        assertEq(book.owner(), address(this), "owner unchanged mid-transfer");
        book.setKeeper(KEEPER); // no revert — still owner
    }

    // ── Pause: blocks openLong on both sides ─────────────────────────────────

    function test_pause_emits_and_sets_flag() public {
        vm.expectEmit(true, false, false, false, address(book));
        emit Paused(address(this));
        book.pause();
        assertTrue(book.paused(), "paused flag set");
    }

    function test_unpause_emits_and_clears_flag() public {
        book.pause();
        vm.expectEmit(true, false, false, false, address(book));
        emit Unpaused(address(this));
        book.unpause();
        assertFalse(book.paused(), "paused flag cleared");
    }

    function test_pause_reverts_nonOwner() public {
        vm.prank(ALICE);
        vm.expectRevert(bytes("only owner"));
        book.pause();
    }

    function test_unpause_reverts_nonOwner() public {
        book.pause();
        vm.prank(ALICE);
        vm.expectRevert(bytes("only owner"));
        book.unpause();
    }

    function test_pause_blocks_openLong_call() public {
        vm.prank(ALICE);
        book.deposit(CALL, 10e6);

        book.pause();

        vm.prank(ALICE);
        vm.expectRevert(bytes("paused")); // whenNotPaused reverts before the auto-accrue
        book.openLong(CALL, 1e18);
    }

    function test_pause_blocks_openLong_put() public {
        vm.prank(ALICE);
        book.deposit(PUT, 50e6);

        book.pause();

        vm.prank(ALICE);
        vm.expectRevert(bytes("paused"));
        book.openLong(PUT, 1e17);
    }

    function test_unpause_restores_openLong() public {
        vm.prank(ALICE);
        book.deposit(CALL, 10e6);
        book.pause();
        book.unpause();

        vm.prank(ALICE);
        book.openLong(CALL, 1e18); // must not revert — mark auto-refreshed
        (uint256 qty,,) = book.positions(CALL_U, ALICE);
        assertEq(qty, 1e18, "position opened after unpause");
    }

    // ── Pause: exit paths always open (pause cannot trap funds) ──────────────

    /// @dev A pre-existing call position can close + withdraw fully while the market is paused.
    ///      Proves: pause is a de-risk switch, not a fund trap.
    function test_pause_does_not_trap_funds_call() public {
        // Setup: open a call position for ALICE
        uint256 im = 10e6;
        vm.prank(ALICE);
        book.deposit(CALL, im);
        vm.prank(ALICE);
        book.openLong(CALL, 1e18);

        (uint256 qty,,) = book.positions(CALL_U, ALICE);
        assertEq(qty, 1e18, "position open before pause");

        // Pause
        book.pause();
        assertTrue(book.paused(), "market paused");

        // The mark can still be refreshed permissionlessly for fair settlement while paused.
        vm.warp(block.timestamp + 1800);
        book.accrue(CALL); // no revert while paused

        // ALICE can still close
        vm.prank(ALICE);
        book.close(CALL); // must not revert while paused
        (uint256 qtyAfter,,) = book.positions(CALL_U, ALICE);
        assertEq(qtyAfter, 0, "position closed while paused");

        // ALICE can still withdraw
        uint256 col = book.traderCollateral(CALL_U, ALICE);
        if (col > 0) {
            vm.prank(ALICE);
            book.withdraw(CALL, col); // must not revert while paused
            assertEq(book.traderCollateral(CALL_U, ALICE), 0, "collateral withdrawn while paused");
        }
    }

    /// @dev deposit works while paused (trader can always add margin).
    function test_deposit_works_while_paused() public {
        book.pause();
        vm.prank(ALICE);
        book.deposit(CALL, 10e6); // no revert
        assertEq(book.traderCollateral(CALL_U, ALICE), 10e6, "deposit credited while paused");
    }

    /// @dev accrue works while paused (mark can be refreshed for fair settlement). Replaces the old
    ///      keeper "postMark works while paused" — accrue is now the permissionless maintenance path.
    function test_accrue_works_while_paused() public {
        book.pause();
        book.accrue(CALL); // no revert
    }

    /// @dev lpWithdraw (owner) works while paused.
    function test_lpWithdraw_works_while_paused() public {
        book.pause();
        uint256 free = book.poolFree();
        assertGt(free, 0, "pool has free USDC");
        book.lpWithdraw(free / 2); // no revert
    }

    // ── emergencyUnwindCover ─────────────────────────────────────────────────

    function test_emergencyUnwind_reverts_notPaused() public {
        vm.expectRevert(bytes("not paused"));
        book.emergencyUnwindCover();
    }

    function test_emergencyUnwind_reverts_nonOwner() public {
        book.pause();
        vm.prank(ALICE);
        vm.expectRevert(bytes("only owner"));
        book.emergencyUnwindCover();
    }

    function test_emergencyUnwind_sells_floored_cover_emits() public {
        uint256 coverBefore = vault.coverHype(); // 500e18 from setUp (tick-aligned)
        assertGt(coverBefore, 0, "has cover");
        uint256 expectedSell = (coverBefore / 1e16) * 1e16;
        uint256 expectedDust = coverBefore - expectedSell;

        book.pause();
        vm.expectEmit(false, false, false, true, address(book));
        emit EmergencyUnwind(expectedSell);
        book.emergencyUnwindCover();

        assertEq(vault.coverHype(), expectedDust, "only sub-tick dust remains");
        assertGt(vault.poolUsdc(), 0, "proceeds credited to pool");
    }

    /// @notice C1 regression: after emergencyUnwindCover, two open winning covered-call positions
    ///         can both close successfully, each paid their gain from poolFree (replenished by the
    ///         cover-sale proceeds). Both positions win by DRIVING THE ORACLE UP before the unwind.
    ///         Conservation identity holds after each close.
    function test_emergencyUnwind_winning_calls_can_close() public {
        // ── Open two CALL positions at the S=100 computed mark ─────────────────
        book.accrue(CALL);
        uint256 entry = _mark(CALL);

        uint256 qtyA = 1e18;  // 1 HYPE for ALICE
        uint256 qtyB = 2e18;  // 2 HYPE for BOB — two distinct netWritten contributors

        uint256 imA = qtyA * entry / 1e18 / 1e12 + 5e6;
        uint256 imB = qtyB * entry / 1e18 / 1e12 + 5e6;

        vm.prank(ALICE);
        book.deposit(CALL, imA);
        vm.prank(ALICE);
        book.openLong(CALL, qtyA);   // ss.netWritten = 1e18

        vm.prank(BOB);
        book.deposit(CALL, imB);
        vm.prank(BOB);
        book.openLong(CALL, qtyB);   // ss.netWritten = 3e18

        // ── Drive spot up so both positions win (100 → 110); no funding (< 1 period) ──
        vm.warp(block.timestamp + 1800);
        oracle.set(110e18);
        book.accrue(CALL);
        assertGt(_mark(CALL), entry, "mark rose (both positions winning)");

        // ── Emergency wind-down ────────────────────────────────────────────
        book.pause();
        book.emergencyUnwindCover();
        assertEq(vault.coverHype(), 0, "cover fully unwound (tick-aligned)");

        // ── ALICE closes — paid from poolFree (cover exhausted → maxSell clamps to 0, no revert) ──
        uint256 colA0 = book.traderCollateral(CALL_U, ALICE);
        uint256 free0 = book.poolFree();
        vm.prank(ALICE);
        book.close(CALL);

        (uint256 qaAfter,,) = book.positions(CALL_U, ALICE);
        assertEq(qaAfter, 0, "ALICE position deleted");
        assertGt(book.traderCollateral(CALL_U, ALICE), colA0, "ALICE received gain");
        assertLt(book.poolFree(), free0, "poolFree decreased by ALICE gain");
        assertEq(
            vault.poolUsdc(),
            book.poolFree() + book.putEscrow() + book.totalCollateral(),
            "conservation: after ALICE close"
        );

        // ── BOB closes — must NOT revert either ───────────────────────────
        uint256 colB0 = book.traderCollateral(CALL_U, BOB);
        vm.prank(BOB);
        book.close(CALL);

        (uint256 qbAfter,,) = book.positions(CALL_U, BOB);
        assertEq(qbAfter, 0, "BOB position deleted");
        assertGt(book.traderCollateral(CALL_U, BOB), colB0, "BOB received gain");
        assertEq(
            vault.poolUsdc(),
            book.poolFree() + book.putEscrow() + book.totalCollateral(),
            "conservation: after BOB close"
        );
    }

    function test_emergencyUnwind_respects_sub_tick_dust() public {
        // Build a fresh book+vault with non-tick-aligned cover: 1.5 ticks = 15e15 HYPE
        MockCoverVault v2 = new MockCoverVault();
        v2.setMockPx(HYPE_PX);
        v2.pullUsdc(address(0), 10_000e6);
        uint256 dustAmount = 1e16 + 5e15; // = 15e15 HYPE (1.5 ticks)
        v2.buyCover(dustAmount, type(uint256).max);
        assertEq(v2.coverHype(), dustAmount, "cover = 1.5 ticks");

        EverlastingBook b2 = new EverlastingBook(
            v2, oracle, KEEPER,
            KPUT, WPUT, KCALL, 10_000e18, 10_000e18, mockVol
        );
        b2.pause();

        uint256 floored = (dustAmount / 1e16) * 1e16; // = 1e16 (1 tick)
        b2.emergencyUnwindCover();

        assertEq(v2.coverHype(), dustAmount - floored, "sub-tick dust = 5e15 preserved");
        assertEq(v2.coverHype(), 5e15);
    }

    // ── LP-gating: onlyOwner ──────────────────────────────────────────────────

    function test_lpDeposit_reverts_nonOwner() public {
        vm.prank(ALICE);
        vm.expectRevert(bytes("only owner"));
        book.lpDeposit(1e6);
    }

    function test_lpWithdraw_reverts_nonOwner() public {
        vm.prank(ALICE);
        vm.expectRevert(bytes("only owner"));
        book.lpWithdraw(1e6);
    }

    function test_lpDeposit_owner_emits() public {
        uint256 freeBefore = book.poolFree();
        vm.expectEmit(true, false, false, true, address(book));
        emit LpDeposited(address(this), 50e6);
        book.lpDeposit(50e6);
        assertEq(book.poolFree(), freeBefore + 50e6, "poolFree raised");
    }

    function test_lpWithdraw_owner_emits() public {
        uint256 free = book.poolFree();
        vm.expectEmit(true, false, false, true, address(book));
        emit LpWithdrawn(address(this), 50e6);
        book.lpWithdraw(50e6);
        assertEq(book.poolFree(), free - 50e6, "poolFree reduced");
    }

    // ── Precision round-trip: no op creates or destroys value ────────────────
    //
    //   Let eq = poolFree + putEscrow + coverEquityUsdc (pool's total equity, ex trader claims).
    //   Over a round-trip eq₀ (pre-open) → open → oracle-move → close → eq₁, with the trader netting
    //   pnl USDC:  eq₁ = eq₀ − pnl  (exactly, using the T7 ceil-to-tick cover sale; ±1 for _toUsdc
    //   truncation in coverEquityUsdc). The cover px is kept fixed so coverEquity only moves via sales.

    /// @dev Run one round-trip and return (equity delta, trader pnl). The mark is moved by the ORACLE
    ///      (spot0 → spot1); same block so there is no funding — PnL is pure mark PnL.
    function _roundTrip(uint256 spot0, uint256 spot1, uint256 qty)
        internal
        returns (int256 eqDelta, int256 pnl)
    {
        oracle.set(spot0);
        book.accrue(CALL);
        uint256 entryMark = _mark(CALL);

        uint256 eq0  = _equity();
        uint256 col0 = book.traderCollateral(CALL_U, BOB);

        uint256 im = qty * entryMark / 1e18 / 1e12 + 2e6;
        vm.prank(BOB);
        book.deposit(CALL, im);
        vm.prank(BOB);
        book.openLong(CALL, qty);

        // Move the mark via the oracle (same block ⇒ no funding).
        oracle.set(spot1);
        book.accrue(CALL);

        vm.prank(BOB);
        book.close(CALL);

        uint256 eq1  = _equity();
        uint256 col1 = book.traderCollateral(CALL_U, BOB);

        eqDelta = int256(eq1)  - int256(eq0);        // pool equity change (negative for gain payout)
        pnl     = int256(col1) - int256(col0) - int256(im); // trader net pnl (positive = gain)
    }

    /// @dev Conservation helper: assert |eqDelta + pnl| ≤ 1 (precision tolerance).
    function _assertConserved(int256 eqDelta, int256 pnl, string memory label) internal pure {
        int256 sum = eqDelta + pnl;
        uint256 sumAbs = sum >= 0 ? uint256(sum) : uint256(-sum);
        assertLe(sumAbs, 1, label);
    }

    /// @notice Gain scenario (spot 100→110): trader wins; pool equity falls by exactly the gain.
    function test_precision_gain_conserved() public {
        (int256 ed, int256 pnl) = _roundTrip(100e18, 110e18, 1e18);
        assertTrue(pnl > 0, "expected trader gain");
        _assertConserved(ed, pnl, "gain: |eqDelta + pnl| <= 1");
        assertLe(ed, int256(0), "pool equity non-increasing net of gain");
    }

    /// @notice Larger-qty gain (spot 100→110, qty=1.5): the ceil-to-tick cover sale still conserves.
    function test_precision_gain_larger_qty_conserved() public {
        (int256 ed, int256 pnl) = _roundTrip(100e18, 110e18, 1_500_000_000_000_000_000);
        assertTrue(pnl > 0, "expected trader gain");
        _assertConserved(ed, pnl, "larger-qty gain: |eqDelta + pnl| <= 1");
        assertLe(ed, int256(0), "pool equity non-increasing net of gain");
    }

    /// @notice Loss scenario (spot 110→100): trader loses; pool gains that amount; no value created.
    function test_precision_loss_no_value_created() public {
        (int256 ed, int256 pnl) = _roundTrip(110e18, 100e18, 1e18);
        assertTrue(pnl < 0, "expected trader loss");
        _assertConserved(ed, pnl, "loss: |eqDelta + pnl| <= 1");
        assertGe(ed, int256(0), "pool equity non-decreasing net of loss");
    }
}
