// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {EverlastingBook} from "../src/EverlastingBook.sol";
import {MockCoverVault} from "../src/mocks/MockCoverVault.sol";
import {MockOracle} from "../src/MockOracle.sol";
import {MockVol} from "../src/mocks/MockVol.sol";
import {ICoverVault} from "../src/interfaces/ICoverVault.sol";
import {ISpotOracle} from "../src/interfaces/ISpotOracle.sol";

/// @notice Phase 2 — adaptive vol controller, on the autonomous mark (Task 6). A per-side integral
///         term `adaptiveMult += ADAPT_K·(U − U_STAR)` per period scales σ, making the computed fair
///         mark market-determined by pool fill-rate. Reworked for Task 6: ADAPT_K (0.02e18) and
///         U_STAR (0.5e18) are now public constants; `setAdaptiveParams` and the `adaptiveK()`/`uStar()`
///         getters were removed. The controller is ALWAYS ON. Tests use ADAPT_K=0.02e18, U_STAR=0.5e18:
///         step per period = 0.02·(U − 0.5), clamped [MULT_MIN=0.5e18, MULT_MAX=3e18].
contract BookAdaptiveTest is Test {
    EverlastingBook book;
    MockVol mockVol;
    MockCoverVault vault;
    MockOracle oracle;

    EverlastingBook.Side constant PUT = EverlastingBook.Side.PUT;
    uint8 constant PUT_U = 0;

    function setUp() public {
        vault = new MockCoverVault();
        oracle = new MockOracle();
        oracle.set(100e18);
        mockVol = new MockVol(); // sigma = 0.8e18, ready = true (constant σ isolates the controller)
        // keeper = owner = trader = this (small caps so a modest position drives real utilization)
        book = new EverlastingBook(
            ICoverVault(address(vault)), ISpotOracle(address(oracle)),
            address(this), 100e18, 20e18, 120e18, 10e18, 10e18, mockVol
        );
    }

    function _seedPoolFree(uint256 amt) internal { vault.pullUsdc(address(this), amt); }

    /// @dev Permissionless mark refresh (autonomous) — folds funding + the adaptive integral.
    function _accrue() internal { book.accrue(PUT); }

    /// @dev Open a put of `qty` (U = qty/putCap), funding IM + pool escrow. Mark set by auto-accrue.
    function _openPut(uint256 qty) internal {
        _seedPoolFree(300e6);
        book.deposit(PUT, 300e6);
        book.openLong(PUT, qty);
    }

    // ── controller inert when U == U_STAR ─────────────────────────────────────
    // Controller is ALWAYS ON (ADAPT_K=0.02e18 constant). The accumulator stays at WAD only when
    // utilization equals U_STAR exactly. Open 5e18 notional so U = 5/10 = 0.5 = U_STAR.

    function test_adaptive_inertAtTarget() public {
        assertEq(book.ADAPT_K(), 0.02e18, "ADAPT_K constant");
        assertEq(book.U_STAR(), 0.5e18,   "U_STAR constant");
        assertEq(book.adaptiveMult(PUT_U), 1e18, "mult seeded to WAD");

        _accrue();                         // baseline mark (sets lastMarkTime)
        _openPut(5e18);                    // U = 5/10 = 0.5 = U_STAR exactly

        uint256 fairBefore = book.fairMark(PUT);
        for (uint256 i = 0; i < 5; i++) { skip(3600); _accrue(); }

        // step = ADAPT_K·(0.5 − 0.5) = 0 → mult never moves
        assertEq(book.adaptiveMult(PUT_U), 1e18, "mult stays at WAD when U == U_STAR");
        assertEq(book.fairMark(PUT), fairBefore, "fair unchanged when mult stable");
        assertEq(book.effectiveSigma(PUT), mockVol.sigma(), "mult==WAD means no sigma shift");
    }

    // ── over-target demand richens the mark (the integral climbs) ───────────────
    // ADAPT_K=0.02, U=0.6, U_STAR=0.5 → step = 0.02·0.1 = 0.002/period.
    // 3 periods → +0.006. (Formerly used setAdaptiveParams(0.05e18,…) → step=0.005, +0.015.)

    function test_adaptive_overTargetRaisesMark() public {
        _accrue();                         // baseline (sets lastMarkTime)
        _openPut(6e18);                    // U = 6/10 = 0.6 > U_STAR 0.5
        assertEq(book.utilization(PUT), 0.6e18);

        uint256 multBefore = book.adaptiveMult(PUT_U);
        uint256 fairBefore = book.fairMark(PUT);

        for (uint256 i = 0; i < 3; i++) { skip(3600); _accrue(); }

        assertGt(book.adaptiveMult(PUT_U), multBefore, "mult climbed");
        assertGt(book.fairMark(PUT), fairBefore, "mark richened");
        assertGt(book.effectiveSigma(PUT), mockVol.sigma(), "mult>WAD lifts sigma above realized");
        // 3 periods · ADAPT_K·(0.6−0.5) = 0.02·0.1 = 0.002 ⇒ +0.006
        assertApproxEqAbs(book.adaptiveMult(PUT_U), 1e18 + 0.006e18, 1e15);
    }

    // ── under-target demand cheapens the mark ───────────────────────────────────
    // ADAPT_K=0.02, U=0, U_STAR=0.5 → step = −0.01/period.
    // 3 periods → −0.03. (Formerly used setAdaptiveParams(0.05e18,…) → step=−0.025, −0.075.)

    function test_adaptive_underTargetLowersMult() public {
        _accrue();                         // baseline; no position ⇒ U = 0

        uint256 multBefore = book.adaptiveMult(PUT_U);

        for (uint256 i = 0; i < 3; i++) { skip(3600); _accrue(); }

        assertLt(book.adaptiveMult(PUT_U), multBefore, "mult dropped");
        // 3 periods · ADAPT_K·(0−0.5) = 0.02·(−0.5) = −0.01 ⇒ −0.03
        assertApproxEqAbs(book.adaptiveMult(PUT_U), 1e18 - 0.03e18, 1e15);
    }

    // ── clamps ──────────────────────────────────────────────────────────────────
    // ADAPT_K=0.02, U=0.8 (= U_MAX, max openable), U_STAR=0.5 → step = 0.02·0.3 = 0.006/period.
    // Needs 334 periods to go from 1→3 (MULT_MAX). 400 periods ensures clamp is hit.
    // (Formerly used setAdaptiveParams(0.1e18, 0.1e18) + U=0.9; U_MAX=0.8 caps qty at 8e18.)

    function test_adaptive_clampsAtMax() public {
        _accrue();
        _openPut(8e18);                    // U = 0.8 (= U_MAX, the hard cap)
        assertEq(book.utilization(PUT), 0.8e18);

        for (uint256 i = 0; i < 400; i++) { skip(3600); _accrue(); }

        assertEq(book.adaptiveMult(PUT_U), 3e18, "clamped at MULT_MAX");
    }

    // ADAPT_K=0.02, U=0, U_STAR=0.5 → step = −0.01/period.
    // Needs 50 periods to go from 1→0.5 (MULT_MIN). 60 periods ensures clamp is hit.
    // (Formerly used setAdaptiveParams(0.1e18, 0.9e18) → step=−0.09, 20 periods sufficed.)

    function test_adaptive_clampsAtMin() public {
        _accrue();                         // U = 0

        for (uint256 i = 0; i < 60; i++) { skip(3600); _accrue(); }

        assertEq(book.adaptiveMult(PUT_U), 0.5e18, "clamped at MULT_MIN (sigma floor holds fairMark valid)");
    }
}
