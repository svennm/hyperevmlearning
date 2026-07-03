# CoveredCallMarket3b — Design: real spot-HYPE cover, folded into the put book

Status: DRAFT for review. Supersedes 3a's abstract cover. Builds on the verified spot-cover spike
(`docs/research/2026-07-03-perp-cover-spike-findings.md`) and the 3a review (PR #2: I1/I2 fixed,
**I3** = cover→USDC on close, still open — this slice closes it).

## Locked decisions (prior turns)
- **Cover = spot HYPE** (own the underlying): no leverage, no liquidation, trustless. Verified live.
- Perp cover rejected: a contract-opened perp is stuck isolated-10× and liquidatable; CoreWriter has
  no leverage/margin action.
- CoreWriter facts to honor: order px/sz = `human*1e8`; sell size floored to `szDecimals` (HYPE 0.01)
  with dust carried; fills are async (land a Core block later); HYPE token 1105, USDC token 0,
  HYPE/USDC spot asset 11035.

## The delta-netting question (the ask) — honest analysis FIRST

**Claim to test:** "fold covered-calls into the put book so delta-netting is possible."

**Sign conventions (pool = peer-to-pool writer; takers are long-only):**
- Put book: pool **writes puts** → short put → **+delta** (long HYPE; the pool loses when HYPE
  falls below K). USDC-collateralized in Slice-1; pool bears the delta unhedged.
- Covered-call book: pool **writes uncapped calls** (−delta) **+ holds spot-HYPE cover** (+1·delta
  per unit). Net **+delta** (cover dominates; pool bears HYPE downside, gives up upside above K).

**Key identity (put–call parity):** a covered call `= long S − short call = PV(K) − P`, i.e. a
**covered call is a SHORT PUT plus a bond.** So the covered-call book and the existing put book are
the **same directional exposure** (both short-put / long-HYPE / short-vol).

**Therefore, folding does NOT net delta — it concentrates it.** Both books make the pool longer HYPE
and shorter vol; their tail risks *compound* on the downside (S→0: put payouts *and* the HYPE cover
collapse both hit). The naive premise ("combine puts + covered-calls → delta cancels") is false.

**What folding actually buys (all real, just not "netting"):**
1. **Capital efficiency** — one USDC pool backs both sides; one shared HYPE cover inventory; one
   keeper, one funding loop, one oracle read.
2. **Unified accounting & risk caps** — a single solvency invariant over the combined book, with
   explicit per-side notional caps (needed *because* risks compound, not because they net).

**Where genuine delta-netting DOES live (optional, future):** if the pool chooses to *delta-hedge
the put book by shorting HYPE* (many LPs do, to shed the downside), then the covered-call's **long**
spot-HYPE cover and the put-hedge's **short** HYPE **net at the inventory level** — the pool
custodies/finances only `call_cover_long − put_hedge_short` HYPE, cutting spread/funding churn. A
unified account is the prerequisite for that. So: **fold now for capital efficiency + to *enable*
inventory-netting later; do not size the cover assuming the put book reduces it.** The mandatory
S→∞ tail cover stays 1:1 on the calls regardless.

> Recommendation: proceed with a **unified market** for capital efficiency and a single solvency
> model, with **hard per-side caps** and the cover sized at the full 1:1 (no netting discount).
> Treat put-book delta-hedging + inventory-netting as a later, opt-in module.

## Architecture

### Option F1 (recommended) — one `EverlastingBook` with PUT + COVERED_CALL sides
Extend the Slice-2 `EverlastingMarket` model to a two-sided book sharing:
- `poolUsdc` (single LP pool, backs put escrow + call cover purchases + payouts),
- `hypeCover` (shared spot-HYPE inventory on the contract's Core account),
- one keeper/funding/oracle loop, one solvency invariant.

Put side keeps Slice-1/2 mechanics (USDC escrow = `qty·W`, fully collateralized). Covered-call side
replaces 3a's abstract `coverQty` with the real spot-HYPE inventory and adds cover buy/sell via
CoreWriter.

### Option F2 — separate `CoveredCallMarket3b`, shared treasury
Standalone contract; shares LP capital with the put market only by convention. Simpler to ship, but
duplicates funding/keeper/solvency and forfeits the shared-inventory prerequisite for netting.

> Recommendation: **F1** if we want the netting option and one solvency model; **F2** if we want to
> ship the covered call fast and defer unification. Leaning F1 — but this is decision **D1** below.

## Q1 — where does pool/trader USDC live?  (decision **D2**)
The cover (HYPE) lives on the contract's **HyperCore** account. The option accounting (mappings,
funding, close math) is **EVM** state. USDC can sit in either place:

