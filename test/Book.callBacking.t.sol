// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {EverlastingBook} from "../src/EverlastingBook.sol";
import {MockCoverVault} from "../src/mocks/MockCoverVault.sol";
import {MockOracle} from "../src/MockOracle.sol";
import {ICoverVault} from "../src/interfaces/ICoverVault.sol";
import {ISpotOracle} from "../src/interfaces/ISpotOracle.sol";

/// @notice M1 regression: the owner must not be able to strand open covered-call winners by
///         emergency-unwinding the cover (cover→poolFree) and then withdrawing those proceeds via
///         lpWithdraw. The call-backing guard blocks lpWithdraw while calls are open but under-backed.
contract BookCallBackingTest is Test {
    EverlastingBook book;
    MockCoverVault  vault;
    MockOracle      oracle;
    address keeper = address(0xBEEF);
    address trader = address(0x7111);

    function setUp() public {
        vault  = new MockCoverVault();
        oracle = new MockOracle();
        // this = owner; caps 10e18; Kput/Wput/Kcall.
        book = new EverlastingBook(
            ICoverVault(address(vault)), ISpotOracle(address(oracle)),
            keeper, 100e18, 20e18, 120e18, 10e18, 10e18
        );
    }

    function _callNetWritten() internal view returns (uint256 nw) {
        (,,,, nw) = book.sideState(uint8(EverlastingBook.Side.COVERED_CALL));
    }

    function test_lpWithdraw_cannotStrandCallWinner() public {
        // Seed 6 HYPE cover @ $50 and open a covered call of 6 (cover-gate holds 1:1).
        vault.setMockPx(50e18);
        vault.pullUsdc(address(this), 1_000_000e6); // pool USDC to fund the cover buy
        vault.buyCover(6e18, type(uint256).max);    // coverHype = 6e18
        oracle.set(130e18);                         // call intrinsic = 10
        vm.prank(keeper);
        book.postMark(EverlastingBook.Side.COVERED_CALL, 15e18);
        vm.prank(trader);
        book.deposit(EverlastingBook.Side.COVERED_CALL, 90e6); // IM = 6·15 = 90
        vm.prank(trader);
        book.openLong(EverlastingBook.Side.COVERED_CALL, 6e18);

        // Normal state: cover backs the calls (coverHype ≥ callNetWritten) ⇒ lpWithdraw allowed.
        book.lpWithdraw(1e6);

        // Owner emergency-unwinds cover: proceeds → poolFree, coverHype → 0, call still open.
        book.pause();
        book.emergencyUnwindCover();
        assertEq(vault.coverHype(), 0, "cover unwound");
        assertEq(_callNetWritten(), 6e18, "call still open");

        // STRAND BLOCKED: those proceeds are now the winner's backing and cannot be withdrawn.
        vm.expectRevert("call backing");
        book.lpWithdraw(1e6);

        // Once the call resolves (close is always open, even while paused), LP capital frees up.
        vm.prank(trader);
        book.close(EverlastingBook.Side.COVERED_CALL);
        assertEq(_callNetWritten(), 0, "call closed");
        book.lpWithdraw(1e6); // now allowed
    }
}
