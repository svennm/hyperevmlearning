# Everlasting options on HIP-3 (Trade.xyz) markets — feasibility findings

**Date:** 2026-07-02 · **Verdict:** READ path **GREEN (empirically verified on mainnet)**; WRITE/hedge path is the remaining go/no-go.

Assessing building everlasting (perpetual, funding-based) options on HyperEVM that use Trade.xyz's
HIP-3 real-world-asset perps as the underlying reference + delta-hedge venue.

## What Trade.xyz is (verified)
Dominant HIP-3 RWA perp DEX on Hyperliquid **mainnet**. DEX name `xyz` (**perp_dex_index = 1**),
deployer `0x88806a71d74ad0a510b350545c9ae490912f0888`, ~98 markets: equities (TSLA/NVDA/AAPL/… ~60),
indices (SP500, XYZ100/Nasdaq, JP225, KR200), commodities (GOLD, WTI, BRENT, NATGAS, metals), FX
(EUR/JPY/GBP) — **not crypto**. Trading is **permissionless** (the ~500k HYPE stake gates *deploying*,
not trading; the only gate is a front-end legal geoblock, not on-chain). S&P-500-licensed (Mar 2026);
peak OI ~$3.2B; >90% of all HIP-3.
*Correction:* the a16z / ~$2B / $135M-Canton figures that surface in search belong to **Digital Asset /
Canton Network — a different company** — not Trade.xyz. Treat any Trade.xyz valuation as unverified.

## READ path — VERIFIED ✅ (on-chain `staticcall`, mainnet HyperEVM)
A HyperEVM contract reads any `xyz:` market's oracle via the `0x…0807` (`oraclePx`) / `0x…0806`
(`markPx`) precompiles.

**Critical encoding — empirically discovered, NOT stated in docs:**
- **Read-precompile index = `perp_dex_index * 10000 + index_in_meta`** (xyz:GOLD → `1*10000+3 = 10003`).
- The **documented action/API asset id = `100000 + perp_dex_index*10000 + index_in_meta`** (110003).
  Passing that to the read precompile **reverts** with `PrecompileError` ("invalid asset").
- ⇒ **reads and CoreWriter actions use DIFFERENT ids for the same market.** Missing this reverts everything.

Verified (precompile vs live info-API oracle, 2026-07-02):

| market | read id | precompile `oraclePx` | info-API oracle |
|---|---|---|---|
| xyz:GOLD | 10003 | $4116.6 | $4116.2 |
| xyz:NVDA | 10002 | $192.85 | $192.77 |
| xyz:TSLA | 10001 | $393.69 | $393.66 |
| xyz:AAPL | 10009 | $307.45 | $307.47 |
| xyz:SP500 | 10052 | $7443.7 | $7442.1 |
| xyz:ORCL | 10011 | $139.60 | $139.62 |

Native controls (`oraclePx(0)=BTC`, `(1)=ETH`, `(3)=MATIC`) return sane prices, confirming the precompile
is live; only the mis-encoded HIP-3 ids revert. → **the option pricer + funding engine can consume the
HIP-3 oracle on-chain, trustlessly** (modulo the deployer-run oracle, below).

## WRITE / hedge path — NOT yet verified ⏳ (the remaining go/no-go)
CoreWriter (`0x333…3333`, `sendRawAction`; Limit action id **1**, `reduceOnly` to close) is the hedging
primitive. The action `asset` field uses the **100000+** id (110003 for GOLD). Placing an order is a
state change requiring a funded HyperCore account → **cannot be confirmed read-only.** Test: one small
IOC on `xyz:GOLD` via CoreWriter, then read the position back via the `0x…0800` precompile on a later block.

## Risks to design around
- **Deployer-run centralized oracle** (Trade.xyz "Relayer", ~3s cadence, **clamped ≤1% per update** →
  on-chain price lags fast moves — directly hits option pricing + hedge accuracy).
- **Halt / kill switch:** deployer can `haltTrading` (**force-settles all positions to mark**) or
  `disableDex`. For an *everlasting* (open-ended) option, a mid-life halt/outage can strand or mis-settle
  live positions → needs a settlement fallback (secondary oracle / TWAP / auto-unwind).
- **Fees ~2× native perps; isolated-margin only; CoreWriter writes are fire-and-forget + delayed a few
  seconds.** All hit hedge slippage / capital efficiency / rebalance latency.
- **>90% single-builder concentration** (systemic risk flagged for Hyperliquid itself).

## Precedent
**Hypercall** (Synapse Labs) runs options on **SPCX (SpaceX)** — a HIP-3-only underlying → de-facto
options on another builder's HIP-3 market. Otherwise this pattern is greenfield.

## Next steps
1. **Write/hedge test** (funded account): CoreWriter IOC on `xyz:GOLD` (action id 110003) + position
   read-back. Converts the write path to verified. ← decisive remaining check.
2. If green → spec the contract architecture: option logic + funding on HyperEVM reading `dex*10000+idx`;
   delta-hedge via CoreWriter `100000+dex*10000+idx`.
3. Strategic: accept dependence on Trade.xyz's oracle + halt control, or eventually deploy our own HIP-3
   market for the underlyings we care most about (removes counterparty risk; costs the 500k HYPE stake).

**Sources:** HL docs (HyperEVM↔HyperCore precompiles, Asset IDs, HIP-3 spec, deployer actions), Trade.xyz
docs, S&P 500 license announcement, live mainnet info API + on-chain `staticcall` (the read table above).
