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

---

## REDEPLOY + LIVE DEMO (2026-07-04, session 3) — deposit fix proven end-to-end

Chose option (b): **`EvmUsdcCoverVault`** (USDC = EVM ERC20 → `pullUsdc` is a real `transferFrom`; HYPE cover stays Core-native). `script/DeployBook.s.sol` now deploys it with `HLConstants.usdc()` (testnet EVM USDC `0x2B3370eE501B4a559b57D449569354196457D8Ab`, 6dp).

### Deployed (supersedes the Core-spot stack above)
- **EverlastingBook** `0x95F9E38F535B94946aDb1CD6370107eBfE20fae8` (owner=keeper=`0xe7e5`)
- **EvmUsdcCoverVault** `0x122f05eD66A0bBd4fF96031107Fdf33efC3BE5f6` (owner=`0xe7e5`, keeper=book)
- **OracleLib** `0x288AcEE3b2a5e6dD7f672664B42ffCd15ac65122`
- Kput=Wput=Kcall=$50 (WAD), putCap=callCap=100e18. Deployed with big blocks; verified vault.keeper==book, book.vault==vault, poolUsdc==0 fresh.

### Sourcing EVM USDC (testnet USDC is a Circle FiatToken — mint is minter-gated, no faucet)
Recycle the old $100 (Core) → EVM via the HL SDK. **Core→EVM bridge (verified live, ~seconds):**
```
ex.send_asset("0x2000000000000000000000000000000000000000", "spot", "spot", "USDC", <amount>)
# dest = BASE_SYSTEM_ADDRESS + tokenIndex(0); from an ACTIVATED Core account
```
1. `old_vault.payoutUsdc(0xe7e5, 100e6)` — sweep old vault Core USDC → `0xe7e5` (works only because `0xe7e5` is an activated Core acct). tx `0x839cf206…`
2. `send_asset(... "USDC", 100)` → `0xe7e5` EVM USDC ≈ $100.5.

### Live lifecycle — deposit → open → close → withdraw (PUT side, pure USDC)
The PUT side is USDC-escrow (no HYPE cover), so it exercises the full deposit fix without the cover leg:
1. **LP:** `usdc.approve(vault, 75e6)` + `book.lpDeposit(75e6)` → `transferFrom` pulls $75 into the pool. **This is the fix — the exact `pullUsdc` path `CoreCoverVault` reverted on.**
2. **Deposit (trader):** `usdc.approve(vault, 10e6)` + `book.deposit(0, 10e6)` → `traderCollateral[PUT]=$10`. tx `0xf6592838…`
3. **Open:** `book.postMark(0, 3e18)` (keeper) + `book.openLong(0, 1e17)` → IM=qty·Wput=$5 escrow locked. tx `0x18596225…`
4. **Winning + close:** `book.postMark(0, 35e17)` (+16.7%, within 20% dev) + `book.close(0)` → escrow released, g=$0.05 credited (collateral $10 → $10.05). tx `0xed9abdfc…`
5. **Withdraw:** `book.withdraw(0, 10050000)` → physical ERC20 payout; trader net **+$0.05 realized end-to-end.** tx `0xaac4ed5a…`
Conservation `poolUsdc == poolFree + putEscrow + totalCollateral` asserted at every step (final: poolUsdc $59.95 = poolFree $59.95 + 0 + 0).

### GOTCHA — EVM→Core deposit to a fresh CONTRACT Core account is stuck/very-slow
`vault.bridgeUsdcToCore(15e6)` (the `CoreDepositWallet.deposit` path, to seed the vault's Core USDC for `buyCover`) debited EVM instantly but **never credited the vault's Core account after >10 min** (`coreUserExists`=false). So the **covered-call cover leg couldn't be seeded live** and that demo is deferred. NOT a contract bug — spot-cover mechanics are already proven by the SpotCoverSpike. A `spotSend` to a non-existent Core account silently no-ops (HyperCore drops it); only the (slow) `CoreDepositWallet` deposit activates a fresh account. Open item: reliably activate + fund a *contract's* Core account on testnet.

### Funds (all `0xe7e5`-controlled, nothing lost — total $100.5)
vault EVM $59.95 (pool; `lpWithdraw` to recover) · `0xe7e5` EVM $25.55 · $15 in `CoreDepositWallet` limbo for the vault (recoverable once it credits). Return to `0x9608` needs EVM→Core bridge + spotSend (deferred). Ops helper: `scratchpad/hl_ops.py` (bigblocks / balances / bridge_c2e).
