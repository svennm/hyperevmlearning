# Autonomous mark + market-driven cover — design

**Date:** 2026-07-05 · **Branch (proposed):** `slice-autonomous-mark`
**Governing principle (user):** *nothing is set by the owner; pricing is autonomous and market-driven.*
Every trusted **market parameter** is removed — the mark is computed on-chain, cover is priced off the
live order book. What remains owner-gated is only (a) bounded safety levers that cannot trap funds and
(b) the single LP managing its **own** capital.

This is the endgame of the #2 on-chain-mark trust-min track: it removes the **last trusted number in
pricing** (the keeper-posted mark) and the **last owner-set market knobs** (κ, uMax, adaptive gains,
cover slippage). It also unblocks and reframes the covered-call live demo.

## Owner-authority audit (the classification that drove this)

🎯 market-parameter (remove) · 🛡️ safety (keep, bounded) · 💰 LP-op (keep, single-LP) · 🔧 role/infra · ✅ already trust-min

**EverlastingBook**
| Lever | Class | Decision |
|---|---|---|
| `postMark` (keeper) | 🎯 the MARK | **Remove keeper discretion → `mark = fairMark()` on-chain + permissionless `accrue()`** |
| `setUtilKappa` (κ) | 🎯 funding steepness | **Hardcode `UTIL_KAPPA` constant** |
| `setUMax` | 🎯 util/risk cap | **Hardcode `U_MAX` constant** |
| `setAdaptiveParams` (k, u\*) | 🎯 controller tuning | **Hardcode `ADAPT_K`, `U_STAR` constants** |
| `setVol` | 🔧 infra wiring | **Make `vol` immutable ctor arg** |
| `pause`/`unpause`, `emergencyUnwindCover` | 🛡️ safety | **Keep** — can't trap funds, exits stay open |
| `lpDeposit`/`lpWithdraw` | 💰 LP capital | **Keep** onlyOwner (owner = the single LP; multi-LP shares = separate future slice) |
| `setKeeper`, `transferOwnership` | 🔧 role | **Keep** (keeper shrinks to cover-trigger/bridge only) |
| K, W, caps, vault, oracle | ✅ | already immutable |

**EvmUsdcCoverVault**
| Lever | Class | Decision |
|---|---|---|
| `buyCover` price | 🎯 cover price | **`bbo.ask`, market-driven** (no owner slippage knob) |
| `sellCover` price | 🎯 cover price | **`bbo.bid`, market-driven** (kills the last `SLIPPAGE_BPS` const) |
| `buyCover` sizing (hypeWad) | 🔧 keeper trigger | Keep keeper-triggered (in-custody, D3 pre-fund). Autonomous deficit-sizing = deferred |
| `bridgeUsdcTo*` | 🔧 float ops | Keep (in-custody) |
| `pullUsdc`/`payoutUsdc` | ✅ | book-gated (C1) already trust-min |

## Component A — Autonomous mark (flagship; rewrites the book's pricing core)

**Today:** `sideState.mark` is a stored number the keeper posts via `postMark`, bounded to ±10% of
`fairMark` once `vol.ready()`. Funding accrues as `f = mark − lastIntrinsic` per elapsed period.

**Target:** the keeper never posts. The mark **is** the on-chain fair value.

- **`fairMark(side)` becomes the mark.** It already exists (skewed-σ everlasting BS: RealizedVol σ →
  put-skew → adaptive multiplier; PUT = capped spread, CALL = uncapped). No band, no keeper number.
- **Replace `postMark` with permissionless `accrue(side)`:** folds funding since the last accrue using
  the stored period-start mark, then refreshes the stored mark to the current `fairMark()`:
  ```
  intr    = intrinsic(side)
  periods = (now − lastMarkTime) / FUNDING_PERIOD
  if periods > 0:
      f = (mark ≥ lastIntrinsic ? mark − lastIntrinsic : 0) + _utilSurcharge(side)   // P(U) unchanged
      cumFunding += f * periods
      _updateAdaptiveMult(side, periods)                                             // controller unchanged
  mark         = fairMark(side)     // the on-chain value — no keeper input
  lastIntrinsic = intr
  lastMarkTime  = now
  vol.updateVol() (try/catch)       // σ liveness (F1), unchanged
  ```
