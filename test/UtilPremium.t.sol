// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {EverlastingBook} from "../src/EverlastingBook.sol";
import {MockCoverVault} from "../src/mocks/MockCoverVault.sol";
import {MockOracle} from "../src/MockOracle.sol";
import {MockVol} from "../src/mocks/MockVol.sol";
import {ICoverVault} from "../src/interfaces/ICoverVault.sol";
import {ISpotOracle} from "../src/interfaces/ISpotOracle.sol";

/// @title UtilPremium.t.sol — adversarial tests for the P(U) utilization-surcharge funding curve,
///        migrated to the autonomous mark (Task 5).
/// @notice The mark is now the on-chain computed fair value (no keeper postMark). The base funding
///         identity is unchanged: per period `f = storedMark − lastIntrinsic` (the extrinsic value),
///         plus `surcharge = utilKappa · P(U) / WAD`. PUT: P=U; CALL: P=2U/(1−U)^3. Because the mark
///         is computed, the base component is READ BACK (storedMark after the first accrue) rather
///         than hardcoded; the surcharge component is exact from κ and U.
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

    // 1. κ=0 ⇒ pure base funding, surcharge inert (no-op proof).
    function test_noopWhenKappaZero() public {
        oracle.set(110e18);                 // put intrinsic = 0 (S>Kput)
        _accrue(PUT);
        uint256 m0 = _mark(PUT);            // computed mark, lastIntrinsic=0
        skip(3600);
        _accrue(PUT);                        // f = m0 − 0 = m0, surcharge 0
        assertEq(_cf(PUT), m0);
        assertEq(book.utilKappa(), 0);
    }

    // 2. PUT surcharge linear in U (U=0.5 ⇒ surcharge = κ·U = 0.05).
    function test_putSurchargeLinear() public {
        book.setUtilKappa(0.1e18);
        _fundPool(1_000_000e6);
        oracle.set(90e18);                  // put intrinsic = clamp(10,0,20) = 10
        _accrue(PUT);
        uint256 base = _mark(PUT) - book.intrinsic(PUT); // extrinsic = mark − 10e18
        _deposit(PUT, trader, 100e6);        // IM = 5·20 = 100 usdc
        vm.prank(trader);
        book.openLong(PUT, 5e18);            // U = 5/10 = 0.5
        assertEq(book.utilization(PUT), 0.5e18);
        skip(3600);
        _accrue(PUT);                        // f = base; surcharge = 0.1·0.5 = 0.05e18
        assertEq(_cf(PUT), base + 0.05e18);
    }

    // 3. CALL surcharge convex (U=0.6 ⇒ shape 18.75 ⇒ surcharge = 0.1·18.75 = 1.875).
    function test_callSurchargeConvex() public {
        book.setUtilKappa(0.1e18);
        _seedCover(6e18, 50e18);
        oracle.set(130e18);                 // call intrinsic = 10
        _accrue(CALL);
        uint256 base = _mark(CALL) - book.intrinsic(CALL);
        _deposit(CALL, trader, 500e6);       // ample IM (= qty·mark)
        vm.prank(trader);
        book.openLong(CALL, 6e18);           // U = 0.6
        assertEq(book.utilization(CALL), 0.6e18);
        skip(3600);
        _accrue(CALL);                       // f=base; surcharge=1.875e18
        assertEq(_cf(CALL), base + 1.875e18);
    }

    // 4. CALL shape clamps at MAX_UTIL_SHAPE (U=0.95, κ=1 ⇒ surcharge = MAX_UTIL_SHAPE).
    function test_callShapeClamp() public {
        book.setUtilKappa(1e18);
        book.setUMax(95e16);                // allow U up to 0.95
        _seedCover(10e18, 50e18);
        oracle.set(130e18);
        _accrue(CALL);
        uint256 base = _mark(CALL) - book.intrinsic(CALL);
        _deposit(CALL, trader, 500e6);       // ample IM
        vm.prank(trader);
        book.openLong(CALL, 9.5e18);         // U = 0.95 (== uMax, boundary ok)
        skip(3600);
        _accrue(CALL);                       // f=base; surcharge = 1·1000 = 1000e18
        assertEq(_cf(CALL), base + 1000e18); // MAX_UTIL_SHAPE(1000)
    }

    // 5. Hard u-cap: open exactly at uMax·cap ok; one tick over reverts "u-cap" (both sides).
    function test_uCapBoundary_put() public {
        book.setUMax(0.5e18);               // 50% ⇒ boundary at 5e18 notional
        _fundPool(1_000_000e6);
        oracle.set(90e18);
        _deposit(PUT, trader, 100e6);
        vm.prank(trader);
        book.openLong(PUT, 5e18);           // exactly uMax·cap → ok (mark set by auto-accrue)
        _deposit(PUT, trader2, 1e6);
        vm.prank(trader2);
        vm.expectRevert(bytes("u-cap"));
        book.openLong(PUT, 1e16);           // pushes over → revert
    }

    function test_uCapBoundary_call() public {
        book.setUMax(0.5e18);
        _seedCover(6e18, 50e18);            // cover ≥ 5e18 + tick so cover-gate passes to reach u-cap
        oracle.set(130e18);
        _deposit(CALL, trader, 500e6);
        vm.prank(trader);
        book.openLong(CALL, 5e18);          // exactly uMax·cap → ok
        _deposit(CALL, trader2, 1e6);
        vm.prank(trader2);
        vm.expectRevert(bytes("u-cap"));
        book.openLong(CALL, 1e16);          // over → revert
    }

    // 6. Owner lowers uMax BELOW current U ⇒ accrue must NOT revert; surcharge still computed
    //    honestly at the real U (0.6 ⇒ 18.75, not clamped — nowhere near saturation).
    function test_uMaxLoweredBelowU_noRevert() public {
        book.setUtilKappa(0.1e18);
        _seedCover(6e18, 50e18);
        oracle.set(130e18);
        _accrue(CALL);
        uint256 base = _mark(CALL) - book.intrinsic(CALL);
        _deposit(CALL, trader, 500e6);
        vm.prank(trader);
        book.openLong(CALL, 6e18);          // U = 0.6
        book.setUMax(0.5e18);               // now below current U — must not brick accrue
        skip(3600);
        _accrue(CALL);                       // succeeds; f=base, surcharge=1.875e18
        assertEq(_cf(CALL), base + 1.875e18);
    }

    // 7. cap=0 side ⇒ utilization 0, opens revert on the "cap" guard (which fires before u-cap).
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

    // 8. Setters: onlyOwner + over-cap + uMax=0 all revert.
    function test_setterGuards() public {
        // Hoist getters out of the argument: expectRevert arms the immediately-next call, and a
        // getter-in-argument would consume the arm (foundry gotcha).
        uint256 kmax = book.MAX_UTIL_KAPPA();
        uint256 umax = book.MAX_UMAX();

        vm.prank(trader);
        vm.expectRevert(bytes("only owner"));
        book.setUtilKappa(1e18);

        vm.expectRevert(bytes("kappa>max"));
        book.setUtilKappa(kmax + 1);

        vm.prank(trader);
        vm.expectRevert(bytes("only owner"));
        book.setUMax(0.5e18);

        vm.expectRevert(bytes("uMax=0"));
        book.setUMax(0);

        vm.expectRevert(bytes("uMax>max"));
        book.setUMax(umax + 1);
    }

    // 9. Surcharge scales with periods AND advances continuously (autonomous accrue: no staleness
    //    forgoing — a later re-accrue folds the elapsed periods rather than skipping them).
    function test_periodsScale() public {
        book.setUtilKappa(0.1e18);
        _seedCover(5e18, 50e18);
        oracle.set(130e18);
        _accrue(CALL);
        uint256 base = _mark(CALL) - book.intrinsic(CALL);
        _deposit(CALL, trader, 500e6);
        vm.prank(trader);
        book.openLong(CALL, 5e18);           // U = 0.5 ⇒ shape 8 ⇒ surcharge 0.8e18
        uint256 perPeriod = base + 0.8e18;

        skip(7200);                          // exactly 2 periods
        _accrue(CALL);
        assertEq(_cf(CALL), 2 * perPeriod);

        skip(3600);                          // 1 more period — funding ADVANCES (no stale-forgo)
        _accrue(CALL);
        assertEq(_cf(CALL), 3 * perPeriod);
    }

    // 10. Conservation holds with surcharge ON through open→accrue→close (poolFree never underflows).
    function test_conservationWithSurchargeOn() public {
        book.setUtilKappa(0.1e18);
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
