# hyperevmlearning — Everlasting HYPE Options (Hyperliquid testnet)

An on-chain **everlasting options** venue on Hyperliquid's HyperEVM testnet, implementing the
perpetual (funding-based, never-expiring) options design of White & Bankman-Fried
([Paradigm, 2021](https://www.paradigm.xyz/writing/everlasting-options)).

**Slice 2 (code + tests complete):** an everlasting PUT plus a capped everlasting CALL (call spread, payoff bounded at W=K_hi-K), a protocol fee (funding-carry cut), and opt-in yield-adapter float are all implemented and tested (46 Foundry tests + live-fork oracle read). The put hedges long HYPE (spot or perp long) below K; the capped call hedges short HYPE up to K_hi. **Only the Slice-1 single `EverlastingPut` has been deployed and smoked on testnet (`0xD48a…C135`); two-market deploy and smoke for the fee+float configuration are pending.**

## Status
| Task | What | State |
|---|---|---|
| 1 | Foundry config + remappings | ✅ |
| 2 | MockUSDC (6-dp collateral) | ✅ |
| 3 | OracleLib — HYPE oracle read (WAD) + live fork test | ✅ |
| 4–12 | intrinsic · LP pool · open · funding+guards · close · auto-settle · solvency invariant · keeper+deploy · testnet smoke (Slice-1 single `EverlastingPut` only) | ✅ |
| S2-a | capped call · protocol fee · yield-adapter float · cross-market scenario · combined fee+float fuzz invariant | ✅ 46 tests |
| S2-b | live HyperEVM oracle read — call market fork test | ✅ fork test |
| S2-c | two-market testnet deploy + smoke (fee+float config) | fork-verified oracle read (live); two-market deploy + smoke pending |

Built task-by-task with TDD; the implementation plan was hardened by a 45-agent adversarial audit
(16 findings, 4 blockers fixed) before any code was written. See `docs/superpowers/`.

## Architecture (generalized `EverlastingMarket`)
- **Oracle** — `OracleLib.spotWad()` reads HYPE's canonical price via the HyperCore read precompile
  `oraclePx(135)` at `0x…0807` (chain 998), scaled to WAD. Trustless: the same feed HL uses for its
  own funding/liquidation.
- **Market** — `EverlastingMarket(side, K, W)`, peer-to-pool, serves both PUT and CALL. PUT:
  `intrinsic = clamp(K − S, 0, W)` with `W = K`. CALL (capped): `intrinsic = clamp(S − K, 0, W)`
  with `W = K_hi − K`. A keeper posts `mark` hourly under on-chain guards (`mark ≥ intrinsic`,
  `mark ≤ W`, staleness, deviation); funding accrues through a cumulative index; positions are
  fully collateralized in MockUSDC; auto-settle replaces liquidation. Protocol fee
  (`protocolFeeBps`) skims carry; opt-in `IYieldAdapter` sweeps idle free pool to yield.
- **Keeper** — off-chain, posts the geometric-basket mark for each market
  (`Σ 2⁻ⁱ · BS_put(τᵢ)` for the PUT; call-spread basket for the CALL).

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

Per `docs/superpowers/specs/2026-07-02-everlasting-hype-hedging-suite-design.md` §11 (supersedes Slice-1 spec):

| Slice | Adds | Status |
|---|---|---|
| 1 | Everlasting put, isolated pool, funding, auto-settle | shipped · smoked testnet (`0xD48a…C135`) |
| **2** | **Capped call (full directional hedge) · protocol fee · float** | **code + tests done; testnet deploy pending** |
| 3 | Perp delta-hedger (covered model → uncapped calls); shared cross-margin PoolVault | planned |
| 4 | Partial margin + liquidation engine | planned |
| 5 | Insurance fund + ADL | planned |
| — | Multi-strike ladder; frontend; mainnet + external audit | audit-gated |

- **Exploration (feasibility verified for reads)** — everlasting options on **HIP-3 RWA markets** (e.g.
  Trade.xyz equities / commodities / FX / S&P 500) as the underlying + hedge venue. The on-chain oracle
  read path is verified on mainnet; the CoreWriter hedge path is the remaining go/no-go. See
  `docs/research/2026-07-02-hip3-tradexyz-feasibility.md`.

## Safety
`.env` and all secrets are gitignored. Real funds stay on mainnet; testnet uses free faucet gas and our
own `MockUSDC`.
