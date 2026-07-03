# Slice-1 Runbook — Everlasting HYPE Put (HyperEVM testnet)

**Deployed 2026-07-02, HyperEVM testnet (chain 998).** Throwaway dev wallet only.

## Deployed addresses
| Contract | Address |
|---|---|
| MockUSDC | `0xBD6ce3B6Ea311EB4985e538510237dB0Dc88Faf7` |
| OracleLib | `0xb0be0f430D84Bd8bF10B083179f9022f1947A38A` |
| EverlastingPut | `0xD48aabBd8ad161A68F471045E4c12D67c879C135` (tx `0x857ad40…e951ba6`) |

- **K (strike):** `47e18` ($47, whole-dollar ATM at deploy; HYPE oracle ~$48.0)
- **keeper / lp / deployer:** `0xe7e5b1bfa0B00C30B78599F0a0D137F43d537278`
- **RPC:** `https://rpc.hyperliquid-testnet.xyz/evm`

## Deploying
> **Status:** The two-market deploy script below is ready but **has not yet been executed on testnet**. Only the Slice-1 single `EverlastingPut` (`0xD48a…C135`, see table above) has been deployed and smoked. The commands here document the intended Slice-2 procedure for when the deploy is run.

> ⚠️ `script/Deploy.s.sol` computes `K` and `K_HI` from env vars (not by calling `oracle.spotWad()` in-script). `forge script` runs a local simulation first, and the HyperCore precompile `0x…0807` has no bytecode in that sim → `call to non-contract address` revert. Pass `K` and `K_HI` via `STRIKE_K` and `STRIKE_K_HI` (computed off-chain).

**Environment variables** (required in `.env` or exported):
- `DEPLOYER_PRIVATE_KEY` — deployer account key
- `KEEPER_PRIVATE_KEY` — keeper account key (oracle heartbeat driver)
- `STRIKE_K` — put strike, wad (whole-dollar ATM, e.g., `47e18` for $47)
- `STRIKE_K_HI` — call upper strike, wad (e.g., `50e18` for $50); capped call width is `K_HI - K`
- `PROTOCOL_FEE_BPS` — protocol fee in basis points (e.g., `500` = 5%)

The script deploys **two markets**:
1. **PUT**: `Side.PUT`, width = `K` (ATM)
2. **CALL**: `Side.CALL`, width = `K_HI - K` (capped)

Both markets have the same protocol fee set via `setProtocolFeeBps()`.

Reproducible deploy:
```bash
set -a; source .env; set +a
forge script script/Deploy.s.sol --rpc-url "$HYPEREVM_TESTNET_RPC" --broadcast
```

The script logs:
- MockUSDC, OracleLib addresses
- PUT and CALL market addresses
- K (wad), K_HI (wad), protocol fee (bps)

## Smoke — Slice-1 `EverlastingPut` only (verified 2026-07-02)
All `cast send ... --private-key $DEPLOYER_PRIVATE_KEY --rpc-url $RPC`, `M`=market, `U`=MockUSDC, `A`=deployer:
```bash
cast send $U 'mint(address,uint256)' $A 1000000000000      # 1M mUSDC
cast send $U 'approve(address,uint256)' $M 1000000000000
cast send $M 'lpDeposit(uint256)' 500000000000            # LP 500k
cast send $M 'deposit(uint256)' 47000000                  # trader margin $47
cast send $M 'postMark(uint256)' 5000000000000000000      # mark $5 (keeper-only)
cast send $M 'openLong(uint256)' 1000000000000000000      # 1 put
cast send $M 'close()'
```
Observed: after open → `positions=(1e18, 5e18, 0)`, `poolLocked=47e6`, `poolFree=499953e6`, `intrinsicWad=0` (live oracle read); after close → position cleared, `traderCollateral=47e6`, `poolLocked=0`. ✅

## Keeper
See `keeper/README.md`. Set `MARKET_ADDRESS=0xD48a…C135`, `SIGMA`, then `npm i && npm run post` (schedule hourly).

## Safety
`.env` (keys) is gitignored — throwaway testnet wallet only, never a real-funds key. This is a testnet deployment; not audited for mainnet.
