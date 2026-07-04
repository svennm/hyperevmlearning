# Slice-3b Runbook — live EverlastingBook (testnet 998)

## Deployed (2026-07-04)
- **EverlastingBook** `0x807b51bf4FE5A05cAfF5ed8550619b0De0115ad1` (owner=keeper=deployer `0xe7e5`)
- **CoreCoverVault** `0xEf528CeFE14329bf04025259482a397Bc74Ac337` (owner=`0xe7e5`, keeper=book)
- **OracleLib** `0xf2de14501cca77E14b2dcb0C8a2E53380513f416` (HYPE perp oracle idx 135 → WAD)
- Kput=Wput=Kcall=$50 (WAD); putCap=callCap=100e18. Orphaned dup deploys (run1): OracleLib `0x27d6…`, CoreCoverVault `0x4cb5…` (ignore).
- Deploy needs **big blocks** (EverlastingBook ~2.5M gas > small-block limit). Enabled for `0xe7e5` via `evmUserModify{usingBigBlocks:true}` (HL SDK `use_big_blocks(True)`).

## Funding model (D2 = Core-spot USDC)
- **Pool liquidity:** send USDC to the **vault** `0xEf52…` Core account → it becomes `poolFree` automatically (derived = `poolUsdc − totalCollateral − putEscrow`). No `lpDeposit` needed live (it reverts — `pullUsdc` has no Core `transferFrom`).
- **Trader collateral:** BLOCKED live — `book.deposit → vault.pullUsdc` reverts. Needs a Core-native deposit mechanism (open design item; see below). Trader open/close is proven in the 226 Foundry tests, not runnable live yet.

## Live cover-leg smoke (what works today)
1. Fund vault: `0x9608` sends ~$80 USDC (Core spot) → `0xEf52…`.
2. `cast send $VAULT 'buyCover(uint256,uint256)' <hypeWad> <maxUsdc> --private-key $DEPLOYER` (owner=keeper; buys HYPE cover via CoreWriter, `human*1e8`... note vault takes WAD hypeWad + 6dp maxUsdc).
3. Read: `book.poolUsdc()`, `vault.coverHype()`, `vault.coverEquityUsdc()`, `vault.spotPxUsdc()`, `book.intrinsic(1, ...)`.
4. `cast send $VAULT 'sellCover(uint256)' <hypeWad>` → USDC back to poolUsdc.
5. Sweep: `cast send $VAULT 'payoutUsdc(address,uint256)' 0x9608… <amt6dp>`.

## Open design item — Core-native trader deposit
`CoreCoverVault.pullUsdc` reverts (HyperCore has no ERC20 `transferFrom`). Options to enable trader collateral:
- (a) per-trader Core sub-accounts / deposit-and-claim with attribution;
- (b) reconsider EVM-ERC20 USDC collateral (bridge in) — restores `transferFrom`, adds a Core↔EVM hop;
- (c) owner-operated credit (single-LP trust) for controlled contexts.
Decision pending. Until then the book runs pool-liquidity + cover ops live; the full option lifecycle is Foundry-proven.
