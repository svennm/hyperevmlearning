// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {OptionMath} from "../src/OptionMath.sol";

/// @notice Precision tests for OptionMath — CDF vs scipy reference values, put-call parity, ATM BS.
///         A&S 26.2.17 max error ~7.5e-8; tolerance 5e11 (5e-7 WAD) catches scaling bugs while
///         allowing the approximation + fixed-point rounding.
contract OptionMathTest is Test {
    uint256 constant WAD = 1e18;
    uint256 constant CDF_TOL = 5e11;  // 5e-7
    uint256 constant BS_TOL  = 5e15;  // 0.005

    // ── stdNormalCDF vs scipy (scipy.stats.norm.cdf) ──────────────────────────
    function test_cdf_reference() public pure {
        assertApproxEqAbs(OptionMath.stdNormalCDF(0),        0.5e18,               CDF_TOL);
        assertApproxEqAbs(OptionMath.stdNormalCDF(0.5e18),   691462461274013100,   CDF_TOL); // N(0.5)
        assertApproxEqAbs(OptionMath.stdNormalCDF(1e18),     841344746068542900,   CDF_TOL); // N(1)
        assertApproxEqAbs(OptionMath.stdNormalCDF(2e18),     977249868051820800,   CDF_TOL); // N(2)
        assertApproxEqAbs(OptionMath.stdNormalCDF(3e18),     998650101968369900,   CDF_TOL); // N(3)
        assertApproxEqAbs(OptionMath.stdNormalCDF(-1e18),    158655253931457070,   CDF_TOL); // N(-1)
        assertApproxEqAbs(OptionMath.stdNormalCDF(-2e18),    22750131948179190,    CDF_TOL); // N(-2)
    }

    function test_cdf_symmetry() public pure {
        int256[4] memory xs = [int256(0.3e18), 1e18, 2.5e18, 4e18];
        for (uint256 i = 0; i < xs.length; i++) {
            uint256 a = OptionMath.stdNormalCDF(xs[i]);
            uint256 b = OptionMath.stdNormalCDF(-xs[i]);
            assertApproxEqAbs(a + b, WAD, 1e6); // within a few wei of 1
        }
    }

    function test_cdf_monotonic(int256 a, int256 b) public pure {
        a = bound(a, -9e18, 9e18);
        b = bound(b, -9e18, 9e18);
        if (a > b) (a, b) = (b, a);
        assertLe(OptionMath.stdNormalCDF(a), OptionMath.stdNormalCDF(b));
    }

    function test_cdf_bounds(int256 x) public pure {
        x = bound(x, -50e18, 50e18);
        assertLe(OptionMath.stdNormalCDF(x), WAD);
    }

    function test_cdf_clamp() public pure {
        assertEq(OptionMath.stdNormalCDF(8e18), WAD);
        assertEq(OptionMath.stdNormalCDF(-8e18), 0);
        assertEq(OptionMath.stdNormalCDF(20e18), WAD);
        assertEq(OptionMath.stdNormalCDF(-20e18), 0);
    }

    // ── Black–Scholes (r = 0) ─────────────────────────────────────────────────
    function test_bs_atm() public pure {
        // S=K=100, τ=1, σ=0.5 ⇒ call=put=19.74126514 ; σ=0.2 ⇒ 7.96556746
        uint256 c50 = OptionMath.bsPrice(true, 100e18, 100e18, 1e18, 0.5e18);
        uint256 p50 = OptionMath.bsPrice(false, 100e18, 100e18, 1e18, 0.5e18);
        assertApproxEqAbs(c50, 19741265136584740000, BS_TOL);
        assertApproxEqAbs(p50, 19741265136584740000, BS_TOL);
        assertApproxEqAbs(c50, p50, 1e12); // ATM call == put at r=0

        uint256 c20 = OptionMath.bsPrice(true, 100e18, 100e18, 1e18, 0.2e18);
        assertApproxEqAbs(c20, 7965567455405810000, BS_TOL);
    }

    function test_bs_putCallParity() public pure {
        // r = 0 ⇒ C − P = S − K exactly (up to CDF symmetry error).
        uint256 S = 110e18; uint256 K = 100e18;
        uint256 c = OptionMath.bsPrice(true, S, K, 1e18, 0.5e18);
        uint256 p = OptionMath.bsPrice(false, S, K, 1e18, 0.5e18);
        assertApproxEqAbs(c - p, S - K, 1e13);
    }

    function test_bs_intrinsic() public pure {
        // ITM call ≥ S−K ; ITM put ≥ K−S
        uint256 call = OptionMath.bsPrice(true, 130e18, 100e18, 1e18, 0.5e18);
        assertGe(call, 30e18);
        uint256 put = OptionMath.bsPrice(false, 70e18, 100e18, 1e18, 0.5e18);
        assertGe(put, 30e18);
    }

    // ── everlasting basket ────────────────────────────────────────────────────
    function test_everlasting_basket() public pure {
        uint256 S = 100e18; uint256 K = 100e18; uint256 sig = 0.8e18; uint256 tb = 0.1e18;
        uint256 mark = OptionMath.everlastingMark(true, S, K, sig, tb, 6);
        uint256 shortest = OptionMath.bsPrice(true, S, K, tb, sig);              // τ = tauBase
        uint256 longest  = OptionMath.bsPrice(true, S, K, tb << 5, sig);         // τ = tauBase·2^5
        assertGt(mark, 0);
        assertGt(mark, shortest);   // basket includes longer, more valuable maturities
        assertLt(mark, longest);    // but is weighted toward the short end
    }
}
