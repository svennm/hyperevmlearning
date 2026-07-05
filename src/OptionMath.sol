// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title OptionMath — Black–Scholes (r = 0) + normal CDF for the on-chain everlasting mark.
/// @notice Pure WAD (1e18) fixed-point. `stdNormalCDF` uses Abramowitz–Stegun 26.2.17
///         (max abs error ~7.5e-8). Skew is applied by the CALLER (per-strike σ) — this lib is
///         skew-agnostic and takes a scalar σ.
library OptionMath {
    int256  internal constant WAD  = 1e18;
    uint256 internal constant UWAD = 1e18;

    // Abramowitz–Stegun 26.2.17 constants (WAD, signed)
    int256 internal constant P            =  231641900000000000;   // 0.2316419
    int256 internal constant B1           =  319381530000000000;   // 0.319381530
    int256 internal constant B2           = -356563782000000000;   // -0.356563782
    int256 internal constant B3           = 1781477937000000000;   // 1.781477937
    int256 internal constant B4           = -1821255978000000000;  // -1.821255978
    int256 internal constant B5           = 1330274429000000000;   // 1.330274429
    int256 internal constant INV_SQRT_2PI =  398942280401432677;   // 1/sqrt(2π)
    int256 internal constant CLAMP        = 8e18;                   // |x| ≥ 8 ⇒ N = 0/1

    /// @notice Standard normal CDF N(x). Input signed WAD; output WAD in [0, 1e18], monotonic.
    function stdNormalCDF(int256 x) internal pure returns (uint256) {
        if (x >= CLAMP) return UWAD;
        if (x <= -CLAMP) return 0;
        int256 ax = x < 0 ? -x : x;

        // t = 1 / (1 + p·|x|)   (denominator > WAD > 0)
        int256 t = FixedPointMathLib.sDivWad(WAD, WAD + FixedPointMathLib.sMulWad(P, ax));

        // Horner: t·(b1 + t·(b2 + t·(b3 + t·(b4 + t·b5))))
        int256 poly = FixedPointMathLib.sMulWad(B5, t);
        poly = FixedPointMathLib.sMulWad(B4 + poly, t);
        poly = FixedPointMathLib.sMulWad(B3 + poly, t);
        poly = FixedPointMathLib.sMulWad(B2 + poly, t);
        poly = FixedPointMathLib.sMulWad(B1 + poly, t);

        // φ(x) = (1/√(2π))·exp(−x²/2)  — x² ≥ 0 so expWad arg ≤ 0 (safe; → 0 for large |x|)
        int256 x2  = FixedPointMathLib.sMulWad(x, x);
        int256 phi = FixedPointMathLib.sMulWad(INV_SQRT_2PI, FixedPointMathLib.expWad(-(x2 / 2)));

        // N(|x|) = 1 − φ·poly ∈ (0.5, 1]; tail = φ·poly ∈ [0, 0.5) so WAD − tail can't underflow.
        int256 tail = FixedPointMathLib.sMulWad(phi, poly);
        uint256 nAbs = uint256(WAD - tail);
        return x < 0 ? UWAD - nAbs : nAbs;
    }

    /// @notice European Black–Scholes price with r = 0. WAD in/out.
    function bsPrice(bool isCall, uint256 S, uint256 K, uint256 tau, uint256 sigma)
        internal
        pure
        returns (uint256)
    {
        require(S > 0 && K > 0 && tau > 0 && sigma > 0, "bs:0");
        // σ√τ  — sqrt(tau·1e18) = √τ in WAD
        uint256 sigSqrtT = FixedPointMathLib.mulWad(sigma, FixedPointMathLib.sqrt(tau * UWAD));
        require(sigSqrtT > 0, "bs:volT");

        // d1 = (ln(S/K) + ½σ²τ) / (σ√τ) ; d2 = d1 − σ√τ
        int256 lnSK = FixedPointMathLib.lnWad(int256(FixedPointMathLib.divWad(S, K)));
        int256 halfSig2Tau =
            int256(FixedPointMathLib.mulWad(FixedPointMathLib.mulWad(sigma, sigma), tau) / 2);
        int256 d1 = FixedPointMathLib.sDivWad(lnSK + halfSig2Tau, int256(sigSqrtT));
        int256 d2 = d1 - int256(sigSqrtT);

        // r = 0 ⇒ no discount. Fixed-point noise can make the difference dip below 0 at deep
        // OTM (both terms tiny) — floor at 0 rather than underflow-revert.
        if (isCall) {
            uint256 a = FixedPointMathLib.mulWad(S, stdNormalCDF(d1));
            uint256 b = FixedPointMathLib.mulWad(K, stdNormalCDF(d2));
            return a > b ? a - b : 0;
        } else {
            uint256 a = FixedPointMathLib.mulWad(K, stdNormalCDF(-d2));
            uint256 b = FixedPointMathLib.mulWad(S, stdNormalCDF(-d1));
            return a > b ? a - b : 0;
        }
    }

    /// @notice White–SBF everlasting mark: renormalized geometric basket of BS prices.
    ///         weight 2^{-(i+1)}, maturity tauBase·2^i, i = 0..nTerms−1.
    function everlastingMark(
        bool isCall,
        uint256 S,
        uint256 K,
        uint256 sigma,
        uint256 tauBase,
        uint8 nTerms
    ) internal pure returns (uint256) {
        require(nTerms > 0 && nTerms <= 32, "mark:n");
        uint256 sum;
        uint256 tau = tauBase;
        for (uint256 i = 0; i < nTerms; i++) {
            sum += FixedPointMathLib.mulWad(bsPrice(isCall, S, K, tau, sigma), UWAD >> (i + 1));
            tau <<= 1;
        }
        return FixedPointMathLib.divWad(sum, UWAD - (UWAD >> nTerms)); // ÷ (1 − 2^{-n})
    }
}
