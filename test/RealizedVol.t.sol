// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {RealizedVol} from "../src/RealizedVol.sol";
import {MockOracle} from "../src/MockOracle.sol";

contract RealizedVolTest is Test {
    RealizedVol vol;
    MockOracle oracle;

    function setUp() public {
        oracle = new MockOracle();
        vol = new RealizedVol(oracle);
    }

    function _seed(uint256 px) internal {
        oracle.set(px);
        vol.updateVol(); // seed
    }

    function test_seed_thenReady() public {
        assertFalse(vol.ready());
        _seed(100e18);
        assertEq(vol.samples(), 0);
        assertFalse(vol.ready()); // seed is not a sample
        skip(3600);
        oracle.set(101e18);
        vol.updateVol();
        assertEq(vol.samples(), 1);
        assertTrue(vol.ready());
    }

    function test_sigma_inBounds() public {
        _seed(100e18);
        skip(3600);
        oracle.set(102e18);
        vol.updateVol();
        uint256 s = vol.sigma();
        assertGe(s, vol.SIGMA_MIN());
        assertLe(s, vol.SIGMA_MAX());
    }

    function test_sigma_floorWhenQuiet() public {
        // Tiny moves ⇒ variance ~0 ⇒ σ clamps to the floor.
        _seed(100e18);
        skip(3600);
        oracle.set(100e18); // no move
        vol.updateVol();
        assertEq(vol.sigma(), vol.SIGMA_MIN());
    }

    /// @notice The manipulation guard: a single 10× wick is capped, so σ does NOT hit the ceiling.
    ///         Without the R_MAX cap the raw return (900%) would blow variance past SIGMA_MAX.
    function test_cappedWick_doesNotMaxSigma() public {
        _seed(100e18);
        skip(3600);
        oracle.set(1000e18); // 10x — raw return 900%, capped to R_MAX=10%
        vol.updateVol();
        uint256 s = vol.sigma();
        assertLt(s, vol.SIGMA_MAX());          // cap worked — not slammed to the ceiling
        assertGt(s, vol.SIGMA_MIN());          // but it did register vol
        // one capped 10% sample at 1% EWMA weight ⇒ σ ≈ sqrt((1-λ)·R_MAX²·8760) ≈ 0.936
        assertApproxEqAbs(s, 0.936e18, 0.02e18);
    }

    function test_updateVol_pxZeroReverts() public {
        skip(3600);
        oracle.set(0);
        vm.expectRevert(bytes("px=0"));
        vol.updateVol();
    }

    // ── AUDIT-M: max|return| sampling (kills the first-caller down-bias) ───────────

    /// @notice The fix: within a period the running MAX |return| vs the period anchor is what
    ///         folds into the EWMA — NOT whatever tick the boundary caller happens to pick. An
    ///         honest observer records the intra-period spike; a later "quiet" boundary caller
    ///         cannot suppress it. Under the old first-caller model σ would clamp to the floor.
    function test_maxReturn_capturedNotBoundaryTick() public {
        _seed(100e18);            // anchor = 100 at t0
        // honest observer records the intra-period spike (same period, no fold)
        oracle.set(110e18);       // +10% (== R_MAX)
        vol.updateVol();
        assertEq(vol.samples(), 0, "intra-period must not fold");
        // price calms back down before the boundary
        oracle.set(100.5e18);
        skip(3600);
        vol.updateVol();          // boundary caller at a quiet +0.5% tick
        assertEq(vol.samples(), 1, "boundary folds exactly one sample");
        // σ reflects the recorded 10% max, NOT the 0.5% boundary tick (which would floor σ)
        assertApproxEqAbs(vol.sigma(), 0.936e18, 0.03e18);
        assertGt(vol.sigma(), 0.5e18); // decisively above the floor a 0.5% tick would give
    }

    /// @notice Intra-period calls are permissionless and only record — they never fold/advance σ.
    function test_intraPeriodCall_recordsButDoesNotFold() public {
        _seed(100e18);
        oracle.set(103e18);
        vol.updateVol();
        assertEq(vol.samples(), 0);
        oracle.set(105e18);
        vol.updateVol();
        assertEq(vol.samples(), 0);
    }

    /// @notice Once a high max is recorded, a subsequent quiet same-period observation can't lower it
    ///         (monotone high-water mark). The adversary cannot walk σ down.
    function test_recordedMaxIsMonotonicWithinPeriod() public {
        _seed(100e18);            // anchor = 100
        oracle.set(108e18);       // +8%
        vol.updateVol();          // records max = 8%
        oracle.set(100e18);       // back to flat
        vol.updateVol();          // must NOT lower the recorded max
        skip(3600);
        oracle.set(100e18);
        vol.updateVol();          // fold → reflects 8%, not 0
        // σ ≈ sqrt((1-λ)·0.08²·8760) ≈ 0.748
        assertApproxEqAbs(vol.sigma(), 0.748e18, 0.03e18);
    }

    /// @notice A fold happens at most once per period; a second call in the same new period only records.
    function test_foldOncePerPeriod() public {
        _seed(100e18);
        skip(3600);
        oracle.set(105e18);
        vol.updateVol();          // fold #1
        assertEq(vol.samples(), 1);
        oracle.set(106e18);
        vol.updateVol();          // same period → record only
        assertEq(vol.samples(), 1);
    }
}
