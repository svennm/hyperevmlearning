# Full-repo security audit — 2026-07-05

**Scope:** all 13 source contracts in `src/`.
**Method:** three parallel read-only auditors (core `EverlastingBook`; vaults + `OracleLib` + CoreWriter; legacy + `DeltaHedgeManager` + adapters), each applying a security lens **and** a *fully-on-chain* lens (every off-chain trust dependency flagged, tagged inherent vs our-choice). Findings deduped + synthesized here.
**Bottom line:** the mechanism is sound and conservation holds; every gap is **trust-minimization** — the wall between "testnet demo" and "a whale routes size." "Fully on-chain" is a concrete sub-goal of that wall, not a vague aspiration.

## Status summary

| Severity | Count | Resolved | Open |
|---|---|---|---|
| Critical | 1 | 1 | 0 |
| High | 5 | 0 | 5 |
| Medium | ~8 | 1 | ~7 |
| Low/Info | many | 2 | rest |

Resolved this session: **C1** (rug key, `ed134a2`), **M1** (call-winner strand, `bee02f8`), legacy funding-only settle + SafeERC20 (`c3cbfab`).

---

## Findings

### 🔴 Critical

**C1 — Vault rug key.** `RESOLVED (ed134a2)`
`EvmUsdcCoverVault.payoutUsdc(to,amt)` / `bridge*` were `onlyKeeper` (= `owner || keeper`) and `payoutUsdc` sends to an **arbitrary recipient** untied to book accounting → any owner or keeper EOA could drain 100% of pooled USDC (+ churn cover→USDC first). The single biggest contradiction of the fully-on-chain goal.
*Fix:* fund exits (`payoutUsdc`/`pullUsdc`) gated to an immutable-once `book`; `sellCover` book-or-keeper; `buyCover`/`bridge` keeper (in-custody only). No EOA can move pooled USDC out.

### 🟠 High

**H1 — Async payout not supported.** `OPEN`
`EverlastingBook._closeCall` gain branch assumes `vault.sellCover()` credits `poolUsdc` **synchronously** (the mock). The real on-chain `CoreCoverVault`/`EvmUsdcCoverVault` fill is **async** → at `require(poolFree() >= g)` the proceeds haven't landed → close reverts unless a buffer ≥ g pre-exists; retry re-submits the same `sellHype` (double-sell); position is deleted in the same reverting tx (no partial-progress). *The payout path does not support the fully-on-chain vault it targets.*
*Rec:* reserve/confirm the settled fill before paying (settle-then-verify), or an escrowed synchronous seam. `src/EverlastingBook.sol` `_closeCall` (~541-575). — **[on-chain: THE blocker for fully-on-chain covered-call payout.]**

