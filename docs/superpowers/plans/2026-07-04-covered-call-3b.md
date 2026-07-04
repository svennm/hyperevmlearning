# Covered Call 3b — Implementation Plan (real spot cover, unified two-sided book on Core)

> **For agentic workers:** qwen (`scripts/qwen.sh`) GENERATES each task's Solidity from the
> interface+behavior spec; a Claude auditor reviews each task (spec + solvency) before the next.
> Design: `docs/superpowers/specs/2026-07-03-covered-call-3b-design.md` (decisions D1=F1, D2=Core-spot,
> D3=pre-funded). Spike facts: `docs/research/2026-07-03-perp-cover-spike-findings.md`.

**Goal:** `EverlastingBook` — one unified market writing everlasting HYPE **puts** (USDC-escrowed,
capped) **and** uncapped **covered calls** (backed by a real **spot-HYPE** cover), sharing one USDC
pool and one HYPE cover inventory on the contract's **HyperCore** account. Closes review finding
**I3** (winning call `close()` sells cover → USDC → pool). Reuses 3a accounting (cover ledger, the I2
net-loss predicate, uncapped intrinsic, funding) and Slice-1/2 put mechanics (escrow `W`), rebuilding
the collateral/settlement layer on Core.

**Architecture — the key seam:** an **`ICoverVault`** abstraction separates *option accounting*
(pure, unit-testable) from the *Core collateral layer* (USDC + HYPE on HyperCore via CoreWriter +
precompiles). Two impls: `MockCoverVault` (pure Foundry — the SDD test double, mirrors 3a's abstract
cover) and `CoreCoverVault` (CoreWriter-backed — tested via `hyper-evm-lib`'s `CoreSimulatorLib` fork
sim, then live smoke). Most logic stays fast/pure; CoreWriter risk is isolated to one module.

**Tech Stack:** Solidity 0.8.35 (Foundry/cancun), `@hyper-evm-lib` (`CoreWriterLib`, `PrecompileLib`,
`CoreSimulatorLib`), OpenZeppelin IERC20. qwen3-coder for codegen; live testnet 998.

## Global Constraints
- solc `0.8.35`, `evm_version = cancun`. WAD = 1e18; USDC accounting 6dp; `_toUsdc(wad)=wad/1e12`.
- **Core facts (from the spikes, non-negotiable):** order `limitPx`/`sz` = `human*1e8`; sell size
  floored to underlying `szDecimals` (HYPE = 2 → 0.01 increments) with sub-tick **dust carried** in
  the ledger; fills are **async** (land a Core block later) → never trust optimistic local cover;
  HYPE token `1105` (weiDec 8), USDC token `0` (weiDec 8), HYPE/USDC spot **order asset `11035`**,
  spot px read scale `*1e6`, perp/oracle read scale `*1e4`.
- **Cover invariant (call tail):** `vault.coverHype() ≥ Σ openCall_qty` (1:1), enforced at write time
  via the **on-chain** cover read — a call can only be written against **already-settled** cover.
- **Put invariant (unchanged):** USDC escrow ≥ `Σ openPut_qty · W`.
- **I3 (the point of 3b):** a winning covered-call `close()` calls `vault.sellCover(floor(need,szDec))`
  to realize USDC into `poolUsdc`; dust remainder stays in the cover ledger.
- **I2 (carry from 3a):** settle/close use the full net-loss predicate `markLoss+funding−markGain`,
  not funding-only (see `CoveredCallMarket.netLossUsdc`).
- **Per-side caps:** independent `putCapNotional` / `callCapNotional` params; risks compound on the
  downside (covered call ≡ short put, same side as the put book), so each side is bounded and a
  binding cap is emitted.
- **Events (every state change):** emit on deposit/withdraw, cover buy/sell (with filled size + px +
  dust), openLong, close/settle (signed net + any cover sold), keeper/owner change, pause, and
  cap/param updates. The off-chain keeper + the conservation reasoning depend on these — a
  state-changing path with no event is a defect, not a style choice.
- **Precision discipline:** rounding is deterministic and never creates value; where a rounding choice
  exists it favors the pool (round trader payouts down, trader debits up). `_toUsdc` truncation and
  szDecimals flooring are the only lossy steps; the T7 conservation invariant is the backstop that
  proves no value leaks.
- **Collateral lives on Core (D2):** `poolUsdc` and cover HYPE are the contract's HyperCore spot
  balances; the EVM contract reads them via `PrecompileLib.spotBalance` and moves them via CoreWriter.
  `MockCoverVault` models this as plain ledgers for the pure tests.
