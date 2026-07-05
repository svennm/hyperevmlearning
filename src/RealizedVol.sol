// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ISpotOracle} from "./interfaces/ISpotOracle.sol";

/// @title RealizedVol — manipulation-resistant annualized realized volatility (capped EWMA).
/// @notice σ is the ATM anchor for the on-chain mark. Four manipulation guards:
///         (1) samples the blended HL mark (costly to move), (2) caps each per-sample return at
///         R_MAX so one print can't inject unbounded variance, (3) long EWMA half-life (λ=0.99,
///         ~3 days at 1h) so a single sample's weight (1−λ)=1% barely moves σ, (4) σ clamped to
///         [SIGMA_MIN, SIGMA_MAX]. Permissionless + idempotent per PERIOD (timing bounded to the grid).
contract RealizedVol {
    uint256 public constant LAMBDA           = 0.99e18;  // EWMA decay
    uint256 public constant R_MAX            = 0.10e18;  // per-sample return cap (10%)
    uint256 public constant PERIOD           = 3600;     // 1 hour
    uint256 public constant PERIODS_PER_YEAR = 8760;
    uint256 public constant SIGMA_MIN        = 0.20e18;  // 20% annual floor
    uint256 public constant SIGMA_MAX        = 3.0e18;   // 300% annual ceiling
    uint256 internal constant WAD            = 1e18;

    ISpotOracle public immutable oracle;

    uint256 public varWad;    // per-period variance (WAD)
    uint256 public lastPrice; // last sampled price (WAD)
    uint256 public lastTime;  // last sample timestamp
    uint256 public samples;   // EWMA updates since seed

    event VolUpdated(uint256 price, uint256 rCapped, uint256 varWad);

    constructor(ISpotOracle _oracle) {
        require(address(_oracle) != address(0), "oracle=0");
        oracle = _oracle;
    }

    /// @notice Permissionless, once per PERIOD. First call seeds; subsequent calls EWMA-update.
    function updateVol() external {
        uint256 S = oracle.spotWad();
        require(S > 0, "px=0");

        if (lastPrice == 0) {
            // Seed on the first-ever observation — not time-gated (nothing to compare against yet).
            lastPrice = S;
            lastTime = block.timestamp;
            return; // seed only — not counted as a sample
        }

        // Subsequent samples are idempotent per PERIOD (timing bounded to the grid).
        require(block.timestamp >= lastTime + PERIOD, "too soon");

        uint256 delta = S > lastPrice ? S - lastPrice : lastPrice - S;
        uint256 r = FixedPointMathLib.divWad(delta, lastPrice); // |ΔS/S| in WAD
        if (r > R_MAX) r = R_MAX;                               // guard (2)
        uint256 r2 = FixedPointMathLib.mulWad(r, r);
        // EWMA: var = λ·var + (1−λ)·r²   (mulWad already ÷1e18 — no extra scaling)
        varWad = FixedPointMathLib.mulWad(LAMBDA, varWad) + FixedPointMathLib.mulWad(WAD - LAMBDA, r2);

        lastPrice = S;
        lastTime = block.timestamp;
        samples++;
        emit VolUpdated(S, r, varWad);
    }

    /// @notice Annualized σ (WAD), clamped to [SIGMA_MIN, SIGMA_MAX].
    /// @dev σ = √(var·periods/yr). varWad = v·1e18 ⇒ √(varWad·8760·1e18) = √(v·8760)·1e18 = σ·1e18.
    function sigma() public view returns (uint256) {
        uint256 s = FixedPointMathLib.sqrt(varWad * PERIODS_PER_YEAR * WAD);
        if (s < SIGMA_MIN) return SIGMA_MIN;
        if (s > SIGMA_MAX) return SIGMA_MAX;
        return s;
    }

    /// @notice True once at least one EWMA update (post-seed) has landed.
    function ready() external view returns (bool) {
        return samples >= 1;
    }
}