- **Auto-poke on every interaction:** `openLong` / `close` / `settle` call `_accrue(side)` first, so the
  stored `mark`, `entryMark`, and exit mark are always the live `fairMark` at interaction time and
  funding never stalls between trades. Standalone `accrue(side)` lets anyone advance funding with no trade.
- **Deleted:** `keeper`-gating on the mark, `MARK_BAND_BPS` band logic, `MAX_MARK_DEV_BPS` deviation cap,
  bootstrap/`vol.ready()` branch, `setVol`. `postMark`'s `newMark ≥ intrinsic` / `≤ Wput` clamps become
  moot (fairMark is bounded by construction; keep an internal `min(fairMark, Wput)` clamp on the PUT side
  so the payout cap still holds, and the AUDIT-H intrinsic floor stays as `max(fairMark, intrinsic)`).
- **Robustness:** `fairMark` reverts on `spot == 0`. `accrue` must never brick opens/closes/exits →
  wrap the mark refresh so a transient oracle/vol revert **skips the fold and keeps the last stored
  mark** (fail-safe, pool-conservative), mirroring the current staleness stance. Exits never depend on a
  fresh mark.

**Blast radius:** this is the most-audited, previously-"frozen" part of the book. Every test that calls
`postMark` or asserts a posted `mark`/band/deviation must migrate to `accrue` + `fairMark`. Rebuild via
SDD (fresh implementer + independent auditor per task); conservation invariant + 128k fuzz must still
hold with the controller active.

## Component B — Hardcode the market params

Replace the owner setters with principled constants; make `vol` immutable:
- `UTIL_KAPPA` (P(U) steepness), `U_MAX` (hard util cap, e.g. 0.8e18), `ADAPT_K` (integral gain,
  ≤ MAX_ADAPT_K), `U_STAR` (target utilization, 0.5e18) — all `constant`/`immutable`.
- `vol` → immutable ctor arg (deploy wires RealizedVol at construction).
- Delete `setUtilKappa`, `setUMax`, `setAdaptiveParams`, `setVol` and their events.
- Values chosen conservatively; documented. (Mainnet governance to re-tune = explicit future scope, not now.)

## Component C — Market-driven cover (`EvmUsdcCoverVault`)

`CoreCoverVault` is `@deprecated` → untouched. Both cover legs read the live book:
- **`buyCover(hypeWad, maxUsdc)`** — signature unchanged. `q = bbo(HYPE_SPOT_ASSET)`; `require(q.ask>0)`;
  `limitPx = q.ask × 100 × (10000 + COVER_CROSS_BPS)/10000` (`COVER_CROSS_BPS` = tiny fixed marketability
  buffer, ~50, NOT a price). **H4 fix:** `worstCost = _toUsdc(hypeWad × limitPxWad / WAD)` priced at the
  limit → `maxUsdc` is an honest ceiling. Auto-crosses the dislocated testnet ask ($62.989) with the
  vault's own float; pays the tight ask on a liquid book. No owner slippage knob.
- **`sellCover(hypeWad)`** — signature unchanged (book-called). `limitPx = q.bid × 100 × (10000 −
  COVER_CROSS_BPS)/10000`. Removes the last `SLIPPAGE_BPS` const.
- **`COVER_CROSS_BPS`** is a hardcoded constant (autonomous). The economic bound is `maxUsdc` (buy) and
  the settled-balance check (sell) — not a trusted parameter.

**Scale (verified live):** `bbo(11035)` → `{bid 33000000, ask 62989000}` ×1e6. Order `limitPx` = ×1e8
(`×100`); to WAD = `×1e10`. `bbo(1035)` reverts — asset id is `10000+index = 11035 = HYPE_SPOT_ASSET`.

**Testability (no submodule edits):** the CoreSimulator does **not** serve `bbo`. Tests `vm.mockCall`
the BBO precompile (`0x…080e`) to inject `{bid,ask}` — `$25=$25` keeps existing `buyCover` sim tests
green; a dislocated `$33/$63` proves the auto-cross + the H4 `cost>max` guard (a fill whose stale-bid
estimate would pass but whose ask worst-case exceeds `maxUsdc` now reverts).

## Component D — What stays owner-gated (and why it's not a trust violation)

