# Utilization-Premium Funding Curve — design spec

**Slice:** `slice-util-premium` (off `slice-delta-hedge-t1`, contains live `EverlastingBook` + `DeltaHedgeManager`).
**Date:** 2026-07-04. **Contract touched:** `src/EverlastingBook.sol` only.

## Goal
Add an **endogenous, on-chain utilization surcharge** to funding so the pool self-prices
concentration: as one side fills, funding rises. This is the AmPO utilization premium
(Bichuch–Feinstein, arXiv 2605.19146, Def 3.1 / Ex 3.2) expressed in the everlasting funding
metric — computed from *internal state* (`netWritten`, cap), so it needs no oracle and is
verifiable/arbitrable. Also the writer-solvency knob: writers get over-compensated exactly as
they go one-sided/wrong-way. Pairs with a hard utilization cap = the G2 survivability gate.

## Funding change
Current (`postMark`): `cumFunding += (mark − lastIntrinsic) · periods`.
New:
```
baseF      = mark ≥ lastIntrinsic ? mark − lastIntrinsic : 0     // unchanged
surchargeF = utilSurcharge(side)                                 // NEW, κ·P(U), current U
cumFunding += (baseF + surchargeF) · periods
```
`periods` is already bounded to {0,1,2} by `isFresh`+`MAX_MARK_AGE`=2h (finding #3 is real but
bounded to ≤2h; beyond 2h funding is forgone = pool-conservative). Keep the multiplier for keeper
resilience; document the ≤2-period stale-rate bound. Do NOT `require(periods==1)` (bricks a late keeper).

## Utilization + shapes (all WAD, WAD=1e18)
```
U(side)   = cap == 0 ? 0 : min(netWritten · WAD / cap, WAD)        // ∈ [0, WAD]
shape_put (U) = U                                                  // linear, ceiling WAD at U=1
shape_call(U) = U < WAD ? min( 2·U·WAD·WAD·WAD / (WAD−U)^3 , MAX_UTIL_SHAPE ) : MAX_UTIL_SHAPE
utilSurcharge = utilKappa · shape / WAD                            // WAD price / unit / period
```
- Faithful to AmPO shapes: put `P=κU` (linear→ceiling), call `P=κ·2U/(1−U)^3` (divergent).
- Magnitude lives in `utilKappa` (κ), a keeper/owner knob; the curve provides the SHAPE.
- **Overflow proof:** numerator `2·U·WAD^3 ≤ 2·1e18·1e54 = 2e72 < 2^256≈1.15e77`. With the hard
  cap `uMax ≤ MAX_UMAX < WAD`, `U < WAD` always ⇒ `(WAD−U)^3 ≥ (WAD−MAX_UMAX)^3 > 0`, no div-by-0.
  Belt: `min(…, MAX_UTIL_SHAPE)` clamps even a misconfigured/edge U (e.g. keeper lowers uMax below
  current U). `require`/guard `WAD−U > 0` before the cube.

## Hard utilization cap (survivability gate)
In `openLong`, after the existing `netWritten ≤ cap` check, add per side:
```
require(netWritten_after · WAD ≤ uMax · cap, "u-cap")
```
(PUT: `ps.netWritten·WAD ≤ uMax·putCapNotional`; CALL: `(ss.netWritten+qty)·WAD ≤ uMax·callCapNotional`.)
Bounds `U ≤ uMax`, which both enforces the ≤0.60 survivability cap AND keeps the divergent call
curve provably finite. Overflow: `cap·WAD ≤ ~1e38`, fine.

## New state / params (owner-set, hard-capped)
```
uint256 constant WAD             = 1e18;   // (already implied; ensure present)
uint256 constant MAX_UTIL_KAPPA  = 1e18;   // κ ceiling (1.0 WAD/period — generous; owner sets far below)
uint256 constant MAX_UMAX        = 95e16;  // 0.95·WAD — keeps (WAD−U)^3 bounded away from 0
uint256 constant MAX_UTIL_SHAPE  = 1000e18;// clamp on shape_call

uint256 public utilKappa;   // default 0  → surcharge OFF (backward-compatible; owner turns on)
uint256 public uMax;        // set = WAD in constructor → 100% (no extra cap) until owner tightens
```
**Fail-safe defaults:** `utilKappa=0` (no surcharge), `uMax=WAD` (no extra cap) ⇒ new code is a
**no-op until explicitly activated**. `uMax` MUST be initialized to `WAD` in the constructor body
(0 would brick every openLong — the exact fail-open/brick trap to avoid).

Setters (onlyOwner, like pause/setKeeper): `setUtilKappa(x)` require `x ≤ MAX_UTIL_KAPPA`;
`setUMax(x)` require `x > 0 && x ≤ MAX_UMAX`. Events `UtilKappaSet`, `UMaxSet`. Public view
`utilization(Side) → U`.

## Adversarial test matrix (`test/UtilPremium.t.sol`)
1. κ=0 ⇒ funding identical to pre-change (no-op proof).
2. put surcharge linear in U; hits `κ` at U→cap.
3. call surcharge convex, monotonic ↑, and **finite at uMax** (e.g. U=0.6 ⇒ shape=18.75·WAD).
4. shape_call clamps at MAX_UTIL_SHAPE (force U near MAX_UMAX).
5. u-cap: open exactly at `uMax·cap` ok; one wei over reverts `"u-cap"` (both sides).
6. keeper lowers uMax below current U ⇒ postMark still succeeds (no revert), surcharge clamped.
7. cap=0 side ⇒ U=0, no surcharge, opens revert.
8. setters: over-cap reverts; non-owner reverts.
9. periods∈{1,2}: surcharge scales with periods; ≥2h stale ⇒ no funding (conservative) unchanged.
10. **conservation invariant still holds** with surcharge on (extend existing fuzz): funding only
    moves value trader→pool, never mints; `poolUsdc == poolFree + putEscrow + totalCollateral`.

## Out of scope (this slice)
Robust oracle (finding #4 — separate slice). Legacy backports (finding #1 settle, #2 SafeERC20 in
`EverlastingMarket`/`CoveredCallMarket`) — separate hardening pass, ideally on PR #1/#2 branches.
