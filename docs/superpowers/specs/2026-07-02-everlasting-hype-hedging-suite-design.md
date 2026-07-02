# Everlasting HYPE Options — Slice 2: Hedging Suite + Clearinghouse Economics — Design

**Date:** 2026-07-02
**Status:** Draft for review
**Underlying:** HYPE · **Network:** Hyperliquid testnet (HyperEVM) · **Collateral:** MockUSDC (testnet)
**Builds on:** Slice 1 (`EverlastingPut`, deployed + smoked on testnet)

---

## 1. Goal

Turn the single everlasting **put** into a **full directional hedging suite on HYPE** —
a trader can hedge *either* side of a spot-HYPE or HYPE-perp position — and stand up the
**clearinghouse revenue model** (protocol fee + float) from the first deploy. All on
testnet, reusing Slice-1's solvency-proven machine, with **no new unbounded risk**.

Two deliverables:

1. **The call side.** Slice 1 ships a put, which hedges any *long* (spot HYPE, or a HYPE
   perp long) — buy the put, downside below `K` is covered. The missing half is hedging
   *shorts / upside*, which needs a **call**. We add an everlasting **capped call**
   (a call *spread*) so its payoff stays bounded and fully collateralizable exactly like
   the put — no delta-hedger required.
2. **The clearinghouse economics.** A real clearinghouse earns **fees** (a cut of the
   carry) and **float** (yield on custodied collateral). Both are cheap to add once we
   custody collateral — which we already do — and they are the actual business. We wire
   a `protocolFeeBps` cut of funding carry and an opt-in **yield-adapter seam** for
   float, proving the money model at spread scale on testnet.

This is **phase 1 of an on-chain clearinghouse**: novation (pool is counterparty) +
variation margin (funding) + custody + fee + float — the safe subset that needs no
margin/liquidation engine. The margin/liquidation/hedge/insurance-fund machinery that
turns it into a full clearinghouse is staged explicitly in §11.

## 2. Background — why the call is the hard one, and how the cap fixes it

A short **put** has bounded loss: the underlying floors at 0, so max payout per unit is
the strike `K`. That is why Slice 1 is fully collateralizable with `K` per unit and needs
no liquidation. A short **naked call** has *unbounded* loss (price can run to infinity),
so it cannot be fully collateralized — which is why Slice 1 deferred it.

Traditional exchanges never fully-collateralize a naked call; they run
margin + daily variation margin + liquidation + a mutualized clearinghouse default fund,
and market-makers delta-hedge. On-chain we cannot cheaply mutualize a default fund, so
we take the other well-established route first: a **defined-risk vertical spread.**

A **capped call** (bull call spread as one instrument) caps the payoff at an upper strike
`K_hi`:

```
intrinsic_capped_call(S) = clamp(S − K, 0, W)      where W = K_hi − K   (max payout per unit)
intrinsic_put(S)         = clamp(K − S, 0, W)       where W = K          (max payout per unit)
```

Both are **bounded by `W`**, the max payout per unit. This is the single insight that lets
one machine serve both instruments: everywhere Slice 1 uses the strike `K` as the pool's
per-unit obligation, we substitute `W = max payout per unit`. The solvency proof carries
over verbatim (§4).

**Honest limitation (the cost of choosing the cap):** a capped call only protects up to
`K_hi`. Above `K_hi` the hedger is unprotected again. *Uncapped* upside protection needs
the Slice-3 perp delta-hedger (§11). We surface this to users explicitly — a capped call
is capped protection.

## 3. Scope

**In (Slice 2):**
- **Generalize** `EverlastingPut` → one `EverlastingMarket(side, K, W)` contract. Put is
  `EverlastingMarket(PUT, K, K)`; capped call is `EverlastingMarket(CALL, K, W = K_hi − K)`.
  One code path, one place to fix — deliberately avoiding a second drifting copy.
- Deploy **two markets**: a HYPE put and a HYPE capped call, single strike each side, near
  spot at deploy. **Isolated pool per market** (no shared vault yet — see §5, §11).
- **`protocolFeeBps`** — a protocol cut of funding carry, accrued to `feeAccrued`,
  owner-withdrawable. Default configurable; can start non-zero on testnet.