- Commits: Conventional Commits + trailers (`Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` /
  `Claude-Session: https://claude.ai/code/session_012oGWjqC5674GKcZC3E83Lc`). Implementers do not push.
- Branch: `slice3b-covered-call-market` off `slice3-covered-call` (spikes/design stay on `slice3b-perp-cover-spike`).

---

## Phase A — Core-collateral adapter (isolate CoreWriter)

### Task 1: `ICoverVault` interface + `MockCoverVault` (pure Foundry double)
**Files:** Create `src/interfaces/ICoverVault.sol`, `src/mocks/MockCoverVault.sol`, `test/CoverVault.mock.t.sol`
**Produces:** `ICoverVault` with: `poolUsdc() view (uint256, 6dp)`, `coverHype() view (uint256 WAD)`,
`coverEquityUsdc() view`, `buyCover(uint256 hypeWad, uint256 maxUsdc)`, `sellCover(uint256 hypeWad) returns (uint256 usdcOut)`,
`payoutUsdc(address to, uint256 amt)`, `pullUsdc(address from, uint256 amt)` (deposit), `spotPxUsdc() view`.
`MockCoverVault`: implements all against internal ledgers + a settable mock px; `sellCover` **floors
`hypeWad` to szDecimals=2** and returns proceeds at mock px, leaving dust in `coverHype`.
**Behavior spec for qwen:** this is the seam 3a abstracted — `buyCover` debits `poolUsdc`, credits
`coverHype` at px; `sellCover` floors to 0.01 HYPE, credits `poolUsdc`; expose the dust behavior so
callers must tolerate it. No CoreWriter here.
**Tests:** buy moves usdc→hype at px; sell floors to szDecimals (selling 0.9993 sells 0.99, 0.0093
dust remains); coverEquity = coverHype·px; payout/pull move usdc.
**Audit focus:** szDecimals flooring + dust accounting is exact; equity math; no negative balances.

### Task 2: `CoreCoverVault` (CoreWriter-backed) + fork-sim tests
**Files:** Create `src/CoreCoverVault.sol`, `test/CoreCoverVault.sim.t.sol` (CoreSimulatorLib), `test/CoreCoverVault.fork.t.sol` (live read)
**Consumes:** Task 1 interface.
**Produces:** `CoreCoverVault is ICoverVault` implementing the interface via `CoreWriterLib` (spot
buy/sell on asset `11035`, `spotSend` for payout, `PrecompileLib.spotBalance`/`spotPx` for reads),
owner/keeper-gated cover ops, `human*1e8` order encoding, szDecimals flooring + dust carry, marketable
IOC through the book.
**Behavior spec for qwen:** `buyCover(hypeWad,maxUsdc)` → `placeLimitOrder(11035,true, px*1e8, hype*1e8,…)`
with px from `spotPx` + slippage bps; `sellCover` → sell floored size, IOC below bid; `coverHype()` =
`spotBalance(this,1105).total` (wei→WAD); async — document that cover reads reflect settled fills only.
**Tests:** `CoreSimulatorLib` sim: buy → nextBlock → coverHype reflects fill; sell floored → poolUsdc
up; dust remains. `fork`: reads live spotPx/balances (no funds).
**Audit focus (CRITICAL):** px/sz `*1e8` encoding; szDecimals floor; the async gap is respected (no
optimistic cover); no self-transfer/precision reverts. This module carries all CoreWriter risk.

## Phase B — Unified two-sided book (reuse 3a + slice2)

### Task 3: `EverlastingBook` skeleton — sides, shared pool, intrinsic, vault wiring
**Files:** Create `src/EverlastingBook.sol`, `test/Book.intrinsic.t.sol`
**Produces:** `enum Side { PUT, COVERED_CALL }`; constructor takes `ICoverVault vault`, oracle, keeper,
`Kput`, `Wput`, `Kcall`, caps. Per-side state (marks, cumFunding, netWritten, positions keyed by
`(side,trader)`); `intrinsic(side)`: PUT = `clamp(K−S,0,W)` (slice2), COVERED_CALL = `max(S−K,0)`
(uncapped, 3a). `poolUsdc()` delegates to `vault`.
**Behavior spec for qwen:** reuse `EverlastingMarket` (put/slice2) + `CoveredCallMarket` (call/3a)
patterns; the book holds NO cash itself — all USDC/HYPE lives in `vault`. Positions carry `side`.
**Tests:** put intrinsic capped at W; call intrinsic uncapped (deep ITM 10K→9K); side isolation.
**Audit focus:** clean side separation; no cash held outside the vault.

