# Covered Call 3a — Implementation Plan (option accounting + solvency-given-cover)

> **For agentic workers:** qwen (`scripts/qwen.sh`) GENERATES each task's Solidity from the interface+behavior spec below; a Claude auditor reviews each task (spec + solvency) before the next. Pure Foundry, no CoreWriter, no real USDC.

**Goal:** A `CoveredCallMarket` that writes UNCAPPED everlasting HYPE calls, collateralized by an *abstracted* long-HYPE cover held as internal state, and proves the pool stays solvent as spot → ∞ **given the cover invariant** — all in pure Foundry with MockUSDC.

**Architecture:** Reuse Slice-1/2's funding machinery (oracle mark, cumulative-funding index, deposit/withdraw, keeper-posted mark, auto-settle). Replace cash escrow with a **cover ledger**: the pool is long `coverQty` HYPE at avg entry `coverEntry`; cover equity = `coverQty·S`. A call may only be opened while `coverQty ≥ netWritten + qty`. Cover is grown by a keeper op (`increaseCover`) — internal bookkeeping in 3a, the CoreWriter seam for 3b.

**Tech Stack:** Solidity 0.8.35 (Foundry/cancun), OpenZeppelin IERC20, MockUSDC (6dp), MockOracle (WAD). qwen3-coder for codegen.