- **Float seam** — opt-in `IYieldAdapter`; idle *free pool* capital above a reserve can be
  swept to a yield venue; yield harvested to protocol. Testnet ships `NullYieldAdapter`
  (disabled) + `MockYieldAdapter` (simulated APR) to prove the accounting.
- Keeper extended to post marks for both markets (put basket + call-spread basket).
- Foundry suite extended: call-market unit/invariant tests, fee accounting, float
  accounting, cross-market scenario.

**Out (later slices):**
- Uncapped calls, partial margin, liquidation, perp delta-hedger, insurance fund/ADL,
  shared cross-margin pool — Slice 3+ (§11).
- Multi-strike ladder + more underlyings — a config-scale extension available any time
  after Slice 2 (§11); not risk-gated, so not in this slice's critical path.
- Frontend, governance, mainnet, external audit — later.

## 4. Architecture — one bounded market, `W`-generalized

`EverlastingMarket` is `EverlastingPut` with three changes, everything else unchanged:

| Element | Slice 1 (put) | Slice 2 (generalized) |
|---|---|---|
| Instrument | put only | `enum Side { PUT, CALL }` + immutable `K`, immutable `W` (max payout/unit, WAD) |
| `intrinsicWad()` | `clamp(K − S, 0, K)` | `PUT: clamp(K − S, 0, W)` · `CALL: clamp(S − K, 0, W)` |
| Per-unit escrow | `qty·K` | `qty·W` (`_escrowUsdc` keys off `W`) |
| Mark upper guard | `mark ≤ K` | `mark ≤ W` (option value ≤ max payout) |
| Funding | `mark − intrinsic`, cumulative index | **unchanged** |
| Auto-settle / close | escrow-first release, loss floored at collateral | **unchanged** |
| Pool / collateral | single LP, full collateralization | **unchanged** (per-market) |

**Why the solvency proof survives.** Slice 1's audited invariant (comment F2) is
`trader gain g ≤ qty·(mark − entryMark) ≤ qty·K = escrow`. With the generalization,
`mark ≤ W` and `entryMark ≥ 0`, so `g ≤ qty·W = escrow`. Releasing this position's escrow
before paying the trader still guarantees `poolFree ≥ g`. The put is the `W = K` case;
nothing in the proof used "put-ness" beyond `mark ≤ (max payout)`. The audited comments
F1–F5 are preserved through the refactor and each re-verified with `W`.

**Two markets, isolated pools (this slice).** We deploy two independent `EverlastingMarket`
instances. Each has its own pool and LP. Rationale: **risk isolation** — a problem in one
market cannot drain the other — at the cost of capital efficiency and cross-market netting.
A **shared cross-margin `PoolVault`** (the true clearinghouse netting model) is deferred to
Slice 3 because it only pays off *with* a margin engine, and it couples blast radius. Pool
accounting is kept clean enough to extract into a shared vault later.

## 5. Clearinghouse economics — fee + float

### 5.1 Fee — a cut of funding carry

Longs pay the pool time-value each period (`mark − intrinsic`); this is the LP's carry.
The protocol takes `protocolFeeBps` of the **gross funding realized** at close/settle:

```
feeU  = fundingU · protocolFeeBps / 10_000     → feeAccrued   (protocol)
poolFree += (fundingU − feeU)                  → LP keeps the rest
```

`feeAccrued` is a distinct bucket, owner-withdrawable, and is added to the conservation
invariant (§7). The fee is taken from money the trader *already owes* the pool, so it does
**not** weaken any trader-payout guarantee — but the netting path in `_closeFor` must be
re-audited to confirm F2/F3 still hold with the skim (§7, §10). An optional open/close
trade fee (`tradeFeeBps`, default 0) is a trivial add, mentioned but not required.

### 5.2 Float — yield on custodied collateral

The quiet clearinghouse money: idle custodied cash earns interest. We add an opt-in seam:

```solidity
interface IYieldAdapter {
    function deposit(uint256 amt) external;      // vault → venue
    function withdraw(uint256 amt) external;     // venue → vault (must honor on demand)
    function balance() external view returns (uint256);
}
```

- `yieldAdapter == address(0)` ⇒ float disabled; **all USDC stays in-contract** (exact
  Slice-1 behavior — the safe default).
