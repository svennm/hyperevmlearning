# Everlasting HYPE Covered Call (Slice 3) — Design

**Date:** 2026-07-02
**Status:** Draft for review
**Underlying:** HYPE · **Network:** Hyperliquid testnet (HyperEVM + HyperCore) · **Collateral:** **real testnet USDC** (see §7 — *not* MockUSDC)
**Builds on:** Slice 1 (put) + Slice 2 (capped call + fee + float), branch `slice3-covered-call` off `slice2-hedging-suite`.

---

## 1. Goal

Ship an **uncapped everlasting HYPE call** whose writer (the pool) is fully collateralized by a **long HYPE perp cover** — not cash escrow. Buyers get **uncapped upside**; because the pool holds the underlying, a short uncapped call is fully covered and needs **no liquidation engine**. This is the "real product": the option a HYPE short (or anyone) buys to hedge unbounded upside, which the capped call could only bound.

## 2. Background — the covered call

Pool = **long HYPE (via perp) + short call**. Cash-settled. Per unit, entering the cover at price `S0`:

```
pool payoff at spot S = funding_collected + (S − S0)[perp]  − max(S − K, 0)[owed to buyer]
  S ≥ K :  funding + (S − S0) − (S − K) = funding + (K − S0)   → bounded; if S0 ≈ K, pool keeps funding, flat above K
  S < K :  funding + (S − S0)                                  → pool bears HYPE downside (its long perp), floored at S→0
```