**H2 — Keeper mark not economically bounded.** `OPEN`
`postMark` deviation cap is **±20% per update with no min-interval**, and funding only accrues when `periods = age/3600 > 0` — so a **sub-hour mark ramp compounds `1.2^N` and charges zero funding.** A keeper (or stolen key) ramps the uncapped CALL mark; a colluding long closes for `markGain` before funding offsets → pool drained "within the guards."
*Rec:* cumulative/time-windowed deviation cap + min-interval; accrue funding on sub-period elapsed time; cap CALL mark ≤ spot. `src/EverlastingBook.sol` `postMark` (~446-458). — **[on-chain: the on-chain bound advertised as "bounded" is not economically bounding; the fix is #2 on-chain mark.]**

**H3 — Oracle unguarded + dual-source.** `OPEN`
Settlement uses the **perp** oracle `oraclePx(135)` (OracleLib, ×1e14); cover execution + `coverEquityUsdc` use **spot** `spotPx(1035)` (×1e12) → structural basis a trader can extract. No staleness/TWAP/zero guard on the settlement feed; `SCALE=1e14` hardcodes szDecimals=2 (silent 10ⁿ error if HL changes it).
*Rec:* unify to one feed; add block-staleness/TWAP + sanity-band; read szDecimals. `src/OracleLib.sol:11-15`; `EvmUsdcCoverVault.sol:124-126`. — **[on-chain: oracle liveness/manipulation is inherent to reading HL; the missing guards + source split are ours.]**

**H4 — Slippage guard non-functional; fills unverified.** `OPEN`
`require(estCost <= maxUsdc)` recomputes `estCost` from the *same* `spotPx` used to build the order → can never detect slippage. Real execution is a fire-and-forget IOC bounded only by a hardcoded 50 bps; on a thin/dislocated book it **silently 0-fills** (no revert) and the keeper believes cover was bought.
*Rec:* verify post-fill `coverHype`/USDC deltas before crediting; bounded slippage param; min-notional; `require(rawPx>0)` in both cover paths. `EvmUsdcCoverVault.sol` `buyCover`/`sellCover` (145-183). — **[on-chain: CoreWriter async 0-fill is inherent; treating submission as a guaranteed fill is the bug.]**

**H5 — Legacy contracts are a live liability.** `PARTIALLY RESOLVED`
Open **PRs #1/#2** (`origin/slice2-hedging-suite`, `origin/slice3-covered-call`) and `script/Deploy.s.sol` still carry **pre-fix** code (funding-only settle + raw transfer), and `Deploy.s.sol` deploys the *superseded* `EverlastingMarket` pair, not `EverlastingBook`. Also `CoveredCallMarket` has its own High: the uncapped winner is **unpayable** ("cover" is abstract accounting, never converted to cash). A merge+deploy ships known-buggy contracts. *(The working-tree copies were fixed in `c3cbfab`, but that's on `slice-util-premium`, not on the PR branches.)*
*Rec (#4):* delete legacy `.sol` + `Deploy.s.sol`; `DeployBook` is the sole deploy path; gut PRs #1/#2 to docs/tests only. — **[on-chain: the default deploy path IS the superseded venue.]**

### 🟡 Medium

- **M1 — Owner strand of call-winners.** `RESOLVED (bee02f8)` — `lpWithdraw` call-backing guard (`callNetWritten==0 || coverHype>=callNetWritten`).
- **M2 — Reentrancy (defense-in-depth).** `OPEN` — `_closeCall` calls `vault.sellCover()` before `delete positions` / `netWritten -=`; no `nonReentrant` on close/settle/openLong. Trusted vault mitigates today. → CEI + guard. `EverlastingBook.sol` ~569.
- **M3 — Staleness disables guards.** `OPEN` — `>MAX_MARK_AGE` (2h) skips deviation AND funding; keeper can re-anchor arbitrarily + free carry over the gap. → bounded re-anchor + accrue gap funding. `postMark` ~444-458.
- **M4 — Two-layer `poolUsdc()` transient overcount.** `OPEN` — sums EVM balance + Core float (incl. `hold`, settled-only) → overcounts mid-bridge/in-flight buy → over-pay risk. → exclude `hold`; settled-only accessor / single custody layer. `EvmUsdcCoverVault.sol:117-120`.
- **M5 — DeltaHedge async trim breaks coverGate.** `OPEN` — trim reads settled `H`/`Qc`; between submit and settle `Qc` can rise → transient `coverHype < callNetWritten`. → serialize trims vs opens / reserve in-flight. `DeltaHedgeManager.sol:145-156`.
- **M6 — DeltaHedge doesn't assert vault identity.** `OPEN` — ctor never checks `_vault == book.vault()`; mis-wire defeats the safety rail. → assert in ctor. `DeltaHedgeManager.sol:81-89`.
- **M7 — `bridgeUsdcToEvm` needs Core-HYPE gas.** `OPEN` — non-HYPE bridge-out requires Core HYPE for gas the vault can't fund → proceeds stranded on Core float, EVM withdrawals blocked. → pre-fund + check. `EvmUsdcCoverVault.sol:220-222`.
- **M8 — `payoutUsdc` EVM-only, no solvency check.** `OPEN` — reverts if proceeds sit on Core float and EVM balance short → withdrawal DoS until keeper bridges (diverges from CoreCoverVault). `EvmUsdcCoverVault.sol:205-207`.

### ⚪ Low / Info (selected)

- Legacy funding-only settle + raw transfer — `RESOLVED (c3cbfab)` in working tree.
- Unverified 6-dp USDC assumption (`EvmUsdcCoverVault` mixes `balanceOf` 6dp + Core `/100` w/o reading decimals).
- **No events on any vault op** (buy/sell/bridge/pull/payout) — hurts on-chain auditability directly.
- Unchecked `uint64` truncation on `sz`/`limitPx` (keeper-only; use SafeCast).
- CEI: `deposit` credits ledgers after `vault.pullUsdc`; ledgers use requested not received amount (FoT/rebasing latent).
- `putCapNotional`/`callCapNotional` unbounded at construction (overflow footgun in u-cap / utilization).
- `EverlastingMarket.sweepToYield`/`harvest` permissionless.
- `_toUsdc` truncation favors the trader by sub-1e-6-USDC dust; szDecimals cover dust stranded (by design).
- Funding approximation (single-`f` over `periods`; `_utilSurcharge` uses current U) — bounded (`periods≤2`), documented, accepted.
- **P(U) WAD math independently re-verified correct** (overflow-safe, clamp/div-0 handled; slight upward bias near saturation, sub-tick).

**Confirmed sound by the auditors:** conservation invariant holds; the settle + SafeERC20 fixes are correct; the `DeltaHedgeManager` delta model signs are right.

---

## Fully-on-chain trust census

Right now: **reads on-chain, writes on-chain, but the DECISIONS are off-chain-trusted** — specifically (1) the **mark** (a keeper posts a Black–Scholes basket with a hand-set σ; there is *no on-chain source for a HYPE-option price* because no HYPE options market exists — that's the wedge) and (2) **fund authority** (now closed by C1).

| Trust surface | Inherent to HyperEVM? | Removable (our choice)? |
|---|---|---|
| CoreWriter fire-and-forget fills (submit ≠ fill; silent 0-fill) | ✅ inherent — mitigate only | mitigation (verify fills) is ours |
| HL price precompiles as sole on-chain price | ✅ inherent | source split + staleness/TWAP guards are ours (H3) |
| EVM↔Core async bridge (+ activation, Core-HYPE gas) | ✅ inherent | two-layer custody split is ours (M4/M7) |
| Keeper *process* exists (pokes buy/sell/mark on schedule) | ✅ inherent | its **authority** is ours to bound/remove |
| Keeper's fund authority (payoutUsdc) | ❌ our choice | ✅ **removed (C1)** |
| Trusted keeper-posted **mark** + σ | ❌ our choice | ✅ removable — compute on-chain (**#2**) |
| Slippage config + fill verification | ❌ our choice | ✅ (H4) |

**The flagship move (#2):** read S from the HL oracle (trustless ✓) → compute σ on-chain from HL price history → run the option pricer on-chain → add the P(U) surcharge (already on-chain). The mark becomes a formula anyone can check — no trusted number. The P(U) slice already shipped is the first on-chain piece of the mark.

---

## The map

```
MECHANISM            ██████████ ~90%   two-sided book, P(U), auto-settle, cover-gate,
                                       292 tests + conservation fuzz; PUT lifecycle live
TRUST-MINIMIZATION   ███░░░░░░░ ~25-30%  ◄── HERE.  ✅ C1 rug  ✅ M1 strand
LIQUIDITY            ░░░░░░░░░░  ~0%    single-LP seed; vault/tranche design on paper
DISTRIBUTION         ░░░░░░░░░░  ~0%    (correctly not started)
TRACK RECORD         ░░░░░░░░░░  ~0%
```

---

## Prioritized fully-on-chain sequence

1. **Kill the rug key (C1).** ✅ `ed134a2`
2. **On-chain mark (H2 + H3).** ⬜ Flagship: robust oracle (blended/TWAP + staleness) → on-chain pricer (BS/AmPO closed-form) + P(U) → no keeper judgment. Answers Feinstein's oracle critique + the verifiable-pricing adoption blocker.
3. **Async-safe payout (H1) + fill verification (H4).** ⬜ Make the real async vault actually work.
4. **Quarantine legacy (H5).** ⬜ Delete legacy `.sol` + `Deploy.s.sol`; fix/close PRs #1/#2.
5. **Reserve call-side + timelock (M1).** ✅ folded into #1 as the `lpWithdraw` call-backing guard (`bee02f8`).

Then: reentrancy guards (M2), oracle unification + guards (H3/M3), events, custody/bridge hardening (M4/M7/M8), DeltaHedge hardening (M5/M6).
