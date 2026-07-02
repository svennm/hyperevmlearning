# Everlasting HYPE Options — Slice 1 (Testnet MVP) — Design

**Date:** 2026-07-02
**Status:** Draft for review
**Underlying:** HYPE · **Network:** Hyperliquid testnet (HyperEVM) · **Collateral:** MockUSDC (testnet)

---

## 1. Goal

Ship the smallest honest slice of an **everlasting options venue** on Hyperliquid testnet:
traders take long/short perpetual-option exposure on **HYPE**, priced and funded per White &
Bankman-Fried's *Everlasting Options* (Paradigm, 2021), with a **peer-to-pool** LP vault as
counterparty. Prove the pricing + funding + collateral core end-to-end on testnet before adding
margin, liquidation, hedging automation, or more markets.

## 2. Background — the instrument

An **everlasting option** is a perpetual option: no expiry, no rolling. Its economics are
delivered by a **funding fee** analogous to a perp's, with the index replaced by the option's
intrinsic value:

```
funding_per_period = mark − intrinsic          (longs pay shorts when positive)
intrinsic (call)   = max(S − K, 0)
intrinsic (put)    = max(K − S, 0)
```

Fair value is a geometric basket of same-strike European options across a maturity ladder
`τ_i = i·Δ` (Δ = funding period). For once-per-period (daily-style) funding:

```
P = Σ_{i≥1} 2^(−i) · V_BS(K, τ_i, σ)          weights ½, ¼, ⅛, …  (Σ = 1)
```

Converges in ~10 terms. `V_BS` needs a volatility input `σ`; `S, K, r(≈0)` are trivial. A
0-strike call reduces to `mark − index` — a plain perp — a useful sanity check the paper notes.

## 3. Why Hyperliquid

- **Trustless index.** A HyperEVM contract reads HYPE's canonical oracle price via the HyperCore
  read precompile `oraclePx(uint32 perpIndex)` at `0x00…0807` — the *same* price HL uses for its
  own funding/liquidation. Intrinsic and funding compute on-chain, no third-party feed.
- **Hedgeability.** The pool's residual delta is hedged on HL's own HYPE perp — deepest venue for
  the underlying, same ecosystem. An options venue lives or dies on hedge quality.
- **Funding cadence exists.** HL settles perp funding hourly; we mirror that cadence.
- **No resting book to snipe.** A pool/oracle-marked design sidesteps the "collect funding on a
  stale order book" arbitrage the paper flags as an open exchange problem.

## 4. Scope

**In (Slice 1):**
- One market: HYPE everlasting **put** (single strike near spot at deploy). **Call deferred:** an uncapped call's payoff is unbounded and cannot be fully collateralized without the Slice-2 hedger, so Slice-1 is **put-only**; the call arrives with the hedger (or as a capped spread). [Audit-confirmed 2026-07-02.]
- Peer-to-pool: single LP vault is counterparty to all trades.
- On-chain intrinsic + funding off the HYPE oracle; hourly funding settlement.
- Mark (time value) posted by an off-chain pricing keeper, with on-chain guards.
- **Fully-collateralized** positions in MockUSDC (no partial margin, so no liquidation needed).
- Open / close / deposit / withdraw. Foundry test suite + a funding-accrual integration run.

**Out (later slices):**
- Slice 2 — partial margin + liquidation; automated delta-hedger on HYPE perp; on-chain basket
  pricing from a **posted σ** (removes keeper-posted mark).
- Slice 3 — on-chain σ from EWMA realized vol; multiple strikes/underlyings; front-end;
  governance/params; mainnet hardening + audit.

The full venue is ~6 subsystems (pricing · funding · pool/collateral · margin · liquidation ·
keepers/UI). Slice 1 = **pricing + funding + pool core** only.

## 5. Architecture

**On-chain (HyperEVM, Solidity / Foundry):**

| Contract | Responsibility |
|---|---|
| `OracleAdapter` | Wraps `L1Read` precompile `oraclePx(HYPE_INDEX)`; converts by `10^(6−szDecimals)`; exposes `spot()` + staleness/sanity checks. |
| `OptionMarket` | Instrument state: `(underlying=HYPE, K, isCall)`, per-trader signed position, `intrinsic()`, open/close at mark against the pool. No expiry, **no discrete exercise**. |
| `CollateralVault` | LP deposits/withdraws MockUSDC; is counterparty to all trades; tracks pool equity + trader collateral; enforces full collateralization. |
| `Funding` | Hourly settlement of `mark − intrinsic` between longs and the pool; guards (below). |
| `MockUSDC` | Testnet ERC-20 collateral, 6 decimals, open faucet-mint for testers. |

**Off-chain:**
- **Pricing keeper** — computes `P = Σ 2^(−i) V_BS(K, τ_i, σ)` off HYPE vol, posts `mark` each
  period. (Slice 2: post `σ` instead; contract prices the basket.)
- **Hedger** — *deferred to Slice 2*; pool delta-hedges net exposure on the HYPE perp.

**Data flow (per funding period):**
1. Keeper reads HYPE oracle + vol → computes basket `mark` → `Funding.postMark(mark)`.
2. Contract validates guards, reads on-chain `intrinsic` from `OracleAdapter`.
3. `Funding.settle()` moves `mark − intrinsic` per unit between longs and pool.
4. Trades (open/close) execute against pool at current `mark`; collateral moves in MockUSDC.

