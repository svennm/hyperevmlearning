// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {EverlastingBook} from "../src/EverlastingBook.sol";
import {MockCoverVault} from "../src/mocks/MockCoverVault.sol";
import {MockOracle} from "../src/MockOracle.sol";
import {MockVol} from "../src/mocks/MockVol.sol";

/// @title BookCallOpenTest
/// @notice Tests for EverlastingBook COVERED_CALL side, migrated to the autonomous mark (Task 5):
///   - openLong: revert paths (dead oracle, IM, cover gate, cap, one-position)
///   - openLong: success path (position stored at the computed mark, netWritten incremented)
///   - openLong auto-refreshes the mark, so there is no staleness gate to trip
///   - funding: accrues mark − intrinsic over a FUNDING_PERIOD
///   - computed CALL mark is uncapped (deep ITM) and floored at intrinsic
///   - the mark is the on-chain fair value (deterministic at a fixed spot → no drift)
contract BookCallOpenTest is Test {
    MockCoverVault vault;
    MockOracle     oracle;
    MockVol        mockVol;
    EverlastingBook book;

    // Strikes / cap defaults
    uint256 constant KPUT  = 100e18;
    uint256 constant WPUT  =  50e18;
    uint256 constant KCALL = 120e18;

    // Aliases for readability
    EverlastingBook.Side private constant CALL = EverlastingBook.Side.COVERED_CALL;
    EverlastingBook.Side private constant PUT  = EverlastingBook.Side.PUT;
    uint8 private constant CALL_U = 1;
    uint8 private constant PUT_U  = 0;

    function setUp() public {
        vault  = new MockCoverVault();
        oracle = new MockOracle();
        mockVol = new MockVol();
        book   = new EverlastingBook(
            vault, oracle, address(this), // keeper = test contract
            KPUT, WPUT, KCALL,
            10_000e18,  // putCapNotional
            10_000e18,  // callCapNotional
            mockVol
        );

        oracle.set(100e18);       // spot $100 — call OTM (Kcall=120), intrinsic=0
        vault.setMockPx(100e18);  // vault mock price

        // Seed vault USDC and buy 50 HYPE cover (50 × $100 = $5000)
        vault.pullUsdc(address(0), 20_000e6);
        vault.buyCover(50e18, 5_000e6);

        // Establish the autonomous mark (permissionless; intrinsic=0 → mark = fair value).
        book.accrue(CALL);
    }

    function _mark(EverlastingBook.Side side) internal view returns (uint256 m) {
        (m,,,,) = book.sideState(uint8(side));
    }

    // ── openLong: revert paths ────────────────────────────────────────────────

    /// @dev Dead oracle (spot==0): the auto-accrue in openLong can't price → "spot=0".
    ///      (Autonomous-mark replacement for the old "no mark" keeper guard: with a live oracle the
    ///      mark is always computed on open, so the only way to block an open is an unpriceable spot.)
    function test_open_revert_dead_oracle() public {
        book.deposit(CALL, 10e6);
        oracle.set(0);
        vm.expectRevert(bytes("spot=0"));
        book.openLong(CALL, 1e18);
    }

    /// @dev No staleness gate any more: openLong auto-accrues, so even after a long delay the open
    ///      succeeds against a freshly-refreshed mark. (Replaces the old "stale mark" revert.)
    function test_open_after_delay_autoRefreshes() public {
        book.deposit(CALL, 20e6);
        vm.warp(block.timestamp + 1_000_000); // far in the future

        book.openLong(CALL, 1e18); // must not revert — mark auto-refreshed
        (uint256 qty,,) = book.positions(CALL_U, address(this));
        assertEq(qty, 1e18, "position opened after a long delay");
    }

    /// @dev Insufficient collateral for premium IM → "IM". alice has no deposit; IM = qty·mark > 0.
    function test_open_revert_IM() public {
        address alice = address(0xA11CE);
        vm.prank(alice);
        vm.expectRevert(bytes("IM"));
        book.openLong(CALL, 1e18);
    }

    /// @dev vault.coverHype() < netWritten + qty → "cover".
    ///      Use a vault seeded with only 0.5 HYPE cover; try to open 1 HYPE.
    function test_open_revert_cover() public {
        MockCoverVault smallVault = new MockCoverVault();
        smallVault.setMockPx(100e18);
        smallVault.pullUsdc(address(0), 1_000e6);
        smallVault.buyCover(5e17, 50e6);  // coverHype = 5e17 (0.5 HYPE)

        EverlastingBook coverBook = new EverlastingBook(
            smallVault, oracle, address(this), KPUT, WPUT, KCALL, 10_000e18, 10_000e18, mockVol
        );
        // Deposit ample IM; the cover gate (not IM) is what must bite.
        coverBook.deposit(CALL, 10e6);

        // 1e18 > 5e17 → cover gate fails
        vm.expectRevert(bytes("cover"));
        coverBook.openLong(CALL, 1e18);
    }

    /// @dev netWritten + qty > callCapNotional → "cap".
    ///      Use a book with callCapNotional=2e18; try to open 3 HYPE (cover on the shared vault is ample).
    function test_open_revert_cap() public {
        EverlastingBook capBook = new EverlastingBook(
            vault, oracle, address(this), KPUT, WPUT, KCALL, 10_000e18, 2e18, mockVol
        );
        capBook.deposit(CALL, 20e6);

        // 3e18 > callCapNotional=2e18 → cap fails
        vm.expectRevert(bytes("cap"));
        capBook.openLong(CALL, 3e18);
    }

    /// @dev Second openLong from same trader before close → "one position".
    function test_open_revert_one_position() public {
        book.deposit(CALL, 20e6);
        book.openLong(CALL, 1e18);

        vm.expectRevert(bytes("one position"));
        book.openLong(CALL, 1e18);
    }

    /// @dev PUT is enabled (T6). With a dead oracle, openLong(PUT)'s auto-accrue can't price → "spot=0".
    ///      (Autonomous-mark replacement for the old "no mark" put guard.)
    function test_open_put_revert_dead_oracle() public {
        oracle.set(0);
        vm.expectRevert(bytes("spot=0"));
        book.openLong(PUT, 1e18);
    }

    /// @dev PUT mark is set autonomously on accrue. spot=100=Kput → put intrinsic 0; mark ∈ (0, Wput].
    function test_put_mark_set_on_accrue() public {
        book.accrue(PUT);
        uint256 m = _mark(PUT);
        assertGt(m, 0,    "put mark set");
        assertLe(m, WPUT, "put mark <= Wput");
    }

    // ── openLong: success path ────────────────────────────────────────────────

    /// @dev Successful open: position stored at the computed mark, netWritten incremented.
    function test_call_open_success() public {
        uint256 qty = 2e18;
        book.deposit(CALL, 20e6);
        uint256 markNow = _mark(CALL);

        book.openLong(CALL, qty);

        (uint256 posQty, uint256 posEntryMark, uint256 posEntryCF) =
            book.positions(CALL_U, address(this));
        (,,,, uint256 netWritten) = book.sideState(CALL_U);

        assertEq(posQty,       qty,     "qty");
        assertEq(posEntryMark, markNow, "entryMark == computed fair value");
        assertEq(posEntryCF,   0,       "entryCumFunding=0 (no prior period)");
        assertEq(netWritten,   qty,     "netWritten");
    }

    // ── funding: accrues mark − intrinsic over a FUNDING_PERIOD ──────────────

    /// @dev F3 pattern: after one period, cumFunding = (mark − lastIntrinsic) × periods.
    ///      oracle=100, Kcall=120, intrinsic=0 → f = mark − 0 = mark; periods = 1.
    function test_funding_accrues_mark_minus_intrinsic() public {
        book.deposit(CALL, 10e6);
        book.openLong(CALL, 1e18);
        uint256 markAtEntry = _mark(CALL);

        // Advance exactly one FUNDING_PERIOD; spot unchanged ⇒ mark constant.
        vm.warp(block.timestamp + book.FUNDING_PERIOD());
        book.accrue(CALL);

        // cumFunding += (mark − 0) × 1 = mark
        (, , uint256 cf, , ) = book.sideState(CALL_U);
        assertEq(cf, markAtEntry, "cumFunding after 1 period == mark");

        // pendingFunding = qty × (cumFunding − entryCumFunding) / 1e18 = mark
        assertEq(book.pendingFunding(CALL, address(this)), markAtEntry, "pendingFunding == mark");
    }

    /// @dev pendingFunding returns 0 for an address with no position.
    function test_pending_funding_no_position() public view {
        assertEq(book.pendingFunding(CALL, address(0xDEAD)), 0);
    }

    // ── computed CALL mark: uncapped + floored at intrinsic ────────────────────

    /// @dev Deep ITM: spot=200, intrinsic=80e18. The computed call mark is ≥ its intrinsic and, unlike
    ///      the PUT (capped at Wput=50), carries NO ≤W ceiling — so it sits far above Wput. That is the
    ///      "uncapped" property the old postMark(mark=200e18) exercised, now proven on the fair value.
    function test_call_mark_uncapped_deep_itm() public {
        oracle.set(200e18);  // intrinsic = 200e18 − 120e18 = 80e18
        book.accrue(CALL);
        uint256 m = _mark(CALL);
        assertGe(m, book.intrinsic(CALL), "mark >= intrinsic");
        assertGt(m, WPUT, "call mark uncapped (far exceeds the put-side Wput ceiling)");
    }

    /// @dev The computed mark is floored at intrinsic (funding→0 at the floor). At S=200 the fair
    ///      value alone is well above the $80 intrinsic, but the floor invariant still holds.
    ///      (Replaces the old "mark<intrinsic" postMark revert with the structural floor guarantee.)
    function test_call_mark_floored_at_intrinsic() public {
        oracle.set(200e18);
        book.accrue(CALL);
        assertGe(_mark(CALL), book.intrinsic(CALL), "computed mark >= intrinsic");
    }

    /// @dev The mark IS the on-chain fair value: accruing twice at a fixed spot cannot move it
    ///      (deterministic in S, σ, adaptiveMult). (Replaces the old keeper "mark deviation" band —
    ///      there is no discretionary mark to deviate.)
    function test_mark_no_drift_at_fixed_spot() public {
        book.accrue(CALL);
        uint256 m1 = _mark(CALL);
        book.accrue(CALL);
        uint256 m2 = _mark(CALL);
        assertEq(m1, m2, "mark unchanged at a fixed spot");
        assertEq(m2, book.fairMark(CALL), "mark == on-chain fair value");
    }
}
