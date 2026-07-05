// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {EverlastingBook} from "../src/EverlastingBook.sol";
import {RealizedVol} from "../src/RealizedVol.sol";
import {MockCoverVault} from "../src/mocks/MockCoverVault.sol";
import {MockOracle} from "../src/MockOracle.sol";
import {ICoverVault} from "../src/interfaces/ICoverVault.sol";
import {ISpotOracle} from "../src/interfaces/ISpotOracle.sol";

/// @notice Phase 2 — adaptive vol controller. A per-side integral term
///         `adaptiveMult += k·(U − uStar)` per period scales σ (level-shift under the ±band), making
///         the mark market-determined by pool fill-rate. Default inert (k=0, mult=WAD). Manip-proof
///         (U needs real size), slow + clamped [MULT_MIN, MULT_MAX], σ re-clamped [SIGMA_MIN, CEIL].
contract BookAdaptiveTest is Test {
    EverlastingBook book;
    RealizedVol vol;
    MockCoverVault vault;
    MockOracle oracle;

    EverlastingBook.Side constant PUT = EverlastingBook.Side.PUT;
    uint8 constant PUT_U = 0;

    function setUp() public {
        vault = new MockCoverVault();
        oracle = new MockOracle();
        oracle.set(100e18);
        // keeper = owner = trader = this (small caps so a modest position drives real utilization)
        book = new EverlastingBook(
            ICoverVault(address(vault)), ISpotOracle(address(oracle)),
            address(this), 100e18, 20e18, 120e18, 10e18, 10e18
        );
        vol = new RealizedVol(oracle);
        book.setVol(vol);
        vol.updateVol();                                   // seed @ 100
        // READY_SAMPLES(3) folds so the band is ACTIVE (adaptive controller tested on the real path).
        skip(3600); oracle.set(101e18); vol.updateVol();   // sample 1
        skip(3600); oracle.set(100e18); vol.updateVol();   // sample 2
        skip(3600); oracle.set(101e18); vol.updateVol();   // sample 3 → ready()
        oracle.set(100e18);  // clean ATM
    }

    function _seedPoolFree(uint256 amt) internal { vault.pullUsdc(address(this), amt); }
    function _postFair() internal { book.postMark(PUT, book.fairMark(PUT)); }

    /// @dev Open a put of `qty` (U = qty/putCap), funding IM + pool escrow. Assumes a mark is posted.
    function _openPut(uint256 qty) internal {
        _seedPoolFree(300e6);
        book.deposit(PUT, 300e6);
        book.openLong(PUT, qty);
    }

    // ── default inert ─────────────────────────────────────────────────────────

    function test_adaptive_inertByDefault() public {
        assertEq(book.adaptiveMult(PUT_U), 1e18, "mult seeded to WAD");
        assertEq(book.adaptiveK(), 0, "k off by default");
        assertEq(book.uStar(), 0.5e18, "uStar default 0.5");

        _postFair();                       // baseline mark (k=0, sets lastMarkTime)
        uint256 fairBefore = book.fairMark(PUT);
        for (uint256 i = 0; i < 5; i++) { skip(3600); _postFair(); }

        assertEq(book.adaptiveMult(PUT_U), 1e18, "mult never moves while k=0");
        assertEq(book.fairMark(PUT), fairBefore, "fair unchanged (sigma + mult stable)");
        assertEq(book.effectiveSigma(PUT), vol.sigma(), "mult==WAD means no sigma shift");
    }

    // ── over-target demand richens the mark (the integral climbs) ───────────────

    function test_adaptive_overTargetRaisesMark() public {
        _postFair();                       // baseline (k=0)
        _openPut(6e18);                    // U = 6/10 = 0.6 > uStar 0.5
        assertEq(book.utilization(PUT), 0.6e18);

        book.setAdaptiveParams(0.05e18, 0.5e18);
        uint256 multBefore = book.adaptiveMult(PUT_U);
        uint256 fairBefore = book.fairMark(PUT);

        for (uint256 i = 0; i < 3; i++) { skip(3600); _postFair(); }

        assertGt(book.adaptiveMult(PUT_U), multBefore, "mult climbed");
        assertGt(book.fairMark(PUT), fairBefore, "mark richened");
        assertGt(book.effectiveSigma(PUT), vol.sigma(), "mult>WAD lifts sigma above realized");
        // 3 periods · k·(0.6−0.5) = 0.05·0.1 = 0.005 ⇒ +0.015
        assertApproxEqAbs(book.adaptiveMult(PUT_U), 1e18 + 0.015e18, 1e15);
    }

    // ── under-target demand cheapens the mark ───────────────────────────────────

    function test_adaptive_underTargetLowersMult() public {
        _postFair();                       // baseline; no position ⇒ U = 0
        book.setAdaptiveParams(0.05e18, 0.5e18);
        uint256 multBefore = book.adaptiveMult(PUT_U);

        for (uint256 i = 0; i < 3; i++) { skip(3600); _postFair(); }

        assertLt(book.adaptiveMult(PUT_U), multBefore, "mult dropped");
        // 3 periods · k·(0−0.5) = −0.025 ⇒ −0.075
        assertApproxEqAbs(book.adaptiveMult(PUT_U), 1e18 - 0.075e18, 1e15);
    }

    // ── clamps ──────────────────────────────────────────────────────────────────

    function test_adaptive_clampsAtMax() public {
        _postFair();
        _openPut(9e18);                    // U = 0.9
        assertEq(book.utilization(PUT), 0.9e18);
        book.setAdaptiveParams(0.1e18, 0.1e18); // step = 0.1·(0.9−0.1) = 0.08 / period

        for (uint256 i = 0; i < 40; i++) { skip(3600); _postFair(); }

        assertEq(book.adaptiveMult(PUT_U), 3e18, "clamped at MULT_MAX");
    }

    function test_adaptive_clampsAtMin() public {
        _postFair();                       // U = 0
        book.setAdaptiveParams(0.1e18, 0.9e18); // step = 0.1·(0−0.9) = −0.09 / period

        for (uint256 i = 0; i < 20; i++) { skip(3600); _postFair(); }

        assertEq(book.adaptiveMult(PUT_U), 0.5e18, "clamped at MULT_MIN (sigma floor holds fairMark valid)");
    }

    // ── owner + hard-cap guards ─────────────────────────────────────────────────

    function test_adaptive_setParams_guards() public {
        vm.prank(address(0xBAD));
        vm.expectRevert("only owner");
        book.setAdaptiveParams(0.05e18, 0.5e18);

        vm.expectRevert("k>max");
        book.setAdaptiveParams(0.1e18 + 1, 0.5e18);

        vm.expectRevert("uStar range");
        book.setAdaptiveParams(0.05e18, 0);

        vm.expectRevert("uStar range");
        book.setAdaptiveParams(0.05e18, 1e18);

        book.setAdaptiveParams(0.05e18, 0.5e18);
        assertEq(book.adaptiveK(), 0.05e18);
        assertEq(book.uStar(), 0.5e18);
    }
}