## Global Constraints
- solc `0.8.35`, `evm_version = cancun`.
- **Uncapped call:** `intrinsicWad() = max(S − K, 0)` — NO upper clamp (unlike Slice-2's capped `W`).
- **Cover invariant (the solvency backbone):** `coverQty ≥ netWritten` at all times a position is open; `openLong` reverts if opening would violate it.
- **Cover equity:** `coverEquityUsdc() = _toUsdc(coverQty · S / 1e18)` where `S = oracle.spotWad()` (models a fully-funded 1× long perp: equity = qty·S).
- **Solvency claim to prove:** with the cover invariant held, `poolUsdc + coverEquity ≥ every open position's max payout`, for all `S` including `S → ∞`. This is the fuzz target.
- **3a is pure Foundry + MockUSDC.** No CoreWriter, no HyperCore, no real USDC. `increaseCover`/`reduceCover` are internal (keeper/lp-gated) state ops standing in for the 3b perp.
- Reuse the Slice-1/2 cumulative-funding-index pattern (`cumFunding`, `pendingFunding`, contemporaneous `lastIntrinsic`) verbatim in behavior.
- WAD = 1e18; USDC = 6dp; `_toUsdc(wad) = wad/1e12`.
- Commits: Conventional Commits + trailers (`Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` / `Claude-Session: https://claude.ai/code/session_01BLLCj5i3z4KaKHQWYV75Z6`). No push by implementers.

---

### Task 1: `CoveredCallMarket` skeleton — state, uncapped intrinsic, balances
**Files:** Create `src/CoveredCallMarket.sol`, `test/CoveredCall.intrinsic.t.sol`
**Produces:** `CoveredCallMarket(IERC20 usdc, ISpotOracle oracle, uint256 K, address keeper)`; getters `K()`, `poolUsdc()`, `coverQty()`, `coverEntry()`, `netWritten()`, `traderCollateral(addr)`, `mark()`, `cumFunding()`; `intrinsicWad() = max(S−K,0)`; `lpDeposit/lpWithdraw` (lp-gated, move `poolUsdc`); `deposit/withdraw` (trader collateral).
**Behavior spec for qwen:** mirror `EverlastingMarket` state/patterns but: no `W`; add `uint256 public coverQty; uint256 public coverEntry; uint256 public netWritten;` and `uint256 public poolUsdc` (rename of pool free cash). `intrinsicWad`: `s = oracle.spotWad(); return s > K ? s - K : 0;`
**Tests (qwen writes, must assert):** intrinsic OTM (S≤K→0), ITM ramp (S=K+3 → 3), deep ITM (S=10K → 9K, uncapped — no clamp); lpDeposit/withdraw move poolUsdc; deposit/withdraw move traderCollateral; withdraw reverts with open position.
**Audit focus:** uncapped intrinsic (no accidental clamp), state names match Produces.

### Task 2: Cover ledger + invariant
**Files:** Modify `src/CoveredCallMarket.sol`; Create `test/CoveredCall.cover.t.sol`
**Consumes:** Task 1 state.
**Produces:** `increaseCover(uint256 qtyWad)` (lp/keeper-gated: grows `coverQty`, updates `coverEntry` as the qty-weighted avg of old entry and current `S`); `coverEquityUsdc() view` = `_toUsdc(coverQty·S/1e18)`; internal `_coverCovers(uint256 addQty) view` = `coverQty ≥ netWritten + addQty`.
**Behavior spec for qwen:** `coverEntry` avg: `newEntry = (coverQty·coverEntry + qtyWad·S) / (coverQty + qtyWad)`. In 3a `increaseCover` is pure bookkeeping (no token move — it models margin already posted; keep it simple and gated).
**Tests:** increaseCover updates qty + weighted entry; coverEquity = qty·S; `_coverCovers` true/false at boundary; only lp/keeper can call.
**Audit focus:** weighted-avg entry math; the invariant helper is correct (`≥`, off-by-one).

### Task 3: `openLong` + funding + `postMark` (uncapped)
**Files:** Modify `src/CoveredCallMarket.sol`; Create `test/CoveredCall.open.t.sol`
**Consumes:** Tasks 1–2.
**Produces:** `openLong(uint256 qtyWad)` — requires fresh mark, one position/trader, trader IM (`traderCollateral ≥ _toUsdc(qty·mark/1e18)` as premium-style IM), and **cover gate `require(_coverCovers(qtyWad), "cover")`**; on success `netWritten += qtyWad`, record `Position(qty, mark, cumFunding)`. `postMark(uint256)` — keeper-gated, guards `mark ≥ intrinsic` + recoverable staleness + deviation (reuse Slice-1/2), **NO upper bound** (uncapped); advances `cumFunding` with contemporaneous `lastIntrinsic`. `pendingFunding(addr)` as Slice-1/2.
**Tests:** openLong locks nothing in cover but bumps netWritten + requires cover (reverts "cover" when `coverQty < netWritten+qty`); IM revert; stale-mark revert; funding accrues `mark−intrinsic` over a period; postMark accepts marks > K (uncapped).
**Audit focus:** the cover gate is present and correct; no accidental `mark ≤ K/W` clamp; funding pair (F3) contemporaneous.

### Task 4: `close` / cash-settle + `settle` (auto-settle) + `reduceCover`
**Files:** Modify `src/CoveredCallMarket.sol`; Create `test/CoveredCall.close.t.sol`
**Consumes:** Tasks 1–3.
**Produces:** `close()`/`_closeFor(t)` — realize `funding = qty·(cumFunding−entryCumFunding)`, `markPnl = qty·(mark−entryMark)`; trader net = markPnl − funding (USDC); pay from `poolUsdc`, floor trader loss at collateral (auto-settle); `netWritten -= qty`; delete position. `settle(t)` permissionless when `funding > collateral`. `reduceCover(uint256 qtyWad)` (lp/keeper) — shrinks `coverQty` (models closing perp), gated so it can't drop `coverQty < netWritten`.
**Behavior spec for qwen:** the pool pays the trader's positive net from `poolUsdc`; the COVER's job is to keep `poolUsdc + coverEquity` solvent (proven in Task 5), not to be moved per-close in 3a. `reduceCover` must revert if it would break the cover invariant.
**Tests:** close pays mark gain; funding flows to pool; auto-settle floors loss at collateral; `netWritten` decrements; `reduceCover` reverts if it would violate invariant.
**Audit focus:** auto-settle floor (no underflow); `netWritten` bookkeeping symmetric with Task 3; reduceCover invariant guard.

### Task 5: Solvency-given-cover invariant (fuzz, spot → ∞)
**Files:** Create `test/CoveredCall.invariant.t.sol`
**Consumes:** Tasks 1–4.
**Produces:** a fuzz handler (keeper = handler via nonce-prediction, as Slice-1/2) exercising increaseCover/openLong/postMark/moveSpot/closePos/settlePos, and an invariant:
`invariant_solvencyGivenCover`: **if `coverQty ≥ netWritten`, then `poolUsdc + coverEquityUsdc() ≥ Σ (open positions' owed intrinsic in USDC)`** — asserted across fuzzed spot that ranges to very large values (e.g. up to 1000×K) so the uncapped payoff is stressed. Plus `afterInvariant` marks-posted > 0 (non-vacuous).
**Behavior spec for qwen:** handler must keep growing cover before/when opening (so the invariant's premise is reachable and the body is exercised non-trivially). moveSpot bound e.g. `[1e18, 1000·K]`.
**Audit focus (CRITICAL):** is the invariant NON-VACUOUS (opens actually happen, spot actually goes huge, cover premise holds during real positions)? Does `poolUsdc + coverEquity ≥ owed` genuinely hold as S→∞ — i.e. does the cover math actually offset the uncapped payoff? This is the whole point of 3a; the auditor must verify by reasoning, not just that it's green.

## Self-Review
- Spec coverage: uncapped intrinsic (T1), cover ledger+invariant (T2), open+funding+uncapped mark (T3), close/cash-settle/reduceCover (T4), solvency-given-cover fuzz (T5) — maps to design §4/§5/§8/§9/§10/§12 (3a scope). CoreWriter/real-USDC (§7,§6) = 3b, out.
- No placeholders: each task gives interface + behavior + test assertions; qwen writes impl, auditor checks.
- Type consistency: `coverQty/coverEntry/netWritten/poolUsdc/increaseCover/reduceCover/coverEquityUsdc/_coverCovers/intrinsicWad` used consistently across tasks.
- Open risk: the cover math (T2 entry avg + T5 solvency) is the novel core — auditor rigor on T2 and T5 is the gate.
