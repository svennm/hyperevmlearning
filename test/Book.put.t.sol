// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {EverlastingBook} from "../src/EverlastingBook.sol";
import {MockCoverVault} from "../src/mocks/MockCoverVault.sol";
import {MockOracle} from "../src/MockOracle.sol";

/// @title BookPutTest
/// @notice Task 6 — PUT side folded into EverlastingBook on the SHARED pool (slice-2 escrow model).
///   Covers:
///     - open escrows exactly qty·Wput (putEscrow rises, poolFree drops)
///     - "put: IM" and "put: pool escrow" revert paths
///     - "cap" revert on aggregate open put qty
///     - postMark(PUT) rejects newMark > Wput (the ≤W clamp; the put-side difference vs call)
///     - winning close pays the capped payout with escrow RELEASED FIRST (F2: no false revert
///       even when poolFree is exactly 0 immediately before the close)
///     - losing close floors at collateral (auto-settle) and releases escrow
///     - settle fires on funding-driven insolvency (netLossUsdc via the shared predicate)
///     - PUT + CALL coexist on ONE pool with the conservation invariant holding throughout,
///       and neither side ever spends the other's escrow/cover/collateral
///
///   Conservation invariant (T7): vault.poolUsdc() == poolFree() + putEscrow + totalCollateral.
contract BookPutTest is Test {
    MockCoverVault  vault;
    MockOracle      oracle;
    EverlastingBook book;

    address constant ALICE = address(0xA11CE);

    uint256 constant KPUT      = 100e18;
    uint256 constant WPUT      =  50e18;  // put max payout / unit → escrow per unit
    uint256 constant KCALL     = 120e18;
    uint256 constant HYPE_PX   = 100e18;  // $100 / HYPE (WAD)
    uint256 constant PUT_MARK   = 20e18;  // seed put mark (a premium in [0, Wput])
    uint256 constant FUNDING_PERIOD = 3600;
    uint256 constant MAX_MARK_AGE   = 7200;

    EverlastingBook.Side private constant PUT  = EverlastingBook.Side.PUT;
    EverlastingBook.Side private constant CALL = EverlastingBook.Side.COVERED_CALL;
    uint8 private constant PUT_U  = 0;
    uint8 private constant CALL_U = 1;

    function setUp() public {
        vault  = new MockCoverVault();
        oracle = new MockOracle();
        book   = new EverlastingBook(
            vault, oracle, address(this), // keeper = test contract
            KPUT, WPUT, KCALL,
            10_000e18, // putCapNotional
            10_000e18  // callCapNotional
        );

        oracle.set(100e18);       // spot $100 == Kput → put intrinsic 0; call OTM
        vault.setMockPx(HYPE_PX);
        vm.warp(1);
    }

    // ── helpers ────────────────────────────────────────────────────────────────

    /// @dev Seed the pool's OWN free USDC (physical USDC with NO trader claim → poolFree rises).
    function _seedPoolFree(uint256 amt) internal {
        vault.pullUsdc(address(this), amt);
    }

    /// @dev The conservation identity T7 fuzzes. poolFree() reverts on underflow, so a successful
    ///      call already proves poolUsdc ≥ totalCollateral + putEscrow; the equality re-confirms it.
    function _assertConservation(string memory tag) internal view {
        assertEq(
            vault.poolUsdc(),
            book.poolFree() + book.putEscrow() + book.totalCollateral(),
            tag
        );
        // totalCollateral must equal the live sum of both sides' per-trader collateral.
        assertEq(
            book.totalCollateral(),
            book.traderCollateral(PUT_U, address(this))
                + book.traderCollateral(CALL_U, address(this))
                + book.traderCollateral(PUT_U, ALICE)
                + book.traderCollateral(CALL_U, ALICE),
            string.concat(tag, " :: totalCollateral == sum traderCollateral")
        );
    }

    // ── open: escrow = qty·W ─────────────────────────────────────────────────────

    /// @dev Opening a put locks exactly qty·Wput of the pool's free USDC as escrow.
    function test_put_open_escrows_qtyW() public {
        _seedPoolFree(100e6);
        book.deposit(PUT, 60e6);
        book.postMark(PUT, PUT_MARK);

        uint256 poolFreeBefore = book.poolFree(); // 160e6 pool − 60e6 collateral = 100e6
        assertEq(poolFreeBefore, 100e6, "poolFree before open");
        assertEq(book.putEscrow(), 0, "no escrow yet");

        book.openLong(PUT, 1e18); // IM = _toUsdc(1e18·50e18/1e18) = 50e6

        assertEq(book.putEscrow(), 50e6, "putEscrow == qty*W");
        assertEq(book.poolFree(), poolFreeBefore - 50e6, "poolFree dropped by qty*W");

        (uint256 qty, uint256 entryMark,) = book.positions(PUT_U, address(this));
        assertEq(qty, 1e18, "position qty");
        assertEq(entryMark, PUT_MARK, "entryMark");
        (,,,, uint256 netW) = book.sideState(PUT_U);
        assertEq(netW, 1e18, "put netWritten");
        _assertConservation("open");
    }

    // ── open reverts ────────────────────────────────────────────────────────────

    /// @dev Trader collateral below escrow IM → "put: IM".
    function test_put_open_revert_IM() public {
        _seedPoolFree(100e6);
        book.deposit(PUT, 10e6);      // < IM = 50e6
        book.postMark(PUT, PUT_MARK);

        vm.expectRevert(bytes("put: IM"));
        book.openLong(PUT, 1e18);
    }

    /// @dev Trader has the IM, but the pool has NO free USDC of its own to lock → "put: pool escrow".
    ///      Deposits raise poolUsdc AND collateral in lockstep, so deposit alone leaves poolFree = 0;
    ///      the escrow must come from the pool's own capital, not the trader's margin.
    function test_put_open_revert_pool_escrow() public {
        book.deposit(PUT, 50e6);      // collateral = IM, but poolFree stays 0 (no separate seed)
        book.postMark(PUT, PUT_MARK);
        assertEq(book.poolFree(), 0, "no pool-free USDC");

        vm.expectRevert(bytes("put: pool escrow"));
        book.openLong(PUT, 1e18);
    }

    /// @dev Aggregate open put qty over the cap → "cap" (checked after IM + pool escrow pass).
    function test_put_open_revert_cap() public {
        EverlastingBook capBook = new EverlastingBook(
            vault, oracle, address(this), KPUT, WPUT, KCALL, 2e18, 10_000e18 // putCap = 2e18
        );
        // Fund pool-free + trader collateral for a 3e18 open (IM = _toUsdc(3e18·50e18/1e18) = 150e6)
        vault.pullUsdc(address(this), 200e6);              // poolUsdc = 200e6
        capBook.deposit(PUT, 200e6);                        // poolFree stays 200e6
        capBook.postMark(PUT, PUT_MARK);

        vm.expectRevert(bytes("cap"));
        capBook.openLong(PUT, 3e18); // netWritten 3e18 > putCap 2e18
    }

    // ── postMark(PUT): ≤W clamp ──────────────────────────────────────────────────

    /// @dev The put-side difference from the call side: postMark rejects newMark > Wput.
    function test_postMark_put_reverts_above_W() public {
        vm.expectRevert(bytes("mark>W"));
        book.postMark(PUT, WPUT + 1e18); // 51e18 > 50e18; intrinsic 0 so the clamp is what bites
    }

    /// @dev newMark == Wput is accepted (boundary).
    function test_postMark_put_accepts_at_W() public {
        book.postMark(PUT, WPUT);
        (uint256 m,,,,) = book.sideState(PUT_U);
        assertEq(m, WPUT, "mark at cap accepted");
    }

    // ── winning close: escrow released FIRST (F2 no-false-revert) ────────────────

    /// @dev Set poolFree to EXACTLY 0 before close (all pool-free USDC is locked as escrow).
    ///      The winning payout is only fundable because the escrow is released FIRST; a
    ///      release-after-pay ordering would revert here. Payout is bounded by escrow (capped).
    function test_put_winning_close_escrow_released_first() public {
        _seedPoolFree(50e6);          // pool's own free USDC == the escrow it must lock
        book.deposit(PUT, 50e6);      // trader IM
        book.postMark(PUT, PUT_MARK); // 20e18

        book.openLong(PUT, 1e18);     // escrow 50e6 locked
        assertEq(book.poolFree(), 0, "poolFree fully locked as escrow before close");

        book.postMark(PUT, 24e18);    // +20% (deviation boundary); same block → no funding

        uint256 colBefore = book.traderCollateral(PUT_U, address(this)); // 50e6
        book.close(PUT);              // g = _toUsdc(1e18·(24-20)e18/1e18) = 4e6 ≤ escrow 50e6

        assertEq(book.putEscrow(), 0, "escrow released");
        assertEq(book.traderCollateral(PUT_U, address(this)), colBefore + 4e6, "trader paid g");
        (uint256 qty,,) = book.positions(PUT_U, address(this));
        assertEq(qty, 0, "position deleted");
        (,,,, uint256 netW) = book.sideState(PUT_U);
        assertEq(netW, 0, "put netWritten cleared");
        _assertConservation("winning close");
    }

    // ── losing close: floor at collateral, escrow released ───────────────────────

    function test_put_losing_close_floors_and_releases_escrow() public {
        _seedPoolFree(50e6);
        book.deposit(PUT, 50e6);
        book.postMark(PUT, PUT_MARK);
        book.openLong(PUT, 1e18);

        book.postMark(PUT, 16e18);    // −20% (deviation boundary); same block → no funding

        book.close(PUT);              // l = _toUsdc(1e18·(20-16)e18/1e18) = 4e6 ≤ collateral 50e6

        assertEq(book.putEscrow(), 0, "escrow released on loss");
        assertEq(book.traderCollateral(PUT_U, address(this)), 46e6, "collateral reduced by l");
        (uint256 qty,,) = book.positions(PUT_U, address(this));
        assertEq(qty, 0, "position deleted");
        _assertConservation("losing close");
    }

    // ── settle: funding-driven insolvency ────────────────────────────────────────

    /// @dev qty=0.1 put, collateral = IM = 5e6. After 3 funding periods, netLossUsdc = 6e6 > 5e6.
    ///      settle force-closes; loss floors at collateral → 0; escrow released; conservation holds.
    function test_put_settle_fires_on_insolvency() public {
        _seedPoolFree(5e6);
        book.deposit(PUT, 5e6);
        book.postMark(PUT, PUT_MARK); // lastIntrinsic = 0
        book.openLong(PUT, 0.1e18);   // IM = escrow = 5e6

        // 3 funding periods at unchanged mark: f = mark(20e18) − lastIntrinsic(0) = 20e18 each
        vm.warp(3601);  book.postMark(PUT, PUT_MARK); // cumFunding += 20e18
        vm.warp(7201);  book.postMark(PUT, PUT_MARK); // += 20e18 → 40e18
        vm.warp(10801); book.postMark(PUT, PUT_MARK); // += 20e18 → 60e18

        // netLossUsdc = _toUsdc(0.1e18·60e18/1e18) = 6e6 > collateral 5e6
        assertEq(book.netLossUsdc(PUT, address(this)), 6e6, "netLoss");
        assertGt(book.netLossUsdc(PUT, address(this)), book.traderCollateral(PUT_U, address(this)), "insolvent");

        book.settle(PUT, address(this));

        assertEq(book.traderCollateral(PUT_U, address(this)), 0, "collateral zeroed (floor)");
        assertEq(book.putEscrow(), 0, "escrow released");
        (uint256 qty,,) = book.positions(PUT_U, address(this));
        assertEq(qty, 0, "position force-closed");
        _assertConservation("settle");
    }

    /// @dev settle reverts "solvent" when netLoss ≤ collateral (fresh position, no funding).
    function test_put_settle_reverts_solvent() public {
        _seedPoolFree(50e6);
        book.deposit(PUT, 50e6);
        book.postMark(PUT, PUT_MARK);
        book.openLong(PUT, 1e18);

        vm.expectRevert(bytes("solvent"));
        book.settle(PUT, address(this));
    }

    // ── PUT + CALL coexistence on ONE shared pool ────────────────────────────────

    /// @dev The crux of the shared-pool model: a put and a call live on the same vault.poolUsdc().
    ///      Conservation holds at every step, and closing one side never touches the other's
    ///      escrow (put) or cover (call). Both sides win; both are paid from their OWN sources
    ///      (put ← released escrow; call ← cover sale) with no cross-contamination.
    function test_put_and_call_coexist_conservation() public {
        // Seed the pool, then convert part of the pool-free USDC into call cover.
        vault.pullUsdc(address(this), 200e6); // poolUsdc = 200e6, poolFree = 200e6
        vault.buyCover(1e18, 100e6);          // poolUsdc = 100e6, coverHype = 1e18, poolFree = 100e6

        book.postMark(CALL, 5e18);            // call OTM → intrinsic 0
        book.postMark(PUT, PUT_MARK);         // 20e18
        _assertConservation("seed");

        // Open the CALL: IM = 5e6; cover gate 1e18 ≥ 1e18 ✓. Call open touches no cash/escrow.
        book.deposit(CALL, 10e6);
        uint256 putEscrowPre = book.putEscrow();
        book.openLong(CALL, 1e18);
        assertEq(book.putEscrow(), putEscrowPre, "call open did NOT touch put escrow");
        _assertConservation("call open");

        // Open the PUT: escrow 50e6 locked. Put open touches no cover.
        book.deposit(PUT, 50e6);
        uint256 coverPre = vault.coverHype();
        book.openLong(PUT, 1e18);
        assertEq(vault.coverHype(), coverPre, "put open did NOT touch cover");
        assertEq(book.putEscrow(), 50e6, "put escrow locked");
        _assertConservation("put open");

        // Both sides go into the money.
        book.postMark(CALL, 6e18); // call gain 1e6 (same block → no funding)
        book.postMark(PUT, 24e18); // put gain 4e6

        // Close the CALL: paid from a COVER SALE; must NOT disturb put escrow.
        uint256 putEscrowBeforeCallClose = book.putEscrow();
        book.close(CALL);
        assertEq(book.putEscrow(), putEscrowBeforeCallClose, "call close did NOT touch put escrow");
        assertEq(book.traderCollateral(CALL_U, address(this)), 11e6, "call trader paid g=1e6");
        assertLt(vault.coverHype(), coverPre, "call close sold cover");
        _assertConservation("call close");

        // Close the PUT: paid from RELEASED ESCROW; must NOT disturb cover.
        uint256 coverBeforePutClose = vault.coverHype();
        book.close(PUT);
        assertEq(vault.coverHype(), coverBeforePutClose, "put close did NOT touch cover");
        assertEq(book.putEscrow(), 0, "put escrow fully released");
        assertEq(book.traderCollateral(PUT_U, address(this)), 54e6, "put trader paid g=4e6");
        _assertConservation("put close");

        // Final cross-contamination guard: each side's collateral moved ONLY via its own ops.
        assertEq(book.traderCollateral(CALL_U, address(this)), 11e6, "call collateral final");
        assertEq(book.traderCollateral(PUT_U,  address(this)), 54e6, "put collateral final");
    }
}
