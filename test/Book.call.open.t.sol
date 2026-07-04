// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {EverlastingBook} from "../src/EverlastingBook.sol";
import {MockCoverVault} from "../src/mocks/MockCoverVault.sol";
import {MockOracle} from "../src/MockOracle.sol";

/// @title BookCallOpenTest
/// @notice Tests for EverlastingBook COVERED_CALL side:
///   - openLong: revert paths (no mark, stale mark, IM, cover gate, cap, one-position)
///   - openLong: success path (position stored, netWritten incremented)
///   - funding: accrues mark − intrinsic over a FUNDING_PERIOD
///   - postMark: accepts marks > Kcall (no ≤W upper cap on call side)
///   - PUT placeholder reverts
contract BookCallOpenTest is Test {
    MockCoverVault vault;
    MockOracle     oracle;
    EverlastingBook book;

    // Strikes / cap defaults
    uint256 constant KPUT  = 100e18;
    uint256 constant WPUT  =  50e18;
    uint256 constant KCALL = 120e18;

    // Initial mark posted in setUp (call OTM → intrinsic=0, so any >0 mark is valid)
    uint256 constant INIT_MARK = 5e18;

    uint256 constant FUNDING_PERIOD = 3600;
    uint256 constant MAX_MARK_AGE   = 7200;

    // Aliases for readability
    EverlastingBook.Side private constant CALL = EverlastingBook.Side.COVERED_CALL;
    EverlastingBook.Side private constant PUT  = EverlastingBook.Side.PUT;

    function setUp() public {
        vault  = new MockCoverVault();
        oracle = new MockOracle();
        book   = new EverlastingBook(
            vault, oracle, address(this), // keeper = test contract
            KPUT, WPUT, KCALL,
            10_000e18,  // putCapNotional
            10_000e18   // callCapNotional
        );

        oracle.set(100e18);       // spot $100 — call OTM (Kcall=120), intrinsic=0
        vault.setMockPx(100e18);  // vault mock price

        // Seed vault USDC and buy 50 HYPE cover (50 × $100 = $5000)
        vault.pullUsdc(address(0), 20_000e6);
        vault.buyCover(50e18, 5_000e6);

        // Post initial mark: intrinsic=0, mark=5e18 valid (≥ 0), isFresh=false (first mark)
        book.postMark(CALL, INIT_MARK);
    }

    // ── openLong: revert paths ────────────────────────────────────────────────

    /// @dev No mark set → "no mark"
    function test_open_revert_no_mark() public {
        EverlastingBook fresh = new EverlastingBook(
            vault, oracle, address(this), KPUT, WPUT, KCALL, 10_000e18, 10_000e18
        );
        fresh.deposit(CALL, 10e6);

        vm.expectRevert(bytes("no mark"));
        fresh.openLong(CALL, 1e18);
    }

    /// @dev Mark posted but older than MAX_MARK_AGE → "stale mark"
    function test_open_revert_stale_mark() public {
        vm.warp(block.timestamp + MAX_MARK_AGE + 1);

        vm.expectRevert(bytes("stale mark"));
        book.openLong(CALL, 1e18);
    }

    /// @dev Insufficient collateral for premium IM → "IM"
    ///      alice has no deposit; IM = _toUsdc(1e18 × 5e18 / 1e18) = 5e6 > 0
    function test_open_revert_IM() public {
        address alice = address(0xA11CE);
        vm.prank(alice);
        vm.expectRevert(bytes("IM"));
        book.openLong(CALL, 1e18);
    }

    /// @dev vault.coverHype() < netWritten + qty → "cover"
    ///      Use a vault seeded with only 0.5 HYPE cover; try to open 1 HYPE.
    function test_open_revert_cover() public {
        MockCoverVault smallVault = new MockCoverVault();
        smallVault.setMockPx(100e18);
        smallVault.pullUsdc(address(0), 1_000e6);
        // 0.5 HYPE × $100 = $50; _toUsdc(5e17 × 100e18 / 1e18) = _toUsdc(5e19) = 50e6
        smallVault.buyCover(5e17, 50e6);  // coverHype = 5e17 (0.5 HYPE)

        EverlastingBook coverBook = new EverlastingBook(
            smallVault, oracle, address(this), KPUT, WPUT, KCALL, 10_000e18, 10_000e18
        );
        coverBook.postMark(CALL, INIT_MARK);
        // Deposit enough IM for 1 HYPE: _toUsdc(1e18 × 5e18 / 1e18) = 5e6
        coverBook.deposit(CALL, 10e6);

        // 1e18 > 5e17 → cover gate fails
        vm.expectRevert(bytes("cover"));
        coverBook.openLong(CALL, 1e18);
    }

    /// @dev netWritten + qty > callCapNotional → "cap"
    ///      Use a book with callCapNotional=2e18; try to open 3 HYPE.
    function test_open_revert_cap() public {
        EverlastingBook capBook = new EverlastingBook(
            vault, oracle, address(this), KPUT, WPUT, KCALL, 10_000e18, 2e18
        );
        capBook.postMark(CALL, INIT_MARK);
        // IM for 3e18 at mark=5e18: _toUsdc(3e18 × 5e18 / 1e18) = _toUsdc(15e18) = 15e6
        capBook.deposit(CALL, 20e6);

        // 3e18 > callCapNotional=2e18 → cap fails
        vm.expectRevert(bytes("cap"));
        capBook.openLong(CALL, 3e18);
    }

    /// @dev Second openLong from same trader before close → "one position"
    function test_open_revert_one_position() public {
        book.deposit(CALL, 20e6);
        book.openLong(CALL, 1e18);

        vm.expectRevert(bytes("one position"));
        book.openLong(CALL, 1e18);
    }

    /// @dev PUT side not implemented yet → "put: enabled in T6"
    function test_open_put_reverts_placeholder() public {
        vm.expectRevert(bytes("put: enabled in T6"));
        book.openLong(PUT, 1e18);
    }

    function test_postMark_put_reverts_placeholder() public {
        vm.expectRevert(bytes("put: enabled in T6"));
        book.postMark(PUT, 5e18);
    }

    // ── openLong: success path ────────────────────────────────────────────────

    /// @dev Successful open: position stored correctly, netWritten incremented
    function test_call_open_success() public {
        uint256 qty = 2e18;
        // IM = _toUsdc(2e18 × 5e18 / 1e18) = _toUsdc(10e18) = 10e6
        book.deposit(CALL, 20e6);

        book.openLong(CALL, qty);

        (uint256 posQty, uint256 posEntryMark, uint256 posEntryCF) =
            book.positions(uint8(CALL), address(this));
        (,,,, uint256 netWritten) = book.sideState(uint8(CALL));

        assertEq(posQty,       qty,       "qty");
        assertEq(posEntryMark, INIT_MARK, "entryMark");
        assertEq(posEntryCF,   0,         "entryCumFunding=0 (no prior period)");
        assertEq(netWritten,   qty,       "netWritten");
    }

    // ── funding: accrues mark − intrinsic over a FUNDING_PERIOD ──────────────

    /// @dev F3 pattern: after one period, cumFunding = (mark − lastIntrinsic) × periods
    ///      oracle=100, Kcall=120, intrinsic=0, mark=5e18
    ///      → f = 5e18 − 0 = 5e18; periods = 1
    ///      → cumFunding = 5e18; pendingFunding(1 unit) = 5e18 WAD
    function test_funding_accrues_mark_minus_intrinsic() public {
        // IM = _toUsdc(1e18 × 5e18 / 1e18) = 5e6
        book.deposit(CALL, 10e6);
        book.openLong(CALL, 1e18);

        // Advance exactly one FUNDING_PERIOD
        vm.warp(block.timestamp + FUNDING_PERIOD);

        // Re-post same mark: within deviation (5e18 ± 20% = [4e18, 6e18])
        book.postMark(CALL, 5e18);

        // cumFunding += (5e18 − 0) × 1 = 5e18
        (, , uint256 cf, , ) = book.sideState(uint8(CALL));
        assertEq(cf, 5e18, "cumFunding after 1 period");

        // pendingFunding = qty × (cumFunding − entryCumFunding) / 1e18
        //                = 1e18 × (5e18 − 0) / 1e18 = 5e18
        assertEq(book.pendingFunding(CALL, address(this)), 5e18, "pendingFunding");
    }

    /// @dev pendingFunding returns 0 for an address with no position
    function test_pending_funding_no_position() public view {
        assertEq(book.pendingFunding(CALL, address(0xDEAD)), 0);
    }

    // ── postMark: uncapped — no ≤W cap on call side ───────────────────────────

    /// @dev Deep ITM: spot=200, intrinsic=80e18. Mark=200e18 >> Kcall is accepted (no clamp).
    ///      Deviation guard skipped because the prior mark is stale (warp past MAX_MARK_AGE).
    function test_postMark_uncapped_deep_itm() public {
        // Stale the existing mark so deviation guard is bypassed (isFresh=false)
        vm.warp(block.timestamp + MAX_MARK_AGE + 1);
        oracle.set(200e18);  // intrinsic = 200e18 − 120e18 = 80e18

        // Mark = 200e18 far exceeds Kcall=120e18; accepted because call side has no upper cap
        book.postMark(CALL, 200e18);

        (uint256 m, , , , ) = book.sideState(uint8(CALL));
        assertEq(m, 200e18, "mark stored uncapped");
    }

    /// @dev mark<intrinsic reverts: spot=200, intrinsic=80e18; try to post mark=50e18
    function test_postMark_revert_below_intrinsic() public {
        vm.warp(block.timestamp + MAX_MARK_AGE + 1);
        oracle.set(200e18);  // intrinsic=80e18

        vm.expectRevert(bytes("mark<intrinsic"));
        book.postMark(CALL, 50e18);   // 50e18 < 80e18 intrinsic
    }

    /// @dev Deviation guard: fresh mark, new mark > 20% above prior → "mark deviation"
    function test_postMark_revert_deviation() public {
        // setUp mark=5e18 at block.timestamp. Still fresh (< MAX_MARK_AGE).
        // hi = 5e18 + 5e18×2000/10000 = 6e18; try 7e18 → rejected
        vm.expectRevert(bytes("mark deviation"));
        book.postMark(CALL, 7e18);
    }
}