- **`pause`/`unpause` + `emergencyUnwindCover`** — bounded safety. Pause blocks new `openLong` only;
  all exits (close/settle/withdraw/lpWithdraw/accrue) stay open → cannot trap funds. Emergency requires
  paused, floors to tick, and the M1 `lpWithdraw` call-backing guard prevents stranding call-winners.
- **`lpDeposit`/`lpWithdraw`** — the single LP moving its **own** capital; `lpWithdraw` can only take
  `poolFree()` (never trader collateral/escrow). Not authority over other users. True multi-LP autonomy
  = permissionless ERC4626 shares, a separate large slice.
- **`keeper`** — reduced to triggering cover buys/bridges (in-custody moves; can't extract funds, can't
  set prices). Its *existence* is inherent (someone pokes cover ahead of demand); its *authority* is now
  bounded to non-pricing, non-extracting ops.

## Component E — Redeploy from `main`

`DeployBook.s.sol` updates: pass `vol` (RealizedVol) into the book ctor (now immutable) instead of
`setVol`; drop any param setters (now constants). Deploy with **big blocks** (book ~2.5M gas;
`use_big_blocks(True)` for `0xe7e5`). New addresses supersede the stale `0x95F9`/`0x122f` stack (which
predate all trust-min work). Record in `docs/RUNBOOK-3b.md` + memory.

## Component F — Live demo (autonomous funding-carry + market-driven cover)

The autonomous mark can't be ramped, and spot is stuck at $33 (call OTM vs $50 strike), so the demo
shows the **autonomous everlasting mechanism** end-to-end rather than a synthetic winning close. Micro,
autonomous, `0xe7e5` only (LP=keeper=trader), funded by bridging its own ~$13 EVM USDC → Core:

1. `lpDeposit` — EVM USDC into `poolFree`.
2. Seed cover: `0xe7e5` bridges EVM→Core (own activated acct) → `spot_transfer` USDC → vault Core acct
   (proven activation path) → keeper `buyCover(0.2e18, maxUsdc)` → **market-driven limit crosses the
   $62.989 ask with the vault's own float** (the actual live blocker, now solved). Poll `coverHype()`.
3. `accrue(CALL)` (permissionless) establishes the on-chain mark = `fairMark(CALL)`.
4. Trader `approve` → `deposit(CALL, im)` → `openLong(CALL, 0.1e18)` (cover-gated; auto-accrues).
5. Let ≥1 funding period elapse → `accrue(CALL)` → funding accrues to the pool (autonomously computed).
6. Trader `close(CALL)` → long pays the accrued funding → **pool/LP earns the carry** (real PnL).
7. Trader `withdraw`. Then keeper `sellCover` unwinds the seeded cover (market-driven `bbo.bid` sell into
   the $33 bid) → proves the live cover **sell** path too.

**Success =** tx links for buyCover(cross)/accrue/open/close/withdraw/sellCover; `coverHype` up then down;
funding realized to the pool; conservation (`poolUsdc == poolFree + putEscrow + totalCollateral`) intact.
Append to `docs/RUNBOOK-3b.md`. Round-trip spread cost (~0.2 HYPE @ $63 → sold @ $33) ≈ a few $ testnet.

## Testing strategy

- SDD (fresh implementer + independent auditor per task; opus for the mark-core + reviews). qwen only for
  mechanical codegen, never for fixed-point pricing math.
- Migrate all `postMark` tests → `accrue`/`fairMark`. Keep the 128k-call conservation fuzz **with the
  controller active** (handler pokes `accrue`); it must stay 0-revert.
- `bbo` tests via `vm.mockCall`. Full suite green before redeploy. Whole-branch adversarial re-audit
  (angry persona) focused on: funding-accrual correctness under the computed mark, no mark-refresh brick
  on oracle revert, conservation, and that no owner/keeper can influence a price.

## Out of scope (explicit)

- Permissionless multi-LP ERC4626 shares (the real `lpDeposit` autonomy) — separate large slice.
- Autonomous cover **sizing** (vault buys the `callNetWritten − coverHype` deficit itself) — deferred;
  keeper still triggers cover buys.
- On-chain post-fill 0-fill verification (async → off-chain keeper polls `coverHype`).
- Mainnet governance / param re-tuning of the now-constant market params.
- `CoreCoverVault` (deprecated), `DeltaHedgeManager` (parked).
