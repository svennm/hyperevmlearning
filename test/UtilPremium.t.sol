// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {EverlastingBook} from "../src/EverlastingBook.sol";
import {MockCoverVault} from "../src/mocks/MockCoverVault.sol";
import {MockOracle} from "../src/MockOracle.sol";
import {MockVol} from "../src/mocks/MockVol.sol";
import {ICoverVault} from "../src/interfaces/ICoverVault.sol";
import {ISpotOracle} from "../src/interfaces/ISpotOracle.sol";

/// @title UtilPremium.t.sol — adversarial tests for the P(U) utilization-surcharge funding curve.
/// @notice Reworked for Task 6: UTIL_KAPPA (0.05e18), U_MAX (0.8e18) are now public constants —
///         the setters and their guard bounds were removed. Surcharge is ALWAYS ON; the tests prove
///         correct values at the fixed κ=0.05e18. Tests that required toggling κ or uMax to
///         zero/non-default have been deleted; the u-cap boundary tests use the fixed U_MAX=0.8.
contract UtilPremiumTest is Test {
    EverlastingBook book;
    MockCoverVault  vault;
    MockOracle      oracle;
    MockVol         mockVol;

    address keeper  = address(0xBEEF);
    address trader  = address(0x7111);
    address trader2 = address(0x7222);

    uint256 constant WAD             = 1e18;
    uint256 constant Kput            = 100e18;
    uint256 constant Wput            = 20e18;
    uint256 constant Kcall           = 120e18;
    uint256 constant putCap          = 10e18;
    uint256 constant callCap         = 10e18;

    EverlastingBook.Side private constant PUT  = EverlastingBook.Side.PUT;
    EverlastingBook.Side private constant CALL = EverlastingBook.Side.COVERED_CALL;

    // This test contract is the owner (deploy unpranked).
    function setUp() public {
        vault  = new MockCoverVault();
        oracle = new MockOracle();
        mockVol = new MockVol();
        book   = new EverlastingBook(
            ICoverVault(address(vault)), ISpotOracle(address(oracle)),
            keeper, Kput, Wput, Kcall, putCap, callCap, mockVol
        );
    }

    // ── helpers ────────────────────────────────────────────────────────────────

    function _cf(EverlastingBook.Side side) internal view returns (uint256 cf) {
        (,, cf,,) = book.sideState(uint8(side));
    }

    /// @dev Stored mark for a side (the period-start mark that funding folds from).
    function _mark(EverlastingBook.Side side) internal view returns (uint256 m) {
        (m,,,,) = book.sideState(uint8(side));
    }

    function _fundPool(uint256 usdc) internal {
        book.lpDeposit(usdc); // owner op; raises poolFree
    }

    function _seedCover(uint256 hypeWad, uint256 pxWad) internal {
        vault.setMockPx(pxWad);
        vault.pullUsdc(address(this), 1_000_000_000e6); // fund pool so buyCover can pay
        vault.buyCover(hypeWad, type(uint256).max);
    }

    /// @dev Permissionless mark refresh (autonomous). Replaces the old keeper postMark.
    function _accrue(EverlastingBook.Side side) internal {
        book.accrue(side);
    }

    function _deposit(EverlastingBook.Side side, address t, uint256 usdc) internal {
        vm.prank(t);
        book.deposit(side, usdc);
    }

    // 1. PUT surcharge linear in U (U=0.5 ⇒ P=0.5 ⇒ surcharge = κ·0.5 = 0.025e18 at κ=0.05).
    //    (Formerly test_putSurchargeLinear; κ fixed to 0.05e18 — setter removed in Task 6.)
    function test_putSurchargeLinear() public {
        _fundPool(1_000_000e6);
        oracle.set(90e18);                  // put intrinsic = clamp(10,0,20) = 10
        _accrue(PUT);
        uint256 base = _mark(PUT) - book.intrinsic(PUT); // extrinsic = mark − 10e18
        _deposit(PUT, trader, 100e6);        // IM = 5·20 = 100 usdc
        vm.prank(trader);
        book.openLong(PUT, 5e18);            // U = 5/10 = 0.5
        assertEq(book.utilization(PUT), 0.5e18);
        skip(3600);
        _accrue(PUT);
        // surcharge = UTIL_KAPPA · P_put(0.5) / WAD = 0.05e18 · 0.5e18 / 1e18 = 0.025e18
        uint256 expectedSurcharge = book.UTIL_KAPPA() * 5e17 / WAD; // = 0.025e18
        assertEq(_cf(PUT), base + expectedSurcharge);
    }

    // 2. CALL surcharge convex (U=0.6 ⇒ P=18.75 ⇒ surcharge = κ·18.75 = 0.9375e18 at κ=0.05).
    //    (Formerly test_callSurchargeConvex; κ fixed to 0.05e18 — setter removed in Task 6.)
    function test_callSurchargeConvex() public {
        _seedCover(6e18, 50e18);
        oracle.set(130e18);                 // call intrinsic = 10
        _accrue(CALL);
        uint256 base = _mark(CALL) - book.intrinsic(CALL);
        _deposit(CALL, trader, 500e6);       // ample IM (= qty·mark)
        vm.prank(trader);
        book.openLong(CALL, 6e18);           // U = 0.6
        assertEq(book.utilization(CALL), 0.6e18);
        skip(3600);
        _accrue(CALL);
        // P_call(0.6) = 2·0.6 / (0.4)^3 = 1.2 / 0.064 = 18.75 (in WAD: 18.75e18)
        // surcharge = 0.05e18 · 18.75e18 / 1e18 = 0.9375e18
        assertEq(_cf(CALL), base + 0.9375e18);
    }

    // 3. Hard u-cap: open exactly at U_MAX·cap ok; one tick over reverts "u-cap" (both sides).
    //    U_MAX=0.8 ⇒ boundary at 8e18 notional for both PUT (cap=10e18) and CALL (cap=10e18).
    //    (Formerly used setUMax(0.5e18) — setter removed in Task 6; now uses fixed U_MAX.)
    function test_uCapBoundary_put() public {
        // U_MAX = 0.8e18, putCap = 10e18 → boundary at 8e18 notional
        uint256 boundary = book.U_MAX() * putCap / WAD; // = 8e18
        _fundPool(1_000_000e6);
        oracle.set(90e18);
        // IM for 8e18 PUT = _toUsdc(8e18 · Wput / 1e18) = _toUsdc(160e18) = 160e6 USDC
        _deposit(PUT, trader, 160e6);
        vm.prank(trader);
        book.openLong(PUT, boundary);       // exactly U_MAX·cap → ok (mark set by auto-accrue)
        _deposit(PUT, trader2, 1e6);
        vm.prank(trader2);
        vm.expectRevert(bytes("u-cap"));
        book.openLong(PUT, 1e16);           // pushes over → revert
    }

    function test_uCapBoundary_call() public {
        // U_MAX = 0.8e18, callCap = 10e18 → boundary at 8e18 notional
        uint256 boundary = book.U_MAX() * callCap / WAD; // = 8e18
        _seedCover(10e18, 50e18);           // cover ≥ 8e18 + tick so cover-gate passes to reach u-cap
        oracle.set(130e18);
        _deposit(CALL, trader, 5000e6);     // ample IM (mark ~fair value, well under 5000/8)
        vm.prank(trader);
        book.openLong(CALL, boundary);      // exactly U_MAX·cap → ok
        _deposit(CALL, trader2, 1e6);
        vm.prank(trader2);
        vm.expectRevert(bytes("u-cap"));
        book.openLong(CALL, 1e16);          // over → revert
    }

    // 4. cap=0 side ⇒ utilization 0, opens revert on the "cap" guard (which fires before u-cap).
    function test_capZeroSide() public {
        EverlastingBook zeroCap = new EverlastingBook(
            ICoverVault(address(vault)), ISpotOracle(address(oracle)),
            keeper, Kput, Wput, Kcall, 0, callCap, mockVol
        );
        zeroCap.lpDeposit(1000e6); // fund poolFree so the escrow check passes; "cap" is what blocks
        oracle.set(90e18);
        assertEq(zeroCap.utilization(PUT), 0);
        vm.prank(trader);
        zeroCap.deposit(PUT, 100e6);
        vm.prank(trader);
        vm.expectRevert(bytes("cap"));
        zeroCap.openLong(PUT, 1e18);         // auto-accrue sets mark; netWritten 1e18 > cap 0 → "cap"
    }

    // 5. Surcharge scales with periods AND advances continuously (autonomous accrue: no staleness
    //    forgoing — a later re-accrue folds the elapsed periods rather than skipping them).
    //    (Formerly used setUtilKappa(0.1e18); now κ=0.05e18 ⇒ surcharge halved: 0.4e18 vs 0.8e18.)
    function test_periodsScale() public {
        _seedCover(5e18, 50e18);
        oracle.set(130e18);
        _accrue(CALL);
        uint256 base = _mark(CALL) - book.intrinsic(CALL);
        _deposit(CALL, trader, 500e6);
        vm.prank(trader);
        book.openLong(CALL, 5e18);           // U = 0.5 ⇒ P_call(0.5)=8 ⇒ surcharge = 0.05·8 = 0.4e18
        uint256 perPeriod = base + 0.4e18;

        skip(7200);                          // exactly 2 periods
        _accrue(CALL);
        assertEq(_cf(CALL), 2 * perPeriod);

        skip(3600);                          // 1 more period — funding ADVANCES (no stale-forgo)
        _accrue(CALL);
        assertEq(_cf(CALL), 3 * perPeriod);
    }

    // 6. Conservation holds with surcharge ON through open→accrue→close (poolFree never underflows).
    //    (Formerly set utilKappa=0.1e18; now always-on at 0.05e18 — setter removed in Task 6.)
    function test_conservationWithSurchargeOn() public {
        _fundPool(1_000_000e6);
        oracle.set(90e18);                   // put intrinsic 10
        _accrue(PUT);
        _deposit(PUT, trader, 100e6);
        vm.prank(trader);
        book.openLong(PUT, 5e18);
        skip(3600);
        _accrue(PUT);                        // accrues base + surcharge
        _assertConservation();
        vm.prank(trader);
        book.close(PUT);                     // must not underflow poolFree
        _assertConservation();
    }

    // ── internal ────────────────────────────────────────────────────────────────

    function _assertConservation() internal view {
        assertEq(vault.poolUsdc(), book.poolFree() + book.putEscrow() + book.totalCollateral());
    }
}
