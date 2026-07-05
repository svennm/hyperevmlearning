# On-chain mark — design spec

**Slice:** `slice-onchain-mark` (off `slice-trustless-custody`). Kills audit finding **H2** (keeper mark not economically bounded) + H3-lite, and is the flagship fully-on-chain move: the funding mark becomes a **verifiable on-chain function** instead of a trusted keeper number.

**Approach (user-approved):** faithful desk-grade Black–Scholes with a rational `N(x)` approximation; realized-vol σ estimated on-chain with manipulation-resistant guards; the on-chain fair value **bounds** a keeper-posted mark (band), not replaces it (yet). Dependency: **solady `FixedPointMathLib`** (vendored at `lib/solady`, remap `solady/`) for `lnWad`/`expWad`/`sqrt`/`powWad`. All values WAD (1e18) unless noted.

**Audit gate:** build now; adversarial audit after; iterate if bad (user directive).

---

## Unit 1 — `src/OptionMath.sol` (pure library, stateless)

### `stdNormalCDF(int256 x) → uint256` (WAD ∈ [0, 1e18])
Abramowitz–Stegun 26.2.17 (the desk/Excel standard), max abs error ≈ 7.5e-8. For `x ≥ 0`:
```
t   = 1 / (1 + p·|x|)                    p = 0.2316419
φ   = (1/√(2π))·exp(−x²/2)               1/√(2π) = 0.39894228040143268
poly= t·(b1 + t·(b2 + t·(b3 + t·(b4 + t·b5))))   (Horner)
N   = 1 − φ·poly
```
Coeffs: `b1=0.319381530, b2=−0.356563782, b3=1.781477937, b4=−1.821255978, b5=1.330274429`.
Rules: `x<0 ⇒ N(x)=WAD−N(−x)` (symmetry). **Clamp** `|x| ≥ 8e18 ⇒ return 0 / WAD` (avoids expWad domain + poly divergence). Must be **monotonic non-decreasing** and return within `[0, WAD]`. Use `expWad` for `exp(−x²/2)` (guard: `x²/2` large ⇒ expWad→0, fine). WAD-scale every product/quotient carefully (this is the #1 audit target).

### `bsPrice(bool isCall, uint256 S, uint256 K, uint256 tau, uint256 sigma) → uint256` (WAD)
European BS, **r = 0** (no discount):
```
sigSqrtT = sigma·sqrt(tau)                  (sqrt of WAD tau via solady sqrt: sqrt(tau·1e18))
lnSK     = lnWad(S·1e18 / K)                (signed)
d1       = (lnSK + ½·sigma²·tau) / sigSqrtT (signed)      ½σ²τ = sigma·sigma·tau/(2·1e18·1e18)
d2       = d1 − sigSqrtT
call     = S·N(d1) − K·N(d2)
put      = K·N(−d2) − S·N(−d1)
```
Guards: `tau>0, sigma>0, S>0, K>0`; with r=0 the European put ≥ intrinsic (no early-exercise gap) so the everlasting invariant `mark ≥ intrinsic` holds.

### `everlastingMark(bool isCall, S, K, sigma, uint256 tauBase, uint8 nTerms) → uint256` (WAD)
White–SBF geometric basket, weights halve, maturities double, renormalized:
```
sum = Σ_{i=0}^{n-1} 2^{-(i+1)}·bsPrice(isCall, S, K, tauBase·2^i, sigma)
w   = Σ_{i=0}^{n-1} 2^{-(i+1)}   (= 1 − 2^{-n})
mark= sum / w
```
`nTerms ≈ 6` (weights halve ⇒ tail negligible; the mark is slow/forgiving). `tauBase` = calibration immutable (WAD years; caller-supplied). NOTE: the **capped put** (put spread) fair value is computed by the BOOK as `everlastingMark(PUT,K) − everlastingMark(PUT, K−Wput)`; the CALL is a single-strike uncapped call. `OptionMath` stays single-strike.

**Tests (`test/OptionMath.t.sol`):** `stdNormalCDF` vs hardcoded scipy values across x∈[−8,8] incl. tails (assert |err| ≤ 1e-9 tolerance band around scipy… use ~1e-7 given A&S); monotonicity fuzz; `N(0)=0.5`, `N(−x)+N(x)=1`; `bsPrice` vs scipy BS for a grid of (S,K,τ,σ); put ≥ intrinsic; call ≥ intrinsic; basket ≥ intrinsic and between shortest/longest-term BS.

---

## Unit 2 — `src/RealizedVol.sol` (contract) — manipulation-resistant σ

State: `uint256 varWad; uint256 lastPrice; uint256 lastTime;`. Reads the blended HL mark via the SAME oracle the book uses (`ISpotOracle.spotWad()` — inject in ctor).

Constants: `LAMBDA=0.99e18` (EWMA decay, ~3-day half-life at 1h), `R_MAX=0.10e18` (per-sample return cap), `PERIOD=3600`, `PERIODS_PER_YEAR=8760`, `SIGMA_MIN=0.20e18`, `SIGMA_MAX=3.0e18`.

### `updateVol()` external — permissionless, once per period
```
require(block.timestamp ≥ lastTime + PERIOD, "too soon")   // idempotent per grid slot
S = oracle.spotWad(); require(S > 0)
if (lastPrice == 0) { lastPrice=S; lastTime=block.timestamp; return }   // seed
r  = |S − lastPrice|·1e18 / lastPrice
if (r > R_MAX) r = R_MAX                                    // cap: one print can't inject unbounded var
r2 = r·r / 1e18
varWad = (LAMBDA·varWad + (1e18−LAMBDA)·r2) / 1e18          // EWMA
lastPrice = S; lastTime = block.timestamp
```
Manipulation resistance = blended-mark source + capped return + long half-life (each sample weight `1e18−LAMBDA` = 1% ⇒ no single sample drags σ) + σ clamp below.

### `sigma() → uint256` (WAD, annualized), and `ready() → bool`
```
annualVarScaled = varWad · PERIODS_PER_YEAR · 1e18
s = solady.sqrt(annualVarScaled)     // = σ_annual · 1e18   (check: varWad=v·1e18 ⇒ v·8760·1e36 ⇒ sqrt = √(v·8760)·1e18)
return clamp(s, SIGMA_MIN, SIGMA_MAX)
```
`ready()` = at least one EWMA update has occurred after seeding (`lastPrice != 0 && lastTime > seedTime`; track a `samples` counter, ready when `samples ≥ 1`).

**Tests (`test/RealizedVol.t.sol`):** seed then update; σ converges to a known value for a constant-vol synthetic price path; **cap enforcement** — a single 10× wick can't move σ more than `(1e18−LAMBDA)·R_MAX²`-bounded; `updateVol` reverts "too soon" within a period; clamp to [MIN,MAX]; `ready()` transitions; σ math scaling (feed a known variance, assert σ).

---

## Unit 3 — book integration (I do this; spec'd here) — the band

`EverlastingBook` gets an immutable `RealizedVol vol`, `OptionMath` usage, and immutable/owner `tauBase`, `markBandBps` (default 1000 = 10%), `nTerms`. In `postMark(side, newMark)`, after the `newMark ≥ intrinsic` / `≤ Wput` checks and BEFORE the deviation/funding block:
```
if (vol.ready()) {
    uint256 S = oracle.spotWad();
    uint256 fair = (side==PUT)
        ? everlastingMark(false,S,Kput,σ,τ,n) − everlastingMark(false,S,Kput−Wput,σ,τ,n)   // capped put spread
        : everlastingMark(true, S,Kcall,σ,τ,n);                                             // uncapped call
    σ = vol.sigma();
    require(newMark ≥ fair·(1e18−band)/1e18 && newMark ≤ fair·(1e18+band)/1e18, "mark band");
} // else: bootstrap — fall back to the existing ±MAX_MARK_DEV_BPS per-update cap until vol.ready()
```
This replaces H2's compounding *per-previous-mark* cap with an **absolute anchor to on-chain fair value** — a keeper can't ramp the mark (sub-hour or otherwise); it's pinned to ±band of a manipulation-resistant fair value. Shrink `band`→0 later ⇒ fully autonomous. Keep the P(U) surcharge unchanged (it's the AmPO-style manip-proof component; the BS band is the base-mark anchor).

**Tests:** keeper mark inside band ok / outside reverts "mark band"; the **H2 ramp attack** (sub-hour repeated postMarks) now bounded to the band; bootstrap path (vol not ready ⇒ old cap); conservation still holds; funding accrues from the banded mark.

---

## Scope / build order (dispatch)
1. **qwen:** Unit 1 `OptionMath.sol` + `test/OptionMath.t.sol` (scipy-referenced). **Highest audit priority — the WAD math.**
2. **qwen:** Unit 2 `RealizedVol.sol` + `test/RealizedVol.t.sol`.
3. **Claude:** Unit 3 book band integration + tests + wiring/deploy update; adversarial audit of all three; full suite green.

`tauBase`, `markBandBps`, `nTerms` are calibration params (owner/immutable) — the band tolerates calibration error, so exact values are tunable post-audit.