So the pool is **never short / never insolvent on the upside** (the unbounded `S−K` owed is offset by the perp's `S−S0` gain when `S0 ≤ K` and the cover is 1:1). Its residual risk is **bounded long-HYPE downside** (LP capital, never a debt). Buyer receives the full `max(S−K,0)` — uncapped. This is the classic covered-call writer position: *sell your upside above K for the funding carry, keep full downside exposure to the underlying.*

## 3. Why a perp cover (not cash, not spot)

- **Cash** can't collateralize an unbounded payoff (that's exactly why Slice-2's call had to be *capped*).
- **Spot HYPE** would need a HyperEVM DEX to acquire/dispose + convert HYPE→USDC to settle — an execution + liquidity dependency we don't control on testnet.
- **HL perp (1× long)** is USDC-denominated, cash-settles clean, uses HL's deepest venue, and reuses the **CoreWriter write-path already verified on testnet** (a HyperEVM contract opened a filled position via CoreWriter, 2026-07-02). Chosen.

## 4. Scope

**In (Slice 3):**
- New `CoveredCallMarket` contract — uncapped everlasting call, per-unit obligation `max(S−K,0)`.
- **Perp-cover collateralization**: pool holds an aggregate long HYPE perp ≥ net written call notional, established/maintained via CoreWriter.
- **Real testnet USDC** collateral (§7). Cash-settled. Funding = `mark − intrinsic`. Protocol-fee cut (reuse Slice-2 pattern).
- Cover-solvency invariant enforced on-chain: a call can only be opened if verified cover capacity exists.

**Out (later):**
- **Multi-LP vault shares** (ERC-4626-style) — the capacity/GTM upgrade — is the *immediate next* slice (§14), not this one.
- Shared cross-margin pool netting put ↔ covered-call (the delta-netting prize) — later.
- **Naked / uncollateralizable-by-HYPE** options (margin + liquidation + insurance fund) — Slice 4.
- On-chain σ / fully on-chain pricing — later.

## 5. Architecture

**New contract `CoveredCallMarket`** (separate from `EverlastingMarket` — collateral is a cover *position*, not cash escrow; own pool this slice for risk isolation).

| Piece | Responsibility |
|---|---|
| Option accounting | per-trader signed long-call position; `intrinsic = max(S−K,0)` on-chain from the HYPE oracle; open/close/funding/cash-settle in real testnet USDC. |
| Cover ledger | tracks `netWrittenNotional` and the **verified** aggregate perp cover; gates opens on `coverAvailable ≥ requested`. |
| CoreWriter adapter | opens / rebalances / reduces the pool's long HYPE perp on HyperCore via CoreWriter (action id, `dex_index` encoding per the verified gotcha). |
| Cover verifier | **reads back the actual HyperCore perp position** via the read precompile — never assumes a CoreWriter request filled (fire-and-forget + delayed). |
| Keeper | posts `mark` hourly (as Slices 1–2) **and** maintains the perp cover ≥ net written notional + buffer. Two keeper duties now. |

## 6. Cover mechanism & the async gap

CoreWriter is **fire-and-forget + delayed** — a submitted perp order fills a block or two later; the contract cannot synchronously know the result. Design around it:

- **Pre-established buffer, not per-trade opens.** The keeper maintains the aggregate perp long at `netWrittenNotional + buffer`. A buyer's `openLong` is gated on **already-verified** cover capacity, so the (instant, on-chain) call write never depends on a (delayed) perp fill.
- **Verify, don't assume.** Cover capacity = the perp position *read back* from HyperCore (read precompile), not the sum of CoreWriter requests submitted. A submitted-but-unfilled order does not count as cover.
- **Liquidation-proof cover.** The cover perp is posted **isolated, 1× (full-notional margin)**, so it can only be liquidated near `S→0` — which is the pool's floor anyway. No cover-side liquidation risk in the operating range.

## 7. Collateral unit — the key decision (confirm at review)

The perp cover is a **real HL testnet perp** settling in **real testnet USDC** on HyperCore. For the cover's PnL and the option's payoff to net in one unit of account, **the covered-call market must use real testnet USDC**, not the `MockUSDC` of Slices 1–2.

*(Phasing: §13's **3a** proves the option accounting in pure Foundry with `MockUSDC` + a mock cover — no HyperCore. The real-USDC requirement binds the **live market in 3b**, where the cover is a real perp. So this decision gates 3b, not the 3a correctness proof.)*

**Consequences:**
- Pool posts ~**1× the written call notional** as real testnet USDC margin (the covered-call capital cost — uncapped protection is capital-heavy).
- Uses the user's **funded HyperCore acct** (`0x9608…9A5b`, ~$999 testnet perp margin) and/or the throwaway dev wallet's HyperCore balance; real-USDC wiring on HyperCore to be confirmed.
- Real funds still never enter the repo; testnet only.

*This is a real departure from Slices 1–2 and the single biggest "is this the right call?" item — flagged for explicit sign-off.*

## 8. Solvency argument (and the critical invariant)

Pool is never short on the upside: `owed max(S−K,0) ≤ perp gain (S−S0)` when `S0 ≤ K` and cover is maintained 1:1. Residual risk = bounded long-HYPE downside (LP capital). **No liquidation engine needed — IF two invariants hold:**

1. **Cover invariant:** verified aggregate perp long ≥ net written call notional, at all times a call is open. Enforced on-chain at `openLong` (gate) + monitored by the keeper.
2. **Cover margin health:** the cover perp stays fully-margined (1× isolated) so it is not itself liquidated in-range.

The trust/operational surface therefore shifts from "keeper posts a fair mark" (Slices 1–2) to **also** "keeper keeps the cover established and margined." That is the defining new risk of this slice and must be stated loudly to users.

## 9. Pricing & funding

- **Uncapped call mark** = geometric BS-call basket `Σ 2^(−i)·BS_call(K, τ_i, σ)`, keeper-posted (same trust model + guards: `mark ≥ intrinsic`, staleness halt, deviation cap). **No upper `W` bound** — the call is uncapped (Slice-2's `mark ≤ W` guard does not apply).
- **Funding** = `mark − intrinsic`, hourly, cumulative-index (reuse Slice-1/2 machinery). Longs pay the pool.
- **Protocol fee** = funding-carry cut (reuse Slice-2, solvency-safe skim).

## 10. Settlement

Cash-settled in testnet USDC. On buyer close ITM, the pool pays `max(S−K,0)` per unit, **sourced from reducing the perp cover** (realizing its `S−S0` gain to USDC via CoreWriter) plus pool USDC; the keeper reconciles `netWrittenNotional` and the cover position after the close. Funding realizes as in Slices 1–2.

## 11. Risk model

Pool = **long HYPE + short calls = a covered-call yield strategy.** Earns the funding carry; bears HYPE downside (bounded). Operational risks + mitigations:
- **CoreWriter fill fails/delays** → verify-don't-assume (§6); buffer absorbs latency; opens gated on verified cover.
- **Cover perp margin** → full-notional 1× isolated (liquidation-proof in-range, §6).
- **Keeper liveness** (mark *and* cover) → staleness halts opens; cover shortfall halts new writes; existing positions cash-settle at oracle.
- **Oracle** → HL's own precompile (trustless), as Slices 1–2.

## 12. Testing strategy

- **Unit (Foundry, pure):** option accounting, `intrinsic = max(S−K,0)`, funding, cash-settle, and the **solvency-given-cover** invariant using a *mock cover* (a stand-in that models "pool holds N notional of long-HYPE exposure"). This proves the option economics without needing HyperCore.
- **Fork / integration (testnet):** the CoreWriter adapter + cover verifier against real HyperCore — open a cover, read it back, reduce it. **Honest:** this part validates only on testnet (fire-and-forget writes, delayed fills, real precompiles); it cannot be fully unit-tested. `PrecompileSimulator.init()` for reads.
- **Invariant:** pool stays solvent as long as the cover invariant holds (fuzz spot, opens/closes, with the mock cover enforced).

## 13. Build decomposition (for the plan)

To de-risk the novel part, the implementation plan will sequence:
- **3a — option market + cover invariant** (cover *abstracted/mocked*): the uncapped call, funding, cash-settle, protocol fee, and the on-chain cover-gate + solvency-given-cover, all provable in pure Foundry. No CoreWriter yet.
- **3b — CoreWriter cover automation**: the contract opens / reads-back / reduces the real HL perp; testnet integration + fork tests.

3a is where correctness lives; 3b is where the operational risk lives. Ship 3a green before 3b.

## 14. Roadmap position

Slice 3 (this) → **multi-LP vault shares** (ERC-4626; the "HYPE covered-call yield vault" that gives capacity — see `project_hl_options_adoption`) → **shared cross-margin** put↔covered-call (delta-netting: put-writing = short-HYPE, covered-call-writing = long-HYPE, they offset) → **Slice 4 naked/margin** (uncollateralizable-by-HYPE; real margin + liquidation + insurance fund).

## 15. Open questions / parameters

- **Confirm the real-USDC decision** (§7) vs. keeping MockUSDC + a mock cover for the whole slice (would defer real HyperCore integration to 3b/later).
- Which HyperCore **read precompile** exposes the contract's own perp position/margin (to verify cover) — identify + fork-test.
- Cover **buffer** size + rebalance cadence.
- Real testnet USDC wiring on HyperCore (funded acct vs dev wallet; how the contract holds/pledges margin).
- `σ` source (hand-set start → trailing realized vol).
- Cover entry: pool enters cover at current `S0` when written — confirm `S0 ≤ K` handling (if `S0 > K`, cover still bounds via `funding + (K − S0)`, pool takes a known haircut; acceptable).

## 16. Honest limitations (this slice)

Testnet; **single-LP seed** (multi-LP vault is next); **two trusted keeper roles** (mark + cover liveness); **real-USDC capital-heavy** (~1× notional); **not audited**; pool bears HYPE downside by design. Uncapped protection is real, but it rides on the cover being maintained — that assumption is the product's core caveat.
