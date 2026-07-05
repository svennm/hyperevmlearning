// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {EverlastingBook} from "../src/EverlastingBook.sol";
import {MockCoverVault} from "../src/mocks/MockCoverVault.sol";
import {MockOracle} from "../src/MockOracle.sol";
import {ICoverVault} from "../src/interfaces/ICoverVault.sol";
import {ISpotOracle} from "../src/interfaces/ISpotOracle.sol";

/// @title UtilPremium.t.sol — adversarial tests for the P(U) utilization-surcharge funding curve.
/// @notice Expected `cumFunding` values are hand-computed. Key identity the tests pin down:
///         base funding per period `f = oldMark − lastIntrinsic` (NOT the mark increment), plus
///         `surcharge = utilKappa · P(U) / WAD`. PUT: P=U; CALL: P=2U/(1−U)^3.
contract UtilPremiumTest is Test {
    EverlastingBook book;
    MockCoverVault  vault;
    MockOracle      oracle;

    address keeper  = address(0xBEEF);
    address trader  = address(0x7111);
    address trader2 = address(0x7222);

    uint256 constant WAD             = 1e18;
    uint256 constant Kput            = 100e18;
    uint256 constant Wput            = 20e18;
    uint256 constant Kcall           = 120e18;
    uint256 constant putCap          = 10e18;
    uint256 constant callCap         = 10e18;

    // This test contract is the owner (deploy unpranked).
    function setUp() public {
        vault  = new MockCoverVault();
        oracle = new MockOracle();
        book   = new EverlastingBook(
            ICoverVault(address(vault)), ISpotOracle(address(oracle)),
            keeper, Kput, Wput, Kcall, putCap, callCap
        );
    }

    // ── helpers ────────────────────────────────────────────────────────────────

    function _cf(EverlastingBook.Side side) internal view returns (uint256 cf) {
        (,, cf,,) = book.sideState(uint8(side));
    }

    function _fundPool(uint256 usdc) internal {
        book.lpDeposit(usdc); // owner op; raises poolFree
    }

    function _seedCover(uint256 hypeWad, uint256 pxWad) internal {
        vault.setMockPx(pxWad);
        vault.pullUsdc(address(this), 1_000_000_000e6); // fund pool so buyCover can pay
        vault.buyCover(hypeWad, type(uint256).max);
    }

    function _postMark(EverlastingBook.Side side, uint256 m) internal {
        vm.prank(keeper);
        book.postMark(side, m);
    }

    function _deposit(EverlastingBook.Side side, address t, uint256 usdc) internal {
        vm.prank(t);
        book.deposit(side, usdc);
    }

    // 1. κ=0 ⇒ pure base funding, surcharge inert (no-op proof).
    function test_noopWhenKappaZero() public {
        oracle.set(110e18);                 // put intrinsic = 0 (S>Kput)
        _postMark(EverlastingBook.Side.PUT, 3e18);   // mark=3, lastIntrinsic=0
        skip(3600);
        _postMark(EverlastingBook.Side.PUT, 3e18);   // f = 3−0 = 3, surcharge 0
        assertEq(_cf(EverlastingBook.Side.PUT), 3e18);
        assertEq(book.utilKappa(), 0);
    }

    // 2. PUT surcharge linear in U (U=0.5 ⇒ surcharge = κ·U = 0.05).
    function test_putSurchargeLinear() public {
        book.setUtilKappa(0.1e18);
        _fundPool(1_000_000e6);
        oracle.set(90e18);                  // put intrinsic = clamp(10,0,20) = 10
        _postMark(EverlastingBook.Side.PUT, 15e18);  // mark=15, lastIntrinsic=10
        _deposit(EverlastingBook.Side.PUT, trader, 100e6); // IM = 5·20 = 100 usdc
        vm.prank(trader);
        book.openLong(EverlastingBook.Side.PUT, 5e18);     // U = 5/10 = 0.5
        assertEq(book.utilization(EverlastingBook.Side.PUT), 0.5e18);
        skip(3600);
        _postMark(EverlastingBook.Side.PUT, 16e18);  // f = 15−10 = 5; surcharge = 0.1·0.5 = 0.05
        assertEq(_cf(EverlastingBook.Side.PUT), 5.05e18);
    }

    // 3. CALL surcharge convex (U=0.6 ⇒ shape 18.75 ⇒ surcharge = 0.1·18.75 = 1.875).
    function test_callSurchargeConvex() public {
        book.setUtilKappa(0.1e18);
        _seedCover(6e18, 50e18);
        oracle.set(130e18);                 // call intrinsic = 10
        _postMark(EverlastingBook.Side.COVERED_CALL, 15e18); // mark=15, lastIntrinsic=10
        _deposit(EverlastingBook.Side.COVERED_CALL, trader, 90e6); // IM = 6·15 = 90
        vm.prank(trader);
        book.openLong(EverlastingBook.Side.COVERED_CALL, 6e18);    // U = 0.6
        assertEq(book.utilization(EverlastingBook.Side.COVERED_CALL), 0.6e18);
        skip(3600);
        _postMark(EverlastingBook.Side.COVERED_CALL, 16e18); // f=5; surcharge=1.875
        assertEq(_cf(EverlastingBook.Side.COVERED_CALL), 6.875e18);
    }

    // 4. CALL shape clamps at MAX_UTIL_SHAPE (U=0.95, κ=1 ⇒ surcharge = MAX_UTIL_SHAPE).
    function test_callShapeClamp() public {
        book.setUtilKappa(1e18);
        book.setUMax(95e16);                // allow U up to 0.95
        _seedCover(10e18, 50e18);
        oracle.set(130e18);
        _postMark(EverlastingBook.Side.COVERED_CALL, 15e18);       // mark=15, lastIntrinsic=10
        _deposit(EverlastingBook.Side.COVERED_CALL, trader, 143e6);// IM = 9.5·15 = 142.5
        vm.prank(trader);
        book.openLong(EverlastingBook.Side.COVERED_CALL, 9.5e18);  // U = 0.95 (== uMax, boundary ok)
        skip(3600);
        _postMark(EverlastingBook.Side.COVERED_CALL, 16e18);       // f=5; surcharge = 1·1000 = 1000
        assertEq(_cf(EverlastingBook.Side.COVERED_CALL), 1005e18); // 5 + MAX_UTIL_SHAPE(1000)
    }

    // 5. Hard u-cap: open exactly at uMax·cap ok; one tick over reverts "u-cap" (both sides).
    function test_uCapBoundary_put() public {
        book.setUMax(0.5e18);               // 50% ⇒ boundary at 5e18 notional
        _fundPool(1_000_000e6);
        oracle.set(90e18);
        _postMark(EverlastingBook.Side.PUT, 15e18);
        _deposit(EverlastingBook.Side.PUT, trader, 100e6);
        vm.prank(trader);
        book.openLong(EverlastingBook.Side.PUT, 5e18);   // exactly uMax·cap → ok
        _deposit(EverlastingBook.Side.PUT, trader2, 1e6);
        vm.prank(trader2);
        vm.expectRevert(bytes("u-cap"));
        book.openLong(EverlastingBook.Side.PUT, 1e16);   // pushes over → revert
    }

    function test_uCapBoundary_call() public {
        book.setUMax(0.5e18);
        _seedCover(6e18, 50e18);            // cover ≥ 5e18 + tick so cover-gate passes to reach u-cap
        oracle.set(130e18);
        _postMark(EverlastingBook.Side.COVERED_CALL, 15e18);
        _deposit(EverlastingBook.Side.COVERED_CALL, trader, 90e6);
        vm.prank(trader);
        book.openLong(EverlastingBook.Side.COVERED_CALL, 5e18);   // exactly uMax·cap → ok
        _deposit(EverlastingBook.Side.COVERED_CALL, trader2, 1e6);
        vm.prank(trader2);
        vm.expectRevert(bytes("u-cap"));
        book.openLong(EverlastingBook.Side.COVERED_CALL, 1e16);   // over → revert
    }

    // 6. Owner lowers uMax BELOW current U ⇒ postMark must NOT revert; surcharge still computed
    //    honestly at the real U (0.6 ⇒ 18.75, not clamped — it is nowhere near saturation).
    function test_uMaxLoweredBelowU_noRevert() public {
        book.setUtilKappa(0.1e18);
        _seedCover(6e18, 50e18);
        oracle.set(130e18);
        _postMark(EverlastingBook.Side.COVERED_CALL, 15e18);
        _deposit(EverlastingBook.Side.COVERED_CALL, trader, 90e6);
        vm.prank(trader);
        book.openLong(EverlastingBook.Side.COVERED_CALL, 6e18);   // U = 0.6
        book.setUMax(0.5e18);               // now below current U — must not brick postMark
        skip(3600);
        _postMark(EverlastingBook.Side.COVERED_CALL, 16e18);      // succeeds; f=5, surcharge=1.875
        assertEq(_cf(EverlastingBook.Side.COVERED_CALL), 6.875e18);
    }

    // 7. cap=0 side ⇒ utilization 0, opens revert on the "cap" guard (which fires before u-cap).
    function test_capZeroSide() public {
        EverlastingBook zeroCap = new EverlastingBook(
            ICoverVault(address(vault)), ISpotOracle(address(oracle)),
            keeper, Kput, Wput, Kcall, 0, callCap
        );
        zeroCap.lpDeposit(1000e6); // fund poolFree so the escrow check passes; the "cap" guard is what blocks
        oracle.set(90e18);
        vm.prank(keeper);
        zeroCap.postMark(EverlastingBook.Side.PUT, 15e18);
        assertEq(zeroCap.utilization(EverlastingBook.Side.PUT), 0);
        _deposit2(zeroCap, EverlastingBook.Side.PUT, trader, 100e6);
        vm.prank(trader);
        vm.expectRevert(bytes("cap"));
        zeroCap.openLong(EverlastingBook.Side.PUT, 1e18);
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

    // 9. Surcharge scales with periods; >2h stale ⇒ no funding advance (pool-conservative), unchanged.
    function test_periodsScaleAndStaleForgo() public {
        book.setUtilKappa(0.1e18);
        _seedCover(5e18, 50e18);
        oracle.set(130e18);
        _postMark(EverlastingBook.Side.COVERED_CALL, 15e18);
        _deposit(EverlastingBook.Side.COVERED_CALL, trader, 75e6); // IM = 5·15 = 75
        vm.prank(trader);
        book.openLong(EverlastingBook.Side.COVERED_CALL, 5e18);    // U = 0.5 ⇒ shape 8 ⇒ surcharge 0.8
        skip(7200);                          // exactly 2 periods, still fresh (== MAX_MARK_AGE)
        _postMark(EverlastingBook.Side.COVERED_CALL, 16e18);       // (f=5 + 0.8)·2 = 11.6
        assertEq(_cf(EverlastingBook.Side.COVERED_CALL), 11.6e18);
        skip(7201);                          // > MAX_MARK_AGE ⇒ not fresh ⇒ no funding advance
        _postMark(EverlastingBook.Side.COVERED_CALL, 17e18);
        assertEq(_cf(EverlastingBook.Side.COVERED_CALL), 11.6e18); // unchanged
    }

    // 10. Conservation holds with surcharge ON through open→accrue→close (poolFree never underflows).
    function test_conservationWithSurchargeOn() public {
        book.setUtilKappa(0.1e18);
        _fundPool(1_000_000e6);
        oracle.set(90e18);                   // put intrinsic 10
        _postMark(EverlastingBook.Side.PUT, 15e18);
        _deposit(EverlastingBook.Side.PUT, trader, 100e6);
        vm.prank(trader);
        book.openLong(EverlastingBook.Side.PUT, 5e18);
        skip(3600);
        _postMark(EverlastingBook.Side.PUT, 16e18);  // accrues base + surcharge
        _assertConservation();
        vm.prank(trader);
        book.close(EverlastingBook.Side.PUT);        // must not underflow poolFree
        _assertConservation();
    }

    // ── internal ────────────────────────────────────────────────────────────────

    function _assertConservation() internal view {
        assertEq(vault.poolUsdc(), book.poolFree() + book.putEscrow() + book.totalCollateral());
    }

    function _deposit2(EverlastingBook b, EverlastingBook.Side side, address t, uint256 usdc) internal {
        vm.prank(t);
        b.deposit(side, usdc);
    }
}