## 6. Instrument semantics

- Position = **signed quantity** per trader per market (+long / −short). Closing = opposite trade
  to the pool at current mark. No exercise/assignment logic — funding delivers intrinsic
  continuously; holders realize P&L by closing.
- `mark ≥ intrinsic` is enforced on-chain (time value ≥ 0 at r≈0), so funding is ≥ 0 and flows
  longs → pool; when a trader is net short, the pool (net long) pays them.

## 7. Pricing, funding & guards

- **Intrinsic:** on-chain from `OracleAdapter.spot()`. Trustless.
- **Mark:** keeper-posted for Slice 1 — the one trusted input — bounded by on-chain guards:
  - `mark ≥ intrinsic` (reject otherwise),
  - **staleness halt:** if last mark older than `MAX_MARK_AGE`, pause opens + funding,
  - **deviation cap:** reject a mark that jumps more than `MAX_MARK_DEV%` vs previous.
- **Funding:** hourly (`Δ = 1h`, matches HL), zero-sum between longs and pool.

## 8. Trust & reliability model

| Component | Trust | Basis / mitigation |
|---|---|---|
| HYPE oracle price `S` | **Trustless** | HyperCore precompile `0x…0807` |
| Intrinsic value | **Trustless** | Computed on-chain from `S` |
| Funding settlement | **Trustless** | `mark − intrinsic`, on-chain, zero-sum |
| Collateral custody | **Trustless** | Held by `CollateralVault` |
| **Mark (time value)** | **Trusted (keeper)** | Guards §7; removal path: Slice 2 on-chain pricing from posted σ, Slice 3 on-chain σ |

The reliability-critical quantities are trustless from day one; the trusted surface is a single
guarded scalar with a defined removal path.

## 9. Pool economics & risk

LPs earn the **funding carry** (the rent longs pay for optionality) as yield, bearing the pool's
residual **delta + gamma**. Slice 1 leaves the pool **unhedged** (small, bounded testnet size);
Slice 2 adds the HYPE-perp hedger. Full collateralization bounds worst-case loss and removes the
need for liquidation in this slice.

## 10. Security considerations

- **No real keys, ever.** Deploy/keeper scripts use a **dedicated testnet dev wallet**; its key
  lives in a gitignored `.env` held by the user. Mainnet keys and real funds never enter scripts
  or the repo. (Aligns with repo rule: never commit secrets.)
- **Oracle:** validate `oraclePx` decimals/index; staleness + zero checks in `OracleAdapter`.
- **Keeper:** guards in §7 bound a faulty/malicious mark; keeper cannot touch collateral, only
  post a (guarded) mark.
- **Contracts:** checks-effects-interactions / reentrancy guards on collateral moves; conservation
  invariant `Σ trader_collateral + pool_equity == deposits` asserted in tests.
- **Funding-arb:** oracle-marked pool (no resting book) removes the stale-book snipe the paper
  flags; funding ticks align with mark posts.

## 11. Dev environment

- **Network:** HyperEVM testnet — RPC `https://rpc.hyperliquid-testnet.xyz/evm`.
- **Wallet:** fresh dev EOA; private key in gitignored `.env`, user-held. Never the mainnet wallet.
- **Gas:** testnet HYPE from a direct faucet (Chainstack / QuickNode) — no mainnet deposit needed.
- **Collateral:** our `MockUSDC` (deploy + open mint) — no dependency on the HyperCore drip.
- **Real mainnet USDC:** not used; stays on mainnet.
- Only if/when live HyperCore hedging is tested (Slice 2+) do we consider a *tiny* mainnet deposit
  to the **dev** address to unlock its drip — decided then, not now.

## 12. Testing strategy (Foundry)

- **Unit:** `intrinsic()` (call/put, ITM/OTM), funding accrual, each guard (mark<intrinsic reverts,
  staleness halts, deviation cap), pool accounting, MockUSDC.
- **Fork/integration:** against HyperEVM testnet reading real `oraclePx(HYPE)` — validate decimals.
- **Invariant:** collateral conservation; funding zero-sum.
- **Scenario:** open long → accrue funding N periods → close → assert P&L.

## 13. Milestones (Slice 1)

1. Foundry scaffold · `MockUSDC` · dev-env + faucet doc.
2. `OracleAdapter` + `intrinsic` (fork-tested vs testnet oracle).
3. `CollateralVault` + deposit/withdraw + open/close at mark.
4. `Funding` engine + guards + keeper script (posts mark hourly).
5. Testnet integration + funding-accrual scenario run.

## 14. Parameters to finalize

- Funding period `Δ` (default **1h**).
- Strikes: call + put near HYPE spot at deploy (exact values TBD at deploy).
- `σ` posting method + guard bounds (`MAX_MARK_DEV%`, `MAX_MARK_AGE`).
- HYPE perp index id (fetch from testnet `meta`) + `szDecimals`.

## 15. Open questions

- Funding period: match HL's 1h, or faster for quicker testnet feedback?
- Keeper `σ` source for MVP: trailing realized vol of HYPE, or a hand-set start value?
- Single ATM strike each side, or a small ladder (e.g. ±1 strike) from the start?
