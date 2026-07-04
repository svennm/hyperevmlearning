// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {EverlastingBook} from "../src/EverlastingBook.sol";
import {MockCoverVault} from "../src/mocks/MockCoverVault.sol";
import {MockOracle} from "../src/MockOracle.sol";

/// @title BookWithdrawTest
/// @notice Task 7 — withdraw + LP pool-free liquidity, unit-level.
///   withdraw(side, amt):   only when the trader's position on that side is CLOSED; debits
///                          traderCollateral + totalCollateral and pays out via the vault.
///                          Conservation-neutral (poolUsdc and totalCollateral both drop by amt).
///   lpDeposit(amt):        raises poolFree() (physical up, NO trader claim).
///   lpWithdraw(amt):       only pool-free USDC may leave (require poolFree() >= amt).
contract BookWithdrawTest is Test {
    MockCoverVault  vault;
    MockOracle      oracle;
    EverlastingBook book;

    address constant ALICE = address(0xA11CE);
    address constant LP    = address(0x11D);

    uint256 constant KPUT    = 100e18;
    uint256 constant WPUT    =  50e18;
    uint256 constant KCALL   = 120e18;
    uint256 constant HYPE_PX = 100e18;
    uint256 constant PUT_MARK = 20e18;

    EverlastingBook.Side private constant PUT  = EverlastingBook.Side.PUT;
    EverlastingBook.Side private constant CALL = EverlastingBook.Side.COVERED_CALL;
    uint8 private constant PUT_U  = 0;
    uint8 private constant CALL_U = 1;

    event Withdrawn(EverlastingBook.Side indexed side, address indexed trader, uint256 amt);
    event LpDeposited(address indexed lp, uint256 amt);
    event LpWithdrawn(address indexed lp, uint256 amt);

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
        vm.warp(1);
    }

    function _conservation() internal view returns (bool) {
        return vault.poolUsdc() == book.poolFree() + book.putEscrow() + book.totalCollateral();
    }

    // ── withdraw: happy path (position closed) ────────────────────────────────

    /// @dev A trader with NO open position withdraws free collateral: collateral + totalCollateral
    ///      + poolUsdc all drop by amt; poolFree() and conservation are unchanged.
    function test_withdraw_free_collateral() public {
        vm.prank(ALICE);
        book.deposit(CALL, 100e6);                 // poolUsdc 100e6, collateral 100e6, poolFree 0
        assertTrue(_conservation(), "conservation after deposit");

        uint256 poolBefore = vault.poolUsdc();
        uint256 freeBefore = book.poolFree();

        vm.expectEmit(true, true, false, true, address(book));
        emit Withdrawn(CALL, ALICE, 40e6);
        vm.prank(ALICE);
        book.withdraw(CALL, 40e6);

        assertEq(book.traderCollateral(CALL_U, ALICE), 60e6, "collateral reduced");
        assertEq(book.totalCollateral(), 60e6, "totalCollateral reduced");
        assertEq(vault.poolUsdc(), poolBefore - 40e6, "poolUsdc paid out");
        assertEq(book.poolFree(), freeBefore, "poolFree unchanged (conservation-neutral)");
        assertTrue(_conservation(), "conservation after withdraw");
    }

    /// @dev Withdrawing the full balance zeroes the trader out.
    function test_withdraw_full_balance() public {
        vm.prank(ALICE);
        book.deposit(PUT, 30e6);
        vm.prank(ALICE);
        book.withdraw(PUT, 30e6);
        assertEq(book.traderCollateral(PUT_U, ALICE), 0, "zeroed");
        assertEq(book.totalCollateral(), 0, "totalCollateral zeroed");
        assertTrue(_conservation(), "conservation");
    }

    // ── withdraw: revert paths ────────────────────────────────────────────────

    /// @dev Cannot withdraw while a position is open on that side → "open position".
    function test_withdraw_reverts_open_position() public {
        // Seed pool-free so the put open can escrow, then open a put for ALICE.
        vault.pullUsdc(address(this), 100e6);      // poolFree = 100e6
        book.postMark(PUT, PUT_MARK);
        vm.prank(ALICE);
        book.deposit(PUT, 60e6);                   // IM = 50e6
        vm.prank(ALICE);
        book.openLong(PUT, 1e18);                  // position open

        vm.prank(ALICE);
        vm.expectRevert(bytes("open position"));
        book.withdraw(PUT, 10e6);
    }

    /// @dev A closed position on the OTHER side does not block withdraw on this side, but the
    ///      per-side guard is independent: an open CALL blocks CALL withdraw only.
    function test_withdraw_side_independent() public {
        vault.pullUsdc(address(this), 100e6);
        // Open a CALL for ALICE (needs cover).
        vault.buyCover(1e18, type(uint256).max);
        book.postMark(CALL, 5e18);
        vm.prank(ALICE);
        book.deposit(CALL, 10e6);
        vm.prank(ALICE);
        book.openLong(CALL, 1e18);
        // ALICE also has free PUT collateral.
        vm.prank(ALICE);
        book.deposit(PUT, 20e6);

        // CALL withdraw blocked (open), PUT withdraw allowed (no put position).
        vm.prank(ALICE);
        vm.expectRevert(bytes("open position"));
        book.withdraw(CALL, 1e6);

        vm.prank(ALICE);
        book.withdraw(PUT, 20e6);
        assertEq(book.traderCollateral(PUT_U, ALICE), 0, "put side withdrawn");
        assertTrue(_conservation(), "conservation");
    }

    /// @dev Withdrawing more than the balance underflow-reverts (fail-closed).
    function test_withdraw_reverts_over_balance() public {
        vm.prank(ALICE);
        book.deposit(CALL, 10e6);
        vm.prank(ALICE);
        vm.expectRevert(); // arithmetic underflow on the collateral debit
        book.withdraw(CALL, 11e6);
    }

    // ── lpDeposit / lpWithdraw ────────────────────────────────────────────────

    /// @dev lpDeposit adds the LP's own capital as pool-free USDC (poolFree rises; no collateral).
    ///      T8: lpDeposit is owner-only; the test contract is the owner (deployer).
    function test_lpDeposit_raises_poolFree() public {
        uint256 freeBefore = book.poolFree();

        vm.expectEmit(true, false, false, true, address(book));
        emit LpDeposited(address(this), 250e6);
        book.lpDeposit(250e6);

        assertEq(book.poolFree(), freeBefore + 250e6, "poolFree += amt");
        assertEq(book.totalCollateral(), 0, "no trader collateral created");
        assertEq(vault.poolUsdc(), 250e6, "physical pool up");
        assertTrue(_conservation(), "conservation");
    }

    /// @dev lpWithdraw removes pool-free USDC only.
    ///      T8: both lp funcs are owner-only; the test contract is the owner.
    function test_lpWithdraw_reduces_poolFree() public {
        book.lpDeposit(250e6);

        vm.expectEmit(true, false, false, true, address(book));
        emit LpWithdrawn(address(this), 100e6);
        book.lpWithdraw(100e6);

        assertEq(book.poolFree(), 150e6, "poolFree -= amt");
        assertEq(vault.poolUsdc(), 150e6, "physical pool down");
        assertTrue(_conservation(), "conservation");
    }

    /// @dev lpWithdraw cannot touch trader collateral or escrow → "pool-free" when amt > poolFree.
    ///      T8: owner calls lpWithdraw (owner-only); revert is pool-free guard, not onlyOwner.
    function test_lpWithdraw_reverts_over_poolFree() public {
        // All physical USDC is trader collateral (poolFree = 0).
        vm.prank(ALICE);
        book.deposit(CALL, 100e6);
        assertEq(book.poolFree(), 0, "no pool-free");

        vm.expectRevert(bytes("pool-free"));
        book.lpWithdraw(1);
    }

    /// @dev lpWithdraw cannot dip into locked PUT escrow either.
    function test_lpWithdraw_cannot_take_escrow() public {
        // Seed pool-free, open a put that locks escrow, then poolFree drops by the escrow.
        book.lpDeposit(50e6);                      // poolFree = 50e6 (LP capital)
        book.postMark(PUT, PUT_MARK);
        vm.prank(ALICE);
        book.deposit(PUT, 50e6);                   // IM 50e6
        vm.prank(ALICE);
        book.openLong(PUT, 1e18);                  // escrow 50e6 locked → poolFree back to 0

        assertEq(book.putEscrow(), 50e6, "escrow locked");
        assertEq(book.poolFree(), 0, "poolFree consumed by escrow");

        vm.expectRevert(bytes("pool-free"));
        book.lpWithdraw(1);                        // cannot pull escrowed USDC
        assertTrue(_conservation(), "conservation");
    }
}