### Task 4: Covered-call side — cover-gated `openLong` + funding + uncapped `postMark`
**Files:** Modify `src/EverlastingBook.sol`; Create `test/Book.call.open.t.sol`
**Consumes:** Tasks 1–3.
**Produces:** `openLong(COVERED_CALL, qty)` — fresh mark, one position/trader/side, premium IM, and
**cover gate `require(vault.coverHype() ≥ callNetWritten + qty)`** (on-chain read, D3), plus
`require(callNetWritten+qty ≤ callCapNotional-equivalent)`; funding via contemporaneous `lastIntrinsic`
(3a/F3); `postMark` uncapped (no `≤W`), keeper-gated, deviation + recoverable-staleness guards.
**Tests:** open reverts "cover" when `coverHype < net+qty`; cap revert; IM revert; stale-mark revert;
funding accrues `mark−intrinsic`; postMark accepts marks > K.
**Audit focus:** cover gate reads the **vault** (not local optimistic state); cap enforced; no mark clamp.

### Task 5: Covered-call `close`/`settle` with I3 cover→USDC + I2 net-loss + szDecimals
**Files:** Modify `src/EverlastingBook.sol`; Create `test/Book.call.close.t.sol`
**Consumes:** Tasks 1–4.
**Produces:** `_closeCall(t)` — compute funding + markPnl; **on a positive trader net, call
`vault.sellCover(floor(neededHype, szDec))` to realize USDC, then pay from `poolUsdc`** (I3);
loss path floors at collateral (auto-settle); `netLossUsdc` full predicate for `settle` (I2);
`callNetWritten -= qty`. Cover unwound on close is `min(position share, floored)`; dust carried.
**Behavior spec for qwen:** the winning payout must be *funded by selling cover*, not assumed present
in `poolUsdc` — this is the whole I3 fix and the reason cover is real in 3b. Mirror
`CoveredCallMarket._closeFor` gain/loss split; add the `vault.sellCover` step on the gain branch.
**Tests:** winning close sells cover → poolUsdc → trader paid (assert vault.coverHype drops, floored);
losing close floors at collateral; `settle` fires on `netLossUsdc>collateral` (the I2 markLoss case);
netWritten symmetric; dust tolerated.
**Audit focus (CRITICAL):** I3 — payout is actually sourced from cover sale, so `close()` can't
false-revert on an uncapped win; szDecimals floor on the sale; I2 predicate matches `_closeFor`.

### Task 6: Put side folded in (escrow `W`, slice2) sharing the pool
**Files:** Modify `src/EverlastingBook.sol`; Create `test/Book.put.t.sol`
**Consumes:** Tasks 3–5.
**Produces:** `openLong(PUT, qty)` / `_closePut` — Slice-1/2 escrow model (`vault` escrows
`qty·W` USDC), fully collateralized, funding, auto-settle; `putCapNotional` enforced. Shares the same
`vault.poolUsdc` as the call side.
**Tests:** put open escrows qty·W; close pays capped payout; put + call coexist on one pool without
cross-contamination; put cap enforced.
**Audit focus:** put escrow released-first (slice2 F2 no-false-revert); shared-pool accounting doesn't
let one side spend the other's escrow/cover.

## Phase C — Solvency, reconciliation, live

### Task 7: Extended conservation + per-side caps + async reconciliation
**Files:** Modify `src/EverlastingBook.sol`; Create `test/Book.invariant.t.sol` (fuzz), `test/Book.reconcile.t.sol`
**Consumes:** Tasks 1–6 (use `MockCoverVault`).
**Produces:** `invariant_conservation` extended to the HYPE leg:
`vault.poolUsdc + vault.coverEquityUsdc + putEscrow == Σ traderCollateral(both sides)` (marked to
oracle); `invariant_coverGate` (`coverHype ≥ callNetWritten`); `invariant_putEscrow`. Deposit/withdraw
via `vault.pullUsdc`/`payoutUsdc` (Core-spot model). Reconciliation: openLong gates on the vault read
(pre-funded-cover model D3) — a helper test shows a call can't be written ahead of settled cover.
**Behavior spec for qwen:** conservation is the load-bearing solvency check (real, non-vacuous — like
3a-I1); mark the HYPE leg at oracle; caps + gates keep both invariants true under fuzz.
**Audit focus (CRITICAL):** conservation is non-vacuous and holds under fuzzed spot→∞ AND spot→0
(downside is where put payout + cover collapse compound); cover gate never violated; caps bind.

