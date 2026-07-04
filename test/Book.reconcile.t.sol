// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {EverlastingBook} from "../src/EverlastingBook.sol";
import {MockCoverVault} from "../src/mocks/MockCoverVault.sol";
import {MockOracle} from "../src/MockOracle.sol";

/// @title BookReconcileTest
/// @notice Task 7 async-reconciliation proof (D3 pre-funded-cover model): a COVERED_CALL can NEVER
///         be written ahead of settled cover. The open gate reads the ON-CHAIN vault balance
///         (`vault.coverHype()`), NOT an optimistic local counter — so a write only succeeds once
///         the cover HYPE has physically settled into the vault. This is what makes the covered
///         call solvent by construction: every written call unit is backed 1:1 by real cover.
contract BookReconcileTest is Test {
    MockCoverVault  vault;
    MockOracle      oracle;
    EverlastingBook book;

    address constant ALICE = address(0xA11CE);
    address constant BOB   = address(0xB0B);

    uint256 constant KPUT  = 100e18;
    uint256 constant WPUT  =  50e18;
    uint256 constant KCALL = 120e18;
    uint256 constant MARK  =   5e18;   // call OTM (spot 100 < Kcall 120) → intrinsic 0
    uint256 constant HYPE_PX = 100e18; // $100 / HYPE (WAD)

    EverlastingBook.Side private constant CALL = EverlastingBook.Side.COVERED_CALL;
    uint8 private constant CALL_U = 1;

    function setUp() public {
        vault  = new MockCoverVault();
        oracle = new MockOracle();
        book   = new EverlastingBook(
            vault, oracle, address(this),
            KPUT, WPUT, KCALL,
            10_000e18, 10_000e18
        );
        oracle.set(100e18);
        vault.setMockPx(HYPE_PX);

        // Seed pool USDC (for IM/deposits) but DELIBERATELY buy NO cover yet.
        vault.pullUsdc(address(0), 100_000e6);
        book.postMark(CALL, MARK);
    }

    /// @dev D3: with vault.coverHype()=0 < netWritten(0) + qty(1e18), the write reverts "cover".
    ///      The trader has ample IM — the ONLY thing missing is settled cover.
    function test_cannot_write_call_ahead_of_cover() public {
        vm.prank(ALICE);
        book.deposit(CALL, 10e6);          // IM = _toUsdc(1e18*5e18/1e18) = 5e6 ≤ 10e6 ✓
        assertEq(vault.coverHype(), 0, "no cover settled yet");

        vm.prank(ALICE);
        vm.expectRevert(bytes("cover"));
        book.openLong(CALL, 1e18);         // 0 < 0 + 1e18 → gate fails
    }

    /// @dev Partial cover is still insufficient: 0.5 HYPE settled, writing 1 HYPE reverts.
    function test_partial_cover_still_reverts() public {
        vault.buyCover(5e17, type(uint256).max); // 0.5 HYPE cover settled
        vm.prank(ALICE);
        book.deposit(CALL, 10e6);

        vm.prank(ALICE);
        vm.expectRevert(bytes("cover"));
        book.openLong(CALL, 1e18);         // 5e17 < 0 + 1e18 → gate fails
    }

    /// @dev Once the cover physically settles into the vault, the SAME write succeeds.
    function test_write_succeeds_after_cover_settles() public {
        vm.prank(ALICE);
        book.deposit(CALL, 10e6);

        // Cover settles (buyCover credits vault.coverHype()).
        vault.buyCover(1e18, type(uint256).max);  // coverHype = 1e18
        assertGe(vault.coverHype(), 1e18, "cover settled");

        vm.prank(ALICE);
        book.openLong(CALL, 1e18);          // 1e18 ≥ 0 + 1e18 → gate passes
        (,,,, uint256 netW) = book.sideState(CALL_U);
        assertEq(netW, 1e18, "call written against settled cover");
    }

    /// @dev The gate is INCREMENTAL and reads live vault state, not optimistic local netWritten:
    ///      after Alice writes 1 (netWritten=1, cover=1), Bob's write of 1 needs cover ≥ 2. With
    ///      cover still 1 it reverts; only after ANOTHER unit of cover settles does Bob's write pass.
    ///      This proves a second call can't be written ahead of its own incremental cover.
    function test_second_write_gated_by_incremental_cover() public {
        // Alice writes 1 against 1 settled cover.
        vault.buyCover(1e18, type(uint256).max);   // cover = 1e18
        vm.prank(ALICE);
        book.deposit(CALL, 10e6);
        vm.prank(ALICE);
        book.openLong(CALL, 1e18);                 // netWritten = 1e18
        (,,,, uint256 netW1) = book.sideState(CALL_U);
        assertEq(netW1, 1e18, "alice wrote 1");

        // Bob tries to write 1 more, but cover is still only 1 (< netWritten 1 + qty 1 = 2).
        vm.prank(BOB);
        book.deposit(CALL, 10e6);
        vm.prank(BOB);
        vm.expectRevert(bytes("cover"));
        book.openLong(CALL, 1e18);                 // 1e18 < 1e18 + 1e18 → gate fails

        // A second unit of cover settles → Bob's write now passes (cover 2 ≥ netWritten 1 + 1).
        vault.buyCover(1e18, type(uint256).max);   // cover = 2e18
        vm.prank(BOB);
        book.openLong(CALL, 1e18);
        (,,,, uint256 netW2) = book.sideState(CALL_U);
        assertEq(netW2, 2e18, "bob wrote the second unit only after cover settled");
        assertGe(vault.coverHype(), netW2, "coverGate holds: cover >= netWritten");
    }

    /// @dev Optimistic-state proof: selling cover back BELOW netWritten (e.g. an async cover
    ///      drawdown) blocks further writes even though local netWritten is unchanged. The gate
    ///      re-reads the vault every time, so the book cannot be tricked into over-writing.
    function test_gate_rereads_vault_after_cover_drawdown() public {
        vault.buyCover(2e18, type(uint256).max);   // cover = 2e18
        vm.prank(ALICE);
        book.deposit(CALL, 20e6);
        vm.prank(ALICE);
        book.openLong(CALL, 1e18);                 // netWritten = 1e18, cover = 2e18

        // Cover is drawn down to 1e18 (still ≥ netWritten, coverGate intact) via a direct sale.
        vault.sellCover(1e18);                     // cover = 1e18
        assertEq(vault.coverHype(), 1e18, "cover drawn down");

        // Bob's fresh write of 1 needs cover ≥ netWritten(1) + 1 = 2, but only 1 is settled → revert.
        vm.prank(BOB);
        book.deposit(CALL, 20e6);
        vm.prank(BOB);
        vm.expectRevert(bytes("cover"));
        book.openLong(CALL, 1e18);
    }
}