- **(a) Core-spot USDC** (co-located with the cover). Buying cover = spot swap USDC→HYPE in one
  account; payout = sell HYPE→USDC, both on Core. The EVM contract drives it via CoreWriter and
  reads balances via precompiles. Cleanest for cover↔payout; but trader deposits/withdrawals must
  bridge EVM→Core (or traders deposit directly on Core, which complicates UX).
- **(b) EVM ERC20 USDC** (like 3a's MockUSDC). Trader/pool balances are plain EVM state; but every
  cover buy needs USDC EVM→Core (`bridgeUsdcToCoreFor`) and every payout needs HYPE-sale-proceeds
  Core→EVM (`bridgeToEvm`) — an async hop on the hot path (the I3 close path).

> Recommendation: **(a) Core-spot USDC** — keeps the cover and its funding/settlement currency in one
> venue, avoids a bridge hop on the payout path. Cost: deposits/withdrawals become Core-side ops. If
> we want familiar EVM-ERC20 UX, (b) is viable but adds bridge latency to `close()`.

## Q3 — async cover reconciliation  (decision **D3**)
`openLong` (writing a call) is cover-gated, but the spot buy fills a Core block later.

- **Pre-funded cover model (recommended):** the keeper maintains a HYPE cover buffer ≥ open call
  notional *ahead* of demand. `openLong` gates on the **on-chain** cover read (`spotBalance`
  precompile), not optimistic local state — you can only sell calls up to already-settled cover. New
  demand → keeper tops up cover → next block those calls become writable. No gap where a call is
  written against unfilled cover.
- On `close()` of a winning call: sell `floor(needed, szDecimals)` HYPE → USDC → credit `poolUsdc`
  (the **I3** fix). Carry sub-`szDecimals` dust in the cover ledger; never assume exact-balance sale.

## Solvency & risk model
- **Tail invariant (calls):** `hypeCover ≥ Σ openCall_qty` (1:1), enforced at write time via the
  on-chain cover read. Guarantees the S→∞ payout is fundable by selling cover.
- **Put invariant (unchanged):** `poolUsdc` escrow ≥ `Σ openPut_qty·W`.
- **Combined conservation:** `usdc_core + hypeCover·spot + escrow == poolUsdc + Σ traderCollateral`
  (the real 3a-I1 conservation check, extended to include the HYPE leg marked to oracle).
- **Per-side notional caps** (params): cap put and call open interest independently — risks compound
  on the downside, so the LP bounds each. `log`/emit when a cap binds.
- **Downside stress note:** at S→0 the pool pays puts *and* eats the cover's value; size caps + LP
  buffer must survive the joint move, not each alone.

## Build plan (→ SDD)
1. `hypeCover` ledger + CoreWriter buy/sell (from the spike), szDecimals flooring + dust carry.
2. Covered-call side: uncapped intrinsic, funding, cover-gated `openLong` (on-chain cover read).
3. `close()`/settle with **cover→USDC-on-close** (I3), mirroring 3a's net-loss predicate (I2).
4. Extended conservation invariant incl. the HYPE leg; per-side caps.
5. (If F1) fold put side into the same contract + shared pool; (if D2=a) Core-spot USDC deposit/withdraw path.
6. Fork tests against live testnet; then a real 2-sided testnet deployment + smoke.

## Open decisions for the user
- **D1:** F1 unified two-sided book, or F2 standalone covered-call market first?
- **D2:** Collateral in Core-spot USDC (a) or EVM ERC20 (b)?
- **D3:** Confirm the pre-funded-cover model (keeper tops up ahead of demand; writes gate on settled cover).
- **Netting expectation:** acknowledge fold = capital efficiency now, inventory-netting only if/when we add put-book delta-hedging (not a cover-size discount).