### Task 8: Admin, emergency controls, events & precision sweep
**Files:** Modify `src/EverlastingBook.sol`, `src/CoreCoverVault.sol`; Create `test/Book.admin.t.sol`
**Consumes:** Tasks 1–7.
**Produces:**
- **Roles:** `owner` + `keeper`; owner-gated `setKeeper(addr)` and **2-step** `transferOwnership`/
  `acceptOwnership` (no single-tx owner loss). Addresses 3a review M3 (keeper had no setter).
- **Pause:** `pause()`/`unpause()` (owner) blocks new `openLong` (both sides) + cover buys, but
  ALWAYS allows `close`/`settle`/`withdraw`/`sellCover` and `postMark` — a de-risk switch, never a
  fund trap. Users and the pool can always exit while paused.
- **Emergency cover unwind:** owner-only `emergencyUnwindCover()` (paused-only) — sell all cover →
  `poolUsdc` respecting szDecimals floor + dust, for wind-down.
- **Rescue:** owner-gated `spotSend` of stray non-collateral balances (already on `CoreCoverVault`
  from the spike — expose owner-gated on the book path).
- **Events sweep:** verify EVERY state-changing path emits per the Global-Constraints events rule; add
  any missing.
- **Precision sweep:** verify each `_toUsdc`/floor rounds in the pool's favor; add an adversarial
  round-trip test proving no op creates value (`poolUsdc + coverEquity` non-decreasing ex-payout).
**Behavior spec for qwen:** pause never traps funds (close/withdraw work while paused); ownership is
2-step; `emergencyUnwindCover` only when paused. YAGNI — only these controls, nothing more.
**Tests:** setKeeper gating; 2-step ownership (pending→accept; stray accept reverts); pause blocks
open but allows close/withdraw; emergencyUnwind sells all cover to pool (floored); `vm.expectEmit` on
each state-changing path; precision round-trip creates no value.
**Audit focus:** pause cannot trap funds (exit paths always open); ownership can't be lost in one tx;
emergencyUnwind respects szDecimals; event coverage complete; rounding always pool-favorable.

### Task 9: Live testnet integration — deploy `CoreCoverVault` + book, 2-sided smoke
**Files:** Create `script/DeployBook.s.sol`, `docs/RUNBOOK-3b.md`
**Consumes:** all.
**Produces:** deploy `CoreCoverVault` + `EverlastingBook` (vault = the real Core vault) on testnet 998;
runbook to: fund the vault (user Core-spot USDC send), keeper pre-buys cover, write a covered call,
post marks, close (cover sold → USDC), and write/close a put — observing balances via precompiles.
**Behavior spec:** mirror the spike ops; small sizes; sweep funds back after. No new contract logic.
**Audit focus:** end-to-end on-chain: cover gate honored live, I3 sale funds the payout, both sides
share the pool, funds recoverable.

## Self-Review
- Spec coverage: adapter seam (T1–T2), two-sided book skeleton (T3), covered-call open/close with I3+I2
  (T4–T5), put fold-in (T6), extended solvency + caps + reconciliation (T7), admin/emergency/events/
  precision sweep (T8), live 2-sided smoke (T9) — maps to design D1 (F1 unified), D2 (Core-spot),
  D3 (pre-funded cover), and the I3 fix.
- Production hardening: events on every state change (global constraint + T8 sweep), pool-favorable
  rounding discipline (global constraint + T8 precision test), admin/emergency controls (T8: 2-step
  ownership, keeper setter, pause-that-can't-trap-funds, emergency unwind, rescue).
- Reuse, not rewrite: put mechanics from `EverlastingMarket` (slice2), call accounting/funding/I2 from
  `CoveredCallMarket` (3a); only the collateral/settlement layer (vault) and the fold are new.
- CoreWriter risk isolated to `CoreCoverVault` (T2), tested via CoreSimulatorLib + live; the book and
  its solvency are pure-Foundry via `MockCoverVault` (T1) — fast SDD, high-confidence invariants.
- Open risk: T5 (I3 cover→USDC on the hot path — async + szDecimals dust) and T7 (conservation under
  the compounding downside) are the novel cores — auditor rigor gates both.
- Netting caveat honored: no cover-size discount from the put book; per-side caps because risks compound.