- When set: `sweepToYield()` pushes **only `poolFree` above a `reserveBps` buffer** into the
  adapter; `_ensureLiquidity(amt)` pulls back before any payout/withdraw that exceeds the
  liquid balance; `harvest()` realizes adapter gains to `feeAccrued` (protocol float).
- **Hard invariants (float safety):** float only ever deploys *free pool* capital — it
  **never touches `poolLocked` (escrow) or `traderCollateral`.** Trader margin stays 100%
  liquid. A float loss therefore hits LP/protocol yield only, never trader solvency or an
  escrowed obligation.
- **Testnet:** `MockYieldAdapter` accrues a fixed APR (owner-funded MockUSDC) to exercise
  the accounting; `NullYieldAdapter`/`address(0)` for the default path. A **real** adapter
  is an external trust surface and an explicit **audit-gated** decision — never on testnet.

Deploying *trader margin* into float (where CCPs earn the most) is deliberately **not**
done here — it adds withdrawal-liquidity risk. Noted as a later, risk-weighed decision.

## 6. Data flow (per funding period, per market)

Unchanged from Slice 1, per market, plus the fee skim at realization:

1. Keeper reads HYPE oracle, computes the market's basket `mark`, calls `postMark`.
   - Put mark: `Σ 2^(−i) · BS_put(K, τ_i, σ)`.
   - Capped-call mark: `Σ 2^(−i) · [BS_call(K, τ_i, σ) − BS_call(K_hi, τ_i, σ)]` (a vertical
     spread; bounded by `W`).
2. Contract validates guards (`mark ≥ intrinsic`, `mark ≤ W`, staleness, deviation),
   samples `intrinsic` on-chain, advances `cumFunding`.
3. Trades open/close against the market's pool at current `mark`; collateral moves in USDC.
4. At close/settle, funding realizes; `protocolFeeBps` skims to `feeAccrued`; rest to LP.
5. Off the hot path: `sweepToYield()` / `harvest()` manage float when an adapter is set.

## 7. Invariants (tested)

- **Solvency (per market):** pool can always pay every open position's max gain — proven by
  `g ≤ qty·W = escrow`, escrow released before payout (Slice-1 F2, re-verified for `W`).
- **Conservation (generalized):**
  `Σ traderCollateral + poolFree + poolLocked + feeAccrued == usdc.balanceOf(market) + adapter.balance()`.
  Every unit of USDC is a trader's, free pool, locked escrow, protocol fee, or out at yield.
- **Float safety:** `poolLocked` and `traderCollateral` are never sourced to the adapter;
  `sweepToYield` can move at most `poolFree − reserve`.
- **Funding zero-sum (net of fee):** longs' funding out == pool carry in + `feeAccrued` in.
- **Fee monotonic:** `feeAccrued` only increases except by owner withdrawal.

## 8. Instrument semantics & hedging use

- Position = signed qty per trader per market; close = opposite trade to the pool at mark;
  funding delivers intrinsic continuously; no discrete exercise. (Unchanged.)
- **Hedging recipes (surfaced to users, not contract logic):**
  - *Long spot HYPE or HYPE-perp long, size N* → **buy put** (≈N units at chosen `K`):
    downside below `K` covered.
  - *Short HYPE-perp, size N* → **buy capped call** (≈N units, `K..K_hi`): upside covered
    from `K` to `K_hi`; **unprotected above `K_hi`** (the cap tradeoff).
  - *Two-sided / vol* → hold both (a strangle), composable once both markets exist.

## 9. Testing strategy (Foundry)

- **Unit:** call `intrinsicWad` (OTM→0, ramp, cap at `W` above `K_hi`); `escrow = qty·W`;
  guard `mark ≤ W`; funding/close/auto-settle for the call market mirroring the put suite.
- **Fee:** funding skim math; `feeAccrued` accrual + owner withdrawal; invariant includes
  `feeAccrued`; F2/F3 re-verified with the skim in the netting path.
- **Float:** `MockYieldAdapter` accrual → `harvest` → `feeAccrued`; `_ensureLiquidity`
  pulls back for payouts/withdrawals; conservation includes `adapter.balance()`;
  float-never-touches-locked/trader invariant.
- **Invariant:** extend the Slice-1 solvency handler to the call market (fuzzed
  spot/open/close/settle) and to a fee+float-enabled configuration.
