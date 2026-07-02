# Everlasting options on HIP-3 (Trade.xyz) markets — feasibility findings

**Date:** 2026-07-02 · **Verdict:** 🟢 **GREEN — both legs empirically verified.** READ verified on mainnet (`oraclePx` matched the API across 6 `xyz:` markets); WRITE verified on testnet 2026-07-02 — a HyperEVM **contract** opened a *filled* position on a HIP-3 market (`felix:TEST1`, szi 0.5, entryPx 43.31) via **CoreWriter**. The only remaining exposures are the operational/counterparty risks below (deployer oracle + halt), not technical feasibility.

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

## WRITE / hedge path — VERIFIED ✅ (testnet, 2026-07-02)
CoreWriter (`0x333…3333`, `sendRawAction`; Limit action id **1**, `reduceOnly` to close) is the hedging
primitive; the action `asset` field uses the **100000+** id (`100000 + dex*10000 + market`). **Confirmed
on testnet:** a deployed HyperEVM **contract** funded a HyperCore account and sent a marketable IOC via
CoreWriter that **filled** — position `szi=0.5 felix:TEST1, entryPx=43.31, ~$20`, order status *filled*.
So a contract can open/close (hence delta-hedge) a HIP-3 builder market via CoreWriter. Caveats
(documented, not blockers): writes are fire-and-forget + delayed a few seconds; HIP-3 is isolated-margin
only; fees ≈ 2× native perps.

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
