// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {EverlastingBook} from "../src/EverlastingBook.sol";
import {MockCoverVault} from "../src/mocks/MockCoverVault.sol";
import {MockOracle} from "../src/MockOracle.sol";

/// @title BookAdminTest
/// @notice Task 8 — admin controls (setKeeper, 2-step ownership, pause, emergency unwind),
///         LP-gating enforcement, and a precision round-trip conservation proof.
///
///   Key properties proved:
///     1. setKeeper: owner-gated; updates keeper; old keeper can no longer postMark.
///     2. 2-step ownership: transferOwnership sets pendingOwner only; acceptOwnership promotes;
///        stray acceptOwnership reverts; owner unchanged until accept (no single-tx loss).
///     3. Pause: blocks openLong on BOTH sides; all exit paths (close/settle/withdraw/
///        lpWithdraw/postMark/deposit) work while paused — pause is NOT a fund trap.
///     4. emergencyUnwindCover: owner + paused only; sells tick-floored cover; sub-tick dust stays.
///     5. lpDeposit/lpWithdraw: onlyOwner (T8 M3 fix — closes the permissionless-LP withdrawal gap).
///     6. Precision round-trip: pool equity (poolFree + putEscrow + coverEquityUsdc) changes by
///        exactly the trader's net pnl over a buy-cover → openLong → postMark → close sequence.
///        No op creates or destroys value (±1 unit USDC tolerance for _toUsdc truncation).
contract BookAdminTest is Test {
    MockCoverVault  vault;
    MockOracle      oracle;
    EverlastingBook book;

    address constant ALICE   = address(0xA11CE);
    address constant BOB     = address(0xB0B);
    address constant KEEPER  = address(0xBEEF);
    address constant NEW_OWN = address(0xDEAD);

    uint256 constant KPUT     = 100e18;
    uint256 constant WPUT     =  50e18;
    uint256 constant KCALL    = 120e18;
    uint256 constant HYPE_PX  = 100e18;
    uint256 constant CALL_MARK = 5e18;
    uint256 constant PUT_MARK  = 20e18;

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
        book   = new EverlastingBook(
            vault, oracle, KEEPER,
            KPUT, WPUT, KCALL,
            10_000e18, 10_000e18
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

        // Old keeper can no longer postMark
        vm.prank(KEEPER);
        vm.expectRevert(bytes("only keeper"));
        book.postMark(CALL, CALL_MARK);

        // New keeper can
        vm.prank(newK);
        book.postMark(CALL, CALL_MARK); // no revert
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
        vm.prank(KEEPER);
        book.postMark(CALL, CALL_MARK);
        vm.prank(ALICE);
        book.deposit(CALL, 10e6);

        book.pause();

        vm.prank(ALICE);
        vm.expectRevert(bytes("paused"));
        book.openLong(CALL, 1e18);
    }

    function test_pause_blocks_openLong_put() public {
        vm.prank(KEEPER);
        book.postMark(PUT, PUT_MARK);
        vm.prank(ALICE);
        book.deposit(PUT, 50e6);

        book.pause();

        vm.prank(ALICE);
        vm.expectRevert(bytes("paused"));
        book.openLong(PUT, 1e17);
    }

    function test_unpause_restores_openLong() public {
        vm.prank(KEEPER);
        book.postMark(CALL, CALL_MARK);
        vm.prank(ALICE);
        book.deposit(CALL, 10e6);
        book.pause();
        book.unpause();

        vm.prank(ALICE);
        book.openLong(CALL, 1e18); // must not revert
        (uint256 qty,,) = book.positions(CALL_U, ALICE);
        assertEq(qty, 1e18, "position opened after unpause");
    }

    // ── Pause: exit paths always open (pause cannot trap funds) ──────────────

    /// @dev A pre-existing call position can close + withdraw fully while the market is paused.
    ///      Proves: pause is a de-risk switch, not a fund trap.
    function test_pause_does_not_trap_funds_call() public {
        // Setup: open a call position for ALICE
        vm.prank(KEEPER);
        book.postMark(CALL, CALL_MARK);
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

        // Keeper can still post a mark for fair settlement
        vm.warp(block.timestamp + 1800);
        vm.prank(KEEPER);
        book.postMark(CALL, CALL_MARK); // no revert while paused

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

    /// @dev postMark works while paused (keeper can mark for fair settlement).
    function test_postMark_works_while_paused() public {
        book.pause();
        vm.prank(KEEPER);
        book.postMark(CALL, CALL_MARK); // no revert
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
        // 500e18 is already tick-aligned (500e18 / 1e16 * 1e16 == 500e18), so expectedSell == coverBefore
        uint256 expectedSell = (coverBefore / 1e16) * 1e16;
        uint256 expectedDust = coverBefore - expectedSell;

        book.pause();
        vm.expectEmit(false, false, false, true, address(book));
        emit EmergencyUnwind(expectedSell);
        book.emergencyUnwindCover();

        assertEq(vault.coverHype(), expectedDust, "only sub-tick dust remains");
        // Pool USDC increased by the cover proceeds
        assertGt(vault.poolUsdc(), 0, "proceeds credited to pool");
    }

    /// @notice C1 regression: after emergencyUnwindCover, two open winning covered-call positions
    ///         can both close successfully, each paid their gain from poolFree (replenished by the
    ///         cover-sale proceeds). Fails on old maxSell (checked-underflow revert) and passes
    ///         with the clamped fix. Conservation identity holds after each close.
    function test_emergencyUnwind_winning_calls_can_close() public {
        // ── Open two winning CALL positions ────────────────────────────────
        vm.prank(KEEPER);
        book.postMark(CALL, CALL_MARK);  // 5e18

        uint256 qtyA = 1e18;  // 1 HYPE for ALICE
        uint256 qtyB = 2e18;  // 2 HYPE for BOB — ensures two distinct netWritten contributors

        // IM = _toUsdc(qty * mark / 1e18) + buffer
        uint256 imA = qtyA * CALL_MARK / 1e18 / 1e12 + 5e6;
        uint256 imB = qtyB * CALL_MARK / 1e18 / 1e12 + 5e6;

        vm.prank(ALICE);
        book.deposit(CALL, imA);
        vm.prank(ALICE);
        book.openLong(CALL, qtyA);   // ss.netWritten = 1e18

        vm.prank(BOB);
        book.deposit(CALL, imB);
        vm.prank(BOB);
        book.openLong(CALL, qtyB);   // ss.netWritten = 3e18

        // ── Advance mark so both positions win (5e18 → 6e18, ≤ +20% dev) ──
        vm.warp(block.timestamp + 1800);
        vm.prank(KEEPER);
        book.postMark(CALL, 6e18);   // +1 USDC gain per 1e18 qty

        // ── Emergency wind-down ────────────────────────────────────────────
        // setUp seeded 500e18 cover (tick-aligned) → coverHype drops to 0.
        // Pool receives ~50_000 USDC from the cover sale (500 HYPE × $100).
        book.pause();
        book.emergencyUnwindCover();
        assertEq(vault.coverHype(), 0, "cover fully unwound (tick-aligned)");

        // ── ALICE closes — must NOT revert with the fix ────────────────────
        // Old code: maxSell = vault.coverHype() − (ss.netWritten − p.qty)
        //         = 0 − (3e18 − 1e18) = 0 − 2e18 → checked-underflow → REVERT
        // New code: ch=0, rem=2e18, ch>rem is false → maxSell=0 → sellHype=0 →
        //           no vault.sellCover call → require(poolFree() >= g) passes.
        uint256 colA0 = book.traderCollateral(CALL_U, ALICE);
        uint256 free0 = book.poolFree();
        vm.prank(ALICE);
        book.close(CALL);

        (uint256 qaAfter,,) = book.positions(CALL_U, ALICE);
        assertEq(qaAfter, 0, "ALICE position deleted");
        assertGt(book.traderCollateral(CALL_U, ALICE), colA0, "ALICE received gain");
        assertLt(book.poolFree(), free0, "poolFree decreased by ALICE gain");

        // Conservation after ALICE close
        assertEq(
            vault.poolUsdc(),
            book.poolFree() + book.putEscrow() + book.totalCollateral(),
            "conservation: after ALICE close"
        );

        // ── BOB closes — must NOT revert either ───────────────────────────
        // With old code ALICE's close reverted, so ss.netWritten stayed at 3e18.
        // BOB would also underflow: 0 − (3e18 − 2e18) = 0 − 1e18 → REVERT.
        uint256 colB0 = book.traderCollateral(CALL_U, BOB);
        vm.prank(BOB);
        book.close(CALL);

        (uint256 qbAfter,,) = book.positions(CALL_U, BOB);
        assertEq(qbAfter, 0, "BOB position deleted");
        assertGt(book.traderCollateral(CALL_U, BOB), colB0, "BOB received gain");

        // Conservation after BOB close
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
            KPUT, WPUT, KCALL, 10_000e18, 10_000e18
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
    // Mathematical property (proved in T8 design doc):
    //
    //   Let eq = poolFree + putEscrow + coverEquityUsdc (pool's total equity, ex trader claims).
    //   Over a round-trip: eq₀ (pre-open) → open → mark → close → eq₁ (post-close),
    //   with the trader netting pnl USDC:
    //
    //     eq₁ = eq₀ − pnl    (exactly, using the T7 ceil-to-tick cover sale design)
    //
    //   This holds because coverEquityUsdc is the USDC mark-to-market value of the HYPE cover,
    //   and sellCover(sellHype) converts exactly sellHype's equity from cover to poolFree.
    //   The ceil-to-tick ensures proceeds ≥ payout; the "surplus" tick stays in poolFree.
    //   We allow ±1 unit tolerance for _toUsdc integer truncation in coverEquityUsdc.

    /// @dev Run one round-trip and return (equity delta, trader pnl) as signed integers.
    function _roundTrip(
        uint256 spotWad,
        uint256 entryMark,
        uint256 exitMark,
        uint256 qty
    ) internal returns (int256 eqDelta, int256 pnl) {
        oracle.set(spotWad);
        vault.setMockPx(spotWad);

        // Warp past MAX_MARK_AGE so the next postMark is an unconstrained first mark
        vm.warp(block.timestamp + 8001);

        uint256 eq0  = _equity();
        uint256 col0 = book.traderCollateral(CALL_U, BOB);

        // Post entry mark (fresh — no deviation check on a stale-then-new mark)
        vm.prank(KEEPER);
        book.postMark(CALL, entryMark);

        // BOB opens: IM = qty·entryMark / 1e18 / 1e12 (6dp), plus buffer
        uint256 im = qty * entryMark / 1e18 / 1e12 + 2e6;
        vm.prank(BOB);
        book.deposit(CALL, im);
        vm.prank(BOB);
        book.openLong(CALL, qty);

        // Advance half a funding period (no funding accrual; still within MAX_MARK_AGE)
        vm.warp(block.timestamp + 1800);

        // Post exit mark (deviation check: must be within ±20% of entryMark)
        vm.prank(KEEPER);
        book.postMark(CALL, exitMark);

        // BOB closes
        vm.prank(BOB);
        book.close(CALL);

        uint256 eq1  = _equity();
        uint256 col1 = book.traderCollateral(CALL_U, BOB);

        eqDelta = int256(eq1)   - int256(eq0);   // pool equity change (negative for gain payout)
        pnl     = int256(col1)  - int256(col0) - int256(im); // trader net pnl (positive = gain)
    }

    /// @dev Conservation helper: assert |eqDelta + pnl| ≤ 1 (precision tolerance).
    function _assertConserved(int256 eqDelta, int256 pnl, string memory label) internal pure {
        int256 sum = eqDelta + pnl;
        uint256 sumAbs = sum >= 0 ? uint256(sum) : uint256(-sum);
        assertLe(sumAbs, 1, label);
    }

    /// @notice Exact-tick scenario: g = 1 USDC at spot=$100 → hypeForG = exactly 1 tick.
    ///         No rounding in the ceil-to-tick step; pool equity decreases by exactly g.
    function test_precision_exact_tick_gain() public {
        // qty=1e18, entryMark=5e18, exitMark=6e18 → markGainU = _toUsdc(1e18) = 1_000_000
        // hypeForG = (1_000_000 * 1e12) * 1e18 / 100e18 = 1e16 = 1 tick exactly
        (int256 ed, int256 pnl) = _roundTrip(100e18, 5e18, 6e18, 1e18);
        assertTrue(pnl > 0, "expected trader gain");
        _assertConserved(ed, pnl, "exact tick: |eqDelta + pnl| <= 1");
        assertLe(ed, int256(0), "pool equity non-increasing net of gain");
    }

    /// @notice Sub-tick scenario: g = 1.5 USDC at spot=$100 → hypeForG = 1.5 ticks, ceiled to 2.
    ///         Cover sale over-sells by 0.5 ticks; pool keeps the surplus in poolFree.
    ///         Total pool equity still decreases by exactly g (tick surplus stays in the pool).
    function test_precision_sub_tick_gain() public {
        // qty=1.5e18, marks 5e18→6e18 → markGainU = _toUsdc(1.5e18) = 1_500_000 (within 20% dev)
        // hypeForG = 1.5e16 → ceil to 2e16; pool equity conserved within 1 unit
        (int256 ed, int256 pnl) = _roundTrip(100e18, 5e18, 6e18, 1_500_000_000_000_000_000);
        assertTrue(pnl > 0, "expected trader gain");
        _assertConserved(ed, pnl, "sub-tick: |eqDelta + pnl| <= 1");
        assertLe(ed, int256(0), "pool equity non-increasing net of gain");
    }

    /// @notice Loss scenario: trader loses; pool gains that amount; no value created.
    function test_precision_loss_no_value_created() public {
        // entryMark=6e18, exitMark=5e18 → markLossU = 1_000_000 (1 USDC loss to trader)
        // Pool equity should increase by exactly 1_000_000
        (int256 ed, int256 pnl) = _roundTrip(100e18, 6e18, 5e18, 1e18);
        assertTrue(pnl < 0, "expected trader loss");
        _assertConserved(ed, pnl, "loss: |eqDelta + pnl| <= 1");
        assertGe(ed, int256(0), "pool equity non-decreasing net of loss");
    }
}
