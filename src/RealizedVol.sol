// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ISpotOracle} from "./interfaces/ISpotOracle.sol";
import {IVolSource} from "./interfaces/IVolSource.sol";

/// @title RealizedVol — manipulation-resistant annualized realized volatility (capped EWMA).
/// @notice σ is the ATM anchor for the on-chain mark. Manipulation guards:
///         (1) samples the blended HL mark (costly to move), (2) caps each per-sample return at
///         R_MAX so one print can't inject unbounded variance, (3) long EWMA half-life (λ=0.99,
///         ~3 days at 1h) so a single sample's weight (1−λ)=1% barely moves σ, (4) σ clamped to
///         [SIGMA_MIN, SIGMA_MAX], and (5) — AUDIT-M — each period folds the running MAX |return|
///         vs the period anchor, not whatever tick a caller happens to pick.
///
/// @dev    AUDIT-M (down-bias fix): the old model sampled one tick/period, first-caller-wins, so an
///         adversary could call at a quiet tick to bias σ DOWN. Now `updateVol()` is callable any
///         time: within a period it records a monotone high-water `maxRet = max(maxRet, |S−anchor|)`
///         (permissionless, cheap), and the EWMA fold happens once at the period boundary using that
///         max. An adversary can only RAISE maxRet, never lower it — any honest observer who sees a
///         spike locks it in, and the pool is incentivized to (higher σ ⇒ more funding). The anchor
///         being first-caller-set is safe: a manipulated anchor only inflates subsequent |returns|
///         (σ up = pool-conservative), never down. Requires ≥1 honest intra-period observation during
///         volatility, which is permissionless and cheap.
contract RealizedVol is IVolSource {
    uint256 public constant LAMBDA           = 0.99e18;  // EWMA decay
    uint256 public constant R_MAX            = 0.10e18;  // per-sample return cap (10%)
    uint256 public constant PERIOD           = 3600;     // 1 hour
    uint256 public constant PERIODS_PER_YEAR = 8760;
    uint256 public constant SIGMA_MIN        = 0.20e18;  // 20% annual floor
    uint256 public constant SIGMA_MAX        = 3.0e18;   // 300% annual ceiling
    /// @notice F1: min folded periods before ready() — the band never activates on a thin 1-sample σ.
    uint256 public constant READY_SAMPLES    = 3;
    uint256 internal constant WAD            = 1e18;

    ISpotOracle public immutable oracle;

    uint256 public varWad;      // EWMA variance (WAD)
    uint256 public anchorPrice; // price at the current period's start (WAD); 0 ⇒ unseeded
    uint256 public periodStart; // timestamp the current period was anchored
    uint256 public maxRet;      // running max |return| vs anchor this period (WAD, capped R_MAX)
    uint256 public samples;     // completed periods folded into the EWMA since seed

    event VolUpdated(uint256 price, uint256 maxRetFolded, uint256 varWad);

    constructor(ISpotOracle _oracle) {
        require(address(_oracle) != address(0), "oracle=0");
        oracle = _oracle;
    }

    /// @notice Permissionless. First call seeds the anchor; within a period, calls record the running
    ///         max |return|; the first call at/after the period boundary folds that max into the EWMA
    ///         and re-anchors. Intra-period calls never fold (σ advances at most once per PERIOD).
    function updateVol() external {
        uint256 S = oracle.spotWad();
        require(S > 0, "px=0");

        if (anchorPrice == 0) {
            // Seed on the first-ever observation — nothing to compare against yet.
            anchorPrice = S;
            periodStart = block.timestamp;
            return; // seed only — not counted as a sample
        }

        uint256 r = _cappedReturn(S); // |S−anchor|/anchor, capped at R_MAX

        if (block.timestamp >= periodStart + PERIOD) {
            // Close the completed period: the boundary tick counts toward the OLD anchor first.
            if (r > maxRet) maxRet = r;
            uint256 r2 = FixedPointMathLib.mulWad(maxRet, maxRet);
            // EWMA: var = λ·var + (1−λ)·maxRet²   (mulWad already ÷1e18 — no extra scaling)
            varWad = FixedPointMathLib.mulWad(LAMBDA, varWad)
                + FixedPointMathLib.mulWad(WAD - LAMBDA, r2);
            samples++;
            emit VolUpdated(S, maxRet, varWad);
            // Re-anchor a fresh period at the current price.
            anchorPrice = S;
            periodStart = block.timestamp;
            maxRet = 0;
        } else {
            // Same period: monotone high-water max — an adversary can only raise it, never lower it.
            if (r > maxRet) maxRet = r;
        }
    }

    /// @dev |S−anchor|/anchor in WAD, capped at R_MAX (guard 2).
    function _cappedReturn(uint256 S) internal view returns (uint256 r) {
        uint256 delta = S > anchorPrice ? S - anchorPrice : anchorPrice - S;
        r = FixedPointMathLib.divWad(delta, anchorPrice);
        if (r > R_MAX) r = R_MAX;
    }

    /// @notice Annualized σ (WAD), clamped to [SIGMA_MIN, SIGMA_MAX].
    /// @dev σ = √(var·periods/yr). varWad = v·1e18 ⇒ √(varWad·8760·1e18) = √(v·8760)·1e18 = σ·1e18.
    function sigma() public view returns (uint256) {
        uint256 s = FixedPointMathLib.sqrt(varWad * PERIODS_PER_YEAR * WAD);
        if (s < SIGMA_MIN) return SIGMA_MIN;
        if (s > SIGMA_MAX) return SIGMA_MAX;
        return s;
    }

    /// @notice True once at least READY_SAMPLES periods have folded (post-seed). Gating on N>1 keeps a
    ///         thin, easily-biased 1-sample σ from activating the book's fair-value band (F1).
    function ready() external view returns (bool) {
        return samples >= READY_SAMPLES;
    }
}
