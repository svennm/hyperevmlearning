# hyperevmlearning — Everlasting HYPE Options (Hyperliquid testnet)

An on-chain **everlasting options** venue on Hyperliquid's HyperEVM testnet, implementing the
perpetual (funding-based, never-expiring) options design of White & Bankman-Fried
([Paradigm, 2021](https://www.paradigm.xyz/writing/everlasting-options)).

**Slice 2 (complete):** an everlasting PUT plus a capped everlasting CALL (call spread, payoff bounded at W=K_hi-K), a protocol fee (funding-carry cut), and opt-in yield-adapter float are all shipped and tested. The put hedges long HYPE (spot or perp long) below K; the capped call hedges short HYPE up to K_hi.

## Status
| Task | What | State |
|---|---|---|
| 1 | Foundry config + remappings | ✅ |
| 2 | MockUSDC (6-dp collateral) | ✅ |
| 3 | OracleLib — HYPE oracle read (WAD) + live fork test | ✅ |
| 4–12 | intrinsic · LP pool · open · funding+guards · close · auto-settle · solvency invariant · keeper+deploy · testnet smoke | ✅ |

Built task-by-task with TDD; the implementation plan was hardened by a 45-agent adversarial audit
(16 findings, 4 blockers fixed) before any code was written. See `docs/superpowers/`.

## Architecture (Slice 1)
- **Oracle** — `OracleLib.spotWad()` reads HYPE's canonical price via the HyperCore read precompile
  `oraclePx(135)` at `0x…0807` (chain 998), scaled to WAD. Trustless: the same feed HL uses for its
  own funding/liquidation.
- **Market** — `EverlastingPut`, peer-to-pool. `intrinsic = max(K − S, 0)`; a keeper posts the `mark`
  hourly under on-chain guards (`mark ≥ intrinsic`, `mark ≤ K`, staleness, deviation); funding accrues
  through a cumulative index; positions are fully collateralized in MockUSDC; auto-settle replaces
  liquidation.
- **Keeper** — off-chain, posts the geometric-basket mark `Σ 2⁻ⁱ · BS_put(τᵢ)`.

## Layout
```
src/            contracts — OracleLib, MockUSDC, MockOracle, interfaces/ (EverlastingPut in later tasks)
test/           Foundry tests — unit, live fork, invariant
script/         deploy scripts (later task)
keeper/         off-chain mark-posting keeper (later task)
docs/superpowers/specs   design spec
docs/superpowers/plans   audited implementation plan
docs/research            HIP-3 / Trade.xyz feasibility (verified findings)
lib/            forge-std, hyper-evm-lib (HyperCore precompiles)
```

## Build & test
```bash
curl -L https://foundry.paradigm.xyz | bash && foundryup   # once
forge build
forge test                                                 # unit + invariant (local)

# live fork test (reads the testnet oracle) — needs the RPC env + network:
set -a; source .env; set +a
forge test --match-contract OracleLibForkTest -vv
```

## Deploy (testnet)
Config lives in `.env` (gitignored — **dedicated testnet throwaway key only, never a real-funds key**).
Network: HyperEVM testnet, RPC `https://rpc.hyperliquid-testnet.xyz/evm`, chain `998`. See the plan's
Task 11–12.

## Roadmap
- **Slice 2** — delta-hedger (pool hedges on the HYPE perp), partial margin + liquidation, on-chain pricing.
- **Exploration (feasibility verified for reads)** — everlasting options on **HIP-3 RWA markets** (e.g.
  Trade.xyz equities / commodities / FX / S&P 500) as the underlying + hedge venue. The on-chain oracle
  read path is verified on mainnet; the CoreWriter hedge path is the remaining go/no-go. See
  `docs/research/2026-07-02-hip3-tradexyz-feasibility.md`.

## Safety
`.env` and all secrets are gitignored. Real funds stay on mainnet; testnet uses free faucet gas and our
own `MockUSDC`.
