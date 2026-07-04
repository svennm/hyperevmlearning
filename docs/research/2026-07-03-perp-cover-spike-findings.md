# Slice-3b Perp-Cover Spike — Findings (testnet 998, 2026-07-03)

Live end-to-end test of a HyperEVM **contract** opening / reading / closing a long HYPE perp
"cover" via CoreWriter, to de-risk the Slice-3b covered-call cover leg before writing the real
contract.

- Contract: `src/spike/PerpCoverSpike.sol` (throwaway), deployed `0x8Bc3f867d40576485D8031D1a599A11a0a2FD4A8`
- Owner/keeper: deployer `0xe7e5…7278`
- Funded from user `0x9608…9A5b` (Core spot send of 120 USDC); swept back after the run.

## What worked

1. **Contract-driven perp lifecycle works.** Opened 0.5 HYPE long @ $79.22 and closed it, all from
   contract `onlyOwner` calls routed through CoreWriter (`0x3333…3333`). Fills confirmed via
   `userFills`; position read back via the `position` precompile.
2. **Encoding pinned (and a real gotcha).**
   - **WRITE** (CoreWriter limit order): `limitPx` and `sz` are BOTH `human * 1e8`. `$85 -> 85e8`,
     `0.5 HYPE -> 5e7`. A first attempt with `limitPx = price*1e4` (reusing the read scale) **silently
     0-filled** — CoreWriter rejects/expires with no revert and no fill.
   - **READ** (precompiles): `markPx`/`oraclePx` are `price * 10^(6 - szDecimals)` (HYPE `*1e4`);
     `position.szi` is `coins * 10^szDecimals`. **Write-scale ≠ read-scale.**
   - Main-dex (dex 0) order asset id == read perp index == **135**; the `100000+` HIP-3 offset is
     builder-dex-only (NVDA on xyz: order `110002` / read `10002`).
3. **`setUnified()` works from the contract.** `setAbstraction(self, 2)` flipped the contract's Core
   account to unified account (spot USDC shows `tokenToAvailableAfterMaintenance`, matching the user
   account's unified signature). No `usdClassTransfer` needed.
4. **Close settles PnL into SPOT USDC** (the unified balance): 120.000 → 119.140 after the round trip.
   So realizing the cover into USDC on a covered-call payout (the **I3** fix) is mechanically clean —
   close the perp, the USDC lands in the account's spot balance, then `spotSend`/bridge onward.
5. **Rescue path works.** `spotSendUsdc(0x9608, …)` returned the full 119.14 USDC to the user.
6. Round-trip cost was **$0.86** on 0.5 HYPE — dominated by the thin **testnet** book spread
   (bought $79.22 ask, sold $75.68 bid); not representative of mainnet.

## The blocking finding

**A contract-opened perp cover is ISOLATED at the asset's max leverage (HYPE 10×) and is
liquidatable (liqPx $71.74, ≈ −9.4% from entry).** Even with the account set to unified, the
*position* opened isolated 10×, backed by only ~$4.86 of margin.

CoreWriter's action set (ids 1..16) has **no updateLeverage, no cross/isolated toggle, and no
add-isolated-margin action.** So from a pure on-chain flow the cover **cannot** be made cross, 1×,
or otherwise non-liquidatable.

This breaks the covered-call premise: the cover must be **fully-funded / non-liquidatable**, else a
HYPE drawdown liquidates the cover and leaves the pool short a naked uncapped call — insolvency.

## Implications for Slice-3b (design fork)

- **Option A — Spot HYPE cover.** Hold spot HYPE (CoreWriter spot buy, asset `10000 + spotIndex`).
  No leverage, no liquidation, ever — the textbook covered-call structure (own the underlying). Ties
  up full notional and earns no funding, but is trustless and bulletproof. Close = sell spot → USDC.
- **Option B — Perp cover + off-chain leverage set.** Keep the perp (capital-efficient, funding
  income), but CoreWriter can't set 1×/cross. Use action 9 (**Add API wallet**): contract approves an
  agent EOA, an off-chain keeper signs a one-time `updateLeverage(cross, 1×)` L1 action for the
  contract account. Adds a trusted off-chain signer — less trustless.
- **Option C — Perp cover + active margin management.** Keep isolated but a keeper monitors and
  keeps the position far from liqPx. Highest ongoing trust/complexity; a bad-block/oracle gap can
  still liquidate. Weakest.

**Recommendation:** the spike inverts the earlier "perp cover" choice. Given the covered call needs
a non-liquidatable cover and CoreWriter can't set leverage, **Option A (spot HYPE cover)** is now the
clean path. Option B is viable if funding income / capital efficiency is worth an off-chain agent.

## Spot-cover spike (CHOSEN path) — VERIFIED live

`src/spike/SpotCoverSpike.sol`, deployed `0x791A754f244aCA594104dba53605A5C1b18da6C2`. Ran the full
round trip on testnet 998 with 100 USDC:

1. **buyCover** — bought 1.00 HYPE spot @ $63 on asset `11035` (fee 0.0007 HYPE). USDC 100 → 37,
   HYPE 0 → 0.9993. The cover is just a **held token balance** — no leverage, no liqPx, no keeper.
2. **sellCover** — first attempt to sell the raw 0.9993 balance was **silently rejected**: HYPE
   `szDecimals = 2`, so order size must be a 0.01 increment, and 0.9993 (fee dust) is invalid.
   Selling **0.99** (`99000000`) filled @ $50. USDC 37 → 86.47, leaving 0.0093 HYPE dust.
3. **Swept** 86.47 USDC + 0.0093 HYPE back to the funder; contract empty.

Round-trip lost ~$13 = the **testnet** $63 ask / $50 bid spread (+ $0.035 fee). Mainnet HYPE/USDC is
liquid; not representative.

**New finding → 3b requirement:** when unwinding the cover, the sell size MUST be floored to the
underlying's `szDecimals` (HYPE: 2 dp); fee/rounding leaves un-sellable dust that the contract has to
tolerate in its cover accounting (don't assume you can sell the exact held balance).

**Verdict:** spot cover works end-to-end and is trustless/non-liquidatable. Green light to build
`CoveredCallMarket3b` on it.

## Reusable facts for the real contract
- Order px/sz = `human * 1e8`; marketable = IOC through the book; poll reads one Core block after a write.
- Perp read px = `price * 10^(6-szDecimals)` (HYPE `*1e4`); spot read px (`spotPx`) = `*1e6` — neither equals the `*1e8` order scale.
- Order size must respect the asset `szDecimals` (HYPE = 2 → 0.01 increments); floor + carry dust.
- Fresh contract Core accounts default to classic (disabled) + isolated max leverage; `setAbstraction(self,2)` → unified. (Spot cover needs none of this — plain spot balances.)
- Buy/sell settle into the account's spot USDC/HYPE balances; `spotSend` moves them out (rescue / payout).
- HYPE/USDC spot pair index 1035 → order asset id 11035; HYPE token 1105 (weiDec 8); USDC token 0.
