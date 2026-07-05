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

    function test_tooSoon() public {
        _seed(100e18);
        vm.expectRevert("too soon");
        vol.updateVol();
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
}