- **Cross-market scenario:** put + call both open, funding accrues, both close; balances +
  fee reconcile.
- **Fork:** the call market reads the same testnet `oraclePx(HYPE)`.

## 10. Security considerations

- Refactor preserves Slice-1 reentrancy / checks-effects-interactions and the F1–F5 audit
  comments; each re-verified with `W`.
- **Fee/float must not weaken solvency:** fee is skimmed only from funding the trader owes;
  float touches only free pool above reserve. The `_closeFor` netting path is re-audited
  with the skim; the conservation invariant test gates it.
- **Yield adapter = external risk:** testnet uses Mock/Null only; a real adapter is
  audit-gated governance, never shipped to testnet or assumed trustworthy.
- Keeper remains the single trusted scalar per market (guards bound a faulty mark);
  unchanged trust model, unchanged removal path (on-chain pricing later).
- No real keys; dedicated testnet dev wallet; secrets gitignored (repo rule).

## 11. Roadmap — this slice as phase 1 of an on-chain clearinghouse

> **Reframe note:** Slice 1's spec listed "Slice 2 = margin + liquidation + delta-hedger."
> We are inserting the **hedging suite + clearinghouse economics** as the new Slice 2 (safe,
> no unbounded risk), and pushing the margin/liquidation/hedger work to Slice 3+. Numbering
> below supersedes the Slice-1 spec to keep the docs from drifting.

| Slice | Adds | Clearinghouse piece | Risk |
|---|---|---|---|
| 1 ✅ | everlasting put, isolated pool, funding, auto-settle | novation + variation margin (funding) + custody | shipped, testnet |
| **2 (this)** | **capped call = full directional hedge; fee + float** | **+ fee + float (the business), still fully collateralized** | **bounded, testnet** |
| 3 | perp **delta-hedge** (covered model) → **uncapped calls**; shared cross-margin `PoolVault` | covered-writer + netting | hedge quality is now load-bearing |
| 4 | **partial margin + liquidation** engine | capital efficiency + forced close | liquidation edge-cases (where perp DEXes die) |
| 5 | **insurance fund + ADL** | on-chain default waterfall (the mutualized fund analog) | tail mutualization |
| — | multi-strike ladder + underlyings (config-scale, any time after 2); frontend; mainnet + **external audit** | product breadth / go-live | audit gates real money |

**Guiding principle:** *A is the product, C is the business.* Ship the fully-collateralized
hedging suite now with fee+float on — so the venue looks like a clearinghouse (custody + fee
+ float) from the first testnet deploy — then add the risk machinery one primitive at a time,
each leaning on Hyperliquid's own perp + backstop primitives, audit-gating the real-money
version. The clearinghouse earns float *because* it runs the risk machine correctly; we build
that machine slowly enough to get it right.

## 12. Parameters to finalize (at design-approval / deploy)

- `K_hi` for the capped call (sets `W = K_hi − K`) — protection width vs. capital per unit.
- `protocolFeeBps` starting value (funding-carry cut); `tradeFeeBps` (default 0).
- `reserveBps` liquid buffer for float; testnet `MockYieldAdapter` APR.
- Strikes `K` (put) and `K, K_hi` (call) near HYPE spot at deploy.
- Reuse Slice-1 `FUNDING_PERIOD=1h`, `MAX_MARK_AGE`, `MAX_MARK_DEV_BPS` unless revisited.

## 13. Open questions

- Fee routing: funding-carry cut only (recommended), or add a small open/close trade fee?
- Float yield split: 100% protocol (default clearinghouse-float model), or share with LP?
- Isolated pools now (recommended) vs. jump to shared cross-margin vault early (couples
  blast radius before margin exists — not recommended).

## 14. Implementation notes (for the plan / fan-out)

- **Generalize, do not fork.** Refactor `EverlastingPut` into `EverlastingMarket`; re-deploy
  the put as the `W = K` case. One machine, one place to fix (the drift lesson).
- TDD per Slice-1 discipline: tests first, keep each app-suite green.
- **Codegen offload:** use `scripts/qwen.sh` (qwen3-coder via Ollama) for mechanical
  generation — intrinsic clamp variants, adapter interfaces/mocks, boilerplate test
  scaffolds — with Claude briefing + reviewing; keeps token cost low on the routine parts.
