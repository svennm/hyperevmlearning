# Autonomous Mark + Market-Driven Cover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove every trusted market parameter from the live options venue — compute the mark on-chain (`mark = fairMark()`, permissionless `accrue()`), price cover off the live order book (`bbo`), and hardcode the remaining market knobs — then redeploy from `main` and prove the autonomous covered-call lifecycle live.

**Architecture:** `EverlastingBook` stops accepting a keeper-posted mark; a permissionless `accrue(side)` folds funding using the **stored** period-start mark, then refreshes the stored mark to `_computedMark(side)` (= `fairMark` floored at intrinsic, PUT-capped at `Wput`). `close`/`settle` keep reading the stored mark (oracle-independent → exits never brick). Owner-set κ/uMax/adaptive-gains/vol become constants/immutable. `EvmUsdcCoverVault.buyCover`/`sellCover` read `bbo.ask`/`bbo.bid`. Everything else (escrow, cover-gate, I2/I3, conservation) is unchanged.

**Tech Stack:** Solidity 0.8.35, Foundry (forge 1.7.1), hyper-evm-lib (submodule) `PrecompileLib`/`CoreWriterLib`, solady FixedPointMathLib, OZ 5.4. HyperEVM testnet 998.

## Global Constraints

- Solidity `0.8.35`; `forge` at `$HOME/.foundry/bin`.
- `EverlastingBook` runtime must stay < 24576 B (EIP-170); today 16,473 B — the net change is a slight reduction (deleting band/deviation/setters).
- Conservation invariant holds always: `vault.poolUsdc() == poolFree() + putEscrow + totalCollateral`. The 128k-call fuzz must stay **0 reverts** with the adaptive controller active.
- Fund-critical fixed-point / funding math is written and reviewed by Claude (opus), never qwen.
- `CoreCoverVault` is `@deprecated` — do NOT modify it. `DeltaHedgeManager` is parked — only touch it if a signature it consumes changes (none do here).
- No owner/keeper input may influence any price. `COVER_CROSS_BPS`, `UTIL_KAPPA`, `U_MAX`, `ADAPT_K`, `U_STAR` are compile-time constants.
- After each task: `forge test` green (except the one known env-gated fork test `CallForkTest.test_call_intrinsic_readsLiveOracle_andClamps`, which needs a live HL fork URL). Commit per task. Push at phase boundaries.

---

## Phase 1 — Market-driven cover (`EvmUsdcCoverVault`, isolated)

### Task 1: `buyCover` reads the live ask (`bbo`) + H4 cost-at-limit

**Files:**
- Modify: `src/EvmUsdcCoverVault.sol` (add const `COVER_CROSS_BPS`; rewrite `buyCover` ~170-185; remove const `SLIPPAGE_BPS` use on the buy side)
- Test: `test/EvmUsdcCoverVault.unit.t.sol`, `test/EvmUsdcCoverVault.sim.t.sol`

**Interfaces:**
- Consumes: `PrecompileLib.bbo(uint64 asset) → Bbo{uint64 bid; uint64 ask}` (asset = `HYPE_SPOT_ASSET` = 11035). `bbo` scale = ×1e6 (verified live: bid 33000000, ask 62989000). Order `limitPx` scale = ×1e8 (`×100`); WAD = `×1e10`.
- Produces: `buyCover(uint256 hypeWad, uint256 maxUsdc)` — **signature unchanged**. Reverts `"no ask"` if `bbo.ask==0`, `"cost>max"` if worst-case-at-limit > `maxUsdc`, `"qty=0"`, `"qty: below min tick"`.

- [ ] **Step 1: Write failing tests** (mock the BBO precompile — the sim doesn't serve it)

```solidity
// test/EvmUsdcCoverVault.unit.t.sol — add
address constant BBO_ADDR = 0x000000000000000000000000000000000000080e;

function _mockBbo(uint64 bid, uint64 ask) internal {
    vm.mockCall(BBO_ADDR, abi.encode(uint64(11035)),
        abi.encode(PrecompileLib.Bbo({bid: bid, ask: ask})));
}

function test_buyCover_crossesLiveAsk_dislocatedBook() public {
    // bid $33, ask $62.989 (the real testnet dislocation)
    _mockBbo(33_000_000, 62_989_000);
    CoreSimulatorLib.forceSpotBalance(address(vault), USDC_TOKEN, 1000e8); // fund Core float
    vm.prank(keeper);
    vault.buyCover(0.2e18, 14e6); // 0.2 HYPE, cap $14 (0.2 * ~$63.3 limit ≈ $12.7)
    CoreSimulatorLib.nextBlock();
    assertGt(vault.coverHype(), 0, "cover acquired crossing the ask");
}

function test_buyCover_costGuardPricedAtLimit_notStaleBid() public {
    // H4: stale-bid estimate ($33*0.2=$6.6) would pass a $7 cap, but the ask-priced
    // worst case ($63*0.2≈$12.7) must exceed it and revert.
    _mockBbo(33_000_000, 62_989_000);
    CoreSimulatorLib.forceSpotBalance(address(vault), USDC_TOKEN, 1000e8);
    vm.prank(keeper);
    vm.expectRevert(bytes("cost>max"));
    vault.buyCover(0.2e18, 7e6);
}

function test_buyCover_revertsOnZeroAsk() public {
    _mockBbo(33_000_000, 0);
    vm.prank(keeper);
    vm.expectRevert(bytes("no ask"));
    vault.buyCover(0.2e18, 100e6);
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `forge test --mp test/EvmUsdcCoverVault.unit.t.sol -vv`
Expected: FAIL (buyCover still uses `spotPx`; `PrecompileLib.Bbo` import may be missing).

- [ ] **Step 3: Implement** (add import `import {PrecompileLib} ...` already present; add const + rewrite)

```solidity
/// @dev Marketability buffer over the live best quote (bps). A FIXED constant — it does not set the
///      price (the on-chain BBO does); it only guarantees the IOC crosses if the quote ticks.
uint256 internal constant COVER_CROSS_BPS = 50;

function buyCover(uint256 hypeWad, uint256 maxUsdc) external onlyKeeper {
    require(hypeWad > 0, "qty=0");
    PrecompileLib.Bbo memory q = PrecompileLib.bbo(uint64(HYPE_SPOT_ASSET));
    require(q.ask > 0, "no ask");
    // ask ×1e6 → order limitPx ×1e8 (×100), plus a tiny fixed cross buffer.
    uint64 limitPx = uint64(uint256(q.ask) * 100 * (10000 + COVER_CROSS_BPS) / 10000);
    // H4: worst-case spend at the LIMIT (not the stale bid) ≤ caller cap.
    uint256 limitPxWad = uint256(limitPx) * 1e10;
    uint256 worstCost  = _toUsdc(hypeWad * limitPxWad / WAD);
    require(worstCost <= maxUsdc, "cost>max");
    uint64 sz = uint64(hypeWad / 1e10);
    require(sz > 0, "qty: below min tick");
    CoreWriterLib.placeLimitOrder(
        HYPE_SPOT_ASSET, true, limitPx, sz, false, HLConstants.LIMIT_ORDER_TIF_IOC, ++cloidSeq
    );
}
```

Also update the existing sim tests that call `buyCover` (they set `spotPx=$25` and expect a fill): add `_mockBbo(25_000_000, 25_000_000)` in their bodies (a `$25=$25` quote), and bump any `maxUsdc` that was flush against the old bid estimate by the 0.5% buffer. Files: `test/EvmUsdcCoverVault.sim.t.sol` (`test_sim_buyCover_consumesCoreFloat`, `test_sim_buyCover_slippageReverts`).

- [ ] **Step 4: Run tests, verify pass**

Run: `forge test --mp test/EvmUsdcCoverVault.unit.t.sol --mp test/EvmUsdcCoverVault.sim.t.sol -vv`
Expected: PASS (new cross + H4 + zero-ask; migrated sim buyCover tests green).

- [ ] **Step 5: Commit**

```bash
git add src/EvmUsdcCoverVault.sol test/EvmUsdcCoverVault.unit.t.sol test/EvmUsdcCoverVault.sim.t.sol
git commit -m "feat(vault): buyCover prices off live bbo.ask + H4 cost-at-limit (market-driven, no owner knob)"
```

### Task 2: `sellCover` reads the live bid (`bbo`) — kill the last `SLIPPAGE_BPS`

**Files:**
- Modify: `src/EvmUsdcCoverVault.sol` (`sellCover` ~192-208; remove `SLIPPAGE_BPS` const once unused)
- Test: `test/EvmUsdcCoverVault.sim.t.sol`

**Interfaces:**
- Produces: `sellCover(uint256 hypeWad) → uint256 usdcOut` — **signature unchanged** (book-called in `_closeCall`). limit `= bbo.bid × 100 × (10000 − COVER_CROSS_BPS)/10000`. `usdcOut` estimate uses `bbo.bid`.

- [ ] **Step 1: Write failing test**

```solidity
function test_sim_sellCover_crossesLiveBid() public {
    _mockBbo(33_000_000, 62_989_000);           // helper mirrored into sim test file
    CoreSimulatorLib.forceSpotBalance(address(vault), HYPE_TOKEN, 1e8); // 1 HYPE
    vm.prank(keeper);
    uint256 out = vault.sellCover(1e18);
    CoreSimulatorLib.nextBlock();
    assertApproxEqAbs(out, 33e6, 1e6, "sell est at ~bid $33");
}
```

- [ ] **Step 2: Run, verify fail**

Run: `forge test --mp test/EvmUsdcCoverVault.sim.t.sol -vv`
Expected: FAIL (sellCover still uses `spotPx`).

- [ ] **Step 3: Implement**

```solidity
function sellCover(uint256 hypeWad) external onlyBookOrKeeper returns (uint256 usdcOut) {
    // forge-lint: disable-next-line(divide-before-multiply) -- intentional floor-to-tick
    uint256 floored = (hypeWad / HYPE_TICK) * HYPE_TICK;
    require(floored > 0, "qty: below min tick");
    uint256 hypeWei    = uint256(PrecompileLib.spotBalance(address(this), HYPE_TOKEN).total);
    uint256 currentWad = hypeWei * 1e10;
    require(currentWad >= floored, "cover: insufficient");
    PrecompileLib.Bbo memory q = PrecompileLib.bbo(uint64(HYPE_SPOT_ASSET));
    require(q.bid > 0, "no bid");
    usdcOut     = _toUsdc(floored * (uint256(q.bid) * 1e12) / WAD);
    uint64 sz   = uint64(floored / 1e10);
    uint64 limitPx = uint64(uint256(q.bid) * 100 * (10000 - COVER_CROSS_BPS) / 10000);
    CoreWriterLib.placeLimitOrder(
        HYPE_SPOT_ASSET, false, limitPx, sz, false, HLConstants.LIMIT_ORDER_TIF_IOC, ++cloidSeq
    );
}
```

Delete the now-unused `uint256 internal constant SLIPPAGE_BPS = 50;`. Add `_mockBbo` helper to the sim test file; add `_mockBbo(25_000_000,25_000_000)` to any existing `sellCover` sim test.

- [ ] **Step 4: Run, verify pass** — `forge test --mp test/EvmUsdcCoverVault.sim.t.sol -vv` → PASS.

- [ ] **Step 5: Commit + push Phase 1**

```bash
git add src/EvmUsdcCoverVault.sol test/EvmUsdcCoverVault.sim.t.sol
git commit -m "feat(vault): sellCover prices off live bbo.bid; drop hardcoded SLIPPAGE_BPS"
git push -u origin slice-autonomous-mark
```

---

## Phase 2 — Autonomous mark (`EverlastingBook`)

### Task 3: `IVolSource` seam + `MockVol` (additive only — book ctor untouched)

**Files:**
- Create: `src/interfaces/IVolSource.sol`
- Create: `src/mocks/MockVol.sol`
- Modify: `src/RealizedVol.sol` (declare `is IVolSource`)
- Test: `test/MockVol.t.sol` (new)

**Sequencing note:** this task is purely additive so the whole suite stays green. The `EverlastingBook`
ctor change (`vol` → immutable `IVolSource` arg, delete `setVol`) lands in **Task 5**, atomically with the
13-file test migration — otherwise the ctor change breaks every book test before they're migrated.

**Interfaces:**
- Produces: `interface IVolSource { function sigma() external view returns (uint256); function ready() external view returns (bool); function updateVol() external; }`. `MockVol` with `setSigma(uint256)`, `setReady(bool)`; `updateVol()` no-op. `RealizedVol is IVolSource` (its existing `sigma`/`ready`/`updateVol` already match — no logic change).

- [ ] **Step 1: Write failing test**

```solidity
// test/MockVol.t.sol
import {MockVol} from "../src/mocks/MockVol.sol";
import {IVolSource} from "../src/interfaces/IVolSource.sol";
import {RealizedVol} from "../src/RealizedVol.sol";
function test_mockVol_reportsSetSigmaAndReady() public {
    MockVol v = new MockVol();
    v.setSigma(1.2e18); v.setReady(false);
    assertEq(v.sigma(), 1.2e18);
    assertEq(v.ready(), false);
    IVolSource(address(v)).updateVol(); // no-op, no revert
}
function test_realizedVol_isIVolSource() public {
    // compile-time proof RealizedVol satisfies the interface
    IVolSource v = IVolSource(address(new RealizedVol(ISpotOracle(address(oracle)))));
    v.ready();
}
```

- [ ] **Step 2: Run, verify fail** — `forge test --mp test/MockVol.t.sol -vv` → FAIL (`IVolSource`/`MockVol` missing).

- [ ] **Step 3: Implement**

```solidity
// src/interfaces/IVolSource.sol
interface IVolSource {
    function sigma() external view returns (uint256);
    function ready() external view returns (bool);
    function updateVol() external;
}
```
```solidity
// src/mocks/MockVol.sol
import {IVolSource} from "../interfaces/IVolSource.sol";
contract MockVol is IVolSource {
    uint256 private _sigma = 0.8e18;
    bool    private _ready = true;
    function setSigma(uint256 s) external { _sigma = s; }
    function setReady(bool r) external { _ready = r; }
    function sigma() external view returns (uint256) { return _sigma; }
    function ready() external view returns (bool) { return _ready; }
    function updateVol() external {}
}
```
In `src/RealizedVol.sol`: add `import {IVolSource} from "./interfaces/IVolSource.sol";` and `contract RealizedVol is IVolSource` (its `sigma()`/`ready()`/`updateVol()` already match; no logic change).

- [ ] **Step 4: Run, verify pass** — `forge test` → whole suite green (additive only; book untouched).

- [ ] **Step 5: Commit**

```bash
git add src/interfaces/IVolSource.sol src/mocks/MockVol.sol src/RealizedVol.sol test/MockVol.t.sol
git commit -m "feat(vol): IVolSource seam + MockVol; RealizedVol implements it (additive)"
```

### Task 4: `_computedMark` + permissionless `accrue(side)`

**Files:**
- Modify: `src/EverlastingBook.sol` (add `_computedMark`; add `accrue`; keep `postMark` for now so the suite still builds)
- Test: `test/Book.accrue.t.sol` (new)

**Interfaces:**
- Consumes: existing `fairMark(Side) → uint256`, `intrinsic(Side) → uint256`, `_utilSurcharge`, `_updateAdaptiveMult`, `sideState`.
- Produces: `_computedMark(Side side) internal view returns (uint256)` = `fairMark` floored at `intrinsic`, PUT capped at `Wput`. `accrue(Side side) external` — permissionless; folds funding from the stored period-start `mark`, refreshes `mark`/`lastIntrinsic`/`lastMarkTime`, folds the adaptive integral, pings `vol.updateVol()`. Emits existing `MarkPosted(side, mark, cumFunding)`.

- [ ] **Step 1: Write failing tests**

```solidity
// test/Book.accrue.t.sol
function test_accrue_setsMarkToComputedFairValue() public {
    mockVol.setSigma(0.8e18);
    oracle.setSpotWad(33e18);          // S=$33
    book.accrue(Side.COVERED_CALL);    // permissionless — no prank
    (uint256 mark,,,,) = book.sideState(uint8(Side.COVERED_CALL));
    assertEq(mark, book.fairMark(Side.COVERED_CALL), "mark == on-chain fair value");
}

function test_accrue_foldsFundingOverElapsedPeriods() public {
    mockVol.setSigma(0.8e18);
    oracle.setSpotWad(33e18);
    book.accrue(Side.COVERED_CALL);
    (uint256 m0,,,,) = book.sideState(uint8(Side.COVERED_CALL));
    vm.warp(block.timestamp + 2 * book.FUNDING_PERIOD());
    book.accrue(Side.COVERED_CALL);
    (,, uint256 cum,,) = book.sideState(uint8(Side.COVERED_CALL));
    // f = m0 - lastIntrinsic(=0 for OTM call) + P(U)(=0 at U=0); cum = f * 2 periods
    assertEq(cum, m0 * 2, "funding = mark * periods for OTM call at U=0");
}

function test_accrue_isPermissionless() public {
    oracle.setSpotWad(33e18);
    vm.prank(address(0xBEEF)); // random caller
    book.accrue(Side.PUT);     // no revert
}
```

- [ ] **Step 2: Run, verify fail** — `forge test --mp test/Book.accrue.t.sol -vv` → FAIL (`accrue` undefined).

- [ ] **Step 3: Implement**

```solidity
/// @notice The on-chain mark for a side: fair value floored at intrinsic (funding→0 there, AUDIT-H),
///         PUT additionally capped at Wput (payout cap). No keeper input.
function _computedMark(Side side) internal view returns (uint256 m) {
    m = fairMark(side);
    uint256 intr = intrinsic(side);
    if (m < intr) m = intr;
    if (side == Side.PUT && m > Wput) m = Wput;
}

/// @notice Permissionless: fold funding since the last accrue (using the stored period-start mark),
///         then refresh the stored mark to the on-chain computed fair value. Anyone may call — no
///         discretion (the mark is a formula). Reverts only if the oracle can't price (spot==0); that
///         blocks openLong (correct — don't open into a dead oracle) but never blocks close/settle,
///         which read the stored mark and never call this.
function accrue(Side side) public {
    SideState storage ss = sideState[uint8(side)];
    uint256 intr = intrinsic(side);
    if (ss.mark != 0) {
        uint256 age = block.timestamp - ss.lastMarkTime;
        uint256 periods = age / FUNDING_PERIOD;
        if (periods > 0) {
            uint256 f = ss.mark >= ss.lastIntrinsic ? ss.mark - ss.lastIntrinsic : 0;
            f += _utilSurcharge(side);                 // P(U), now always-on (UTIL_KAPPA const)
            ss.cumFunding += f * periods;
            _updateAdaptiveMult(side, periods);        // controller (ADAPT_K const)
        }
    }
    ss.mark = _computedMark(side);                     // ← the mark is the market, not a keeper number
    ss.lastIntrinsic = intr;
    ss.lastMarkTime = block.timestamp;
    emit MarkPosted(side, ss.mark, ss.cumFunding);
    if (address(vol) != address(0)) { try vol.updateVol() {} catch {} }
}
```
(Leave `postMark` in place this task so the suite still builds; it is deleted in Task 5.)

- [ ] **Step 4: Run, verify pass** — `forge test --mp test/Book.accrue.t.sol -vv` → PASS.

- [ ] **Step 5: Commit**

```bash
git add src/EverlastingBook.sol test/Book.accrue.t.sol
git commit -m "feat(book): _computedMark + permissionless accrue() (mark = on-chain fair value)"
```

### Task 5: Delete `postMark`/band/deviation, rewire `openLong`, migrate the 13 book test files

**Files:**
- Modify: `src/EverlastingBook.sol` — (a) **ctor**: `vol` → `IVolSource public immutable`, add final ctor param `IVolSource _vol` with `require(address(_vol)!=0)`, delete `setVol`/`VolSet`/`import {RealizedVol}` and replace `RealizedVol` type refs with `IVolSource`; (b) delete `postMark`, `MARK_BAND_BPS`, `MAX_MARK_DEV_BPS`, band block; (c) `openLong` both sides call `accrue(side)` first, drop the `ss.mark>0`/stale-mark guards in favour of a post-accrue `require(ss.mark>0,"no mark")`; keep `keeper` field + `setKeeper` for cover-trigger role but remove keeper-gating from the mark path
- Modify (migrate): `test/Book.put.t.sol`, `test/Book.admin.t.sol`, `test/Book.call.open.t.sol`, `test/Book.call.close.t.sol`, `test/Book.callBacking.t.sol`, `test/Book.evmvault.integration.t.sol`, `test/Book.intrinsic.t.sol`, `test/Book.withdraw.t.sol`, `test/Book.reconcile.t.sol`, `test/Book.invariant.t.sol`, `test/Book.adaptive.t.sol`, `test/UtilPremium.t.sol`
- Delete: `test/Book.markBand.t.sol` (band removed)

**Interfaces:**
- Produces: `EverlastingBook` ctor final arg `IVolSource _vol` (immutable `vol`); `openLong(Side, uint256)` now auto-accrues; `postMark` and `setVol` **removed**. No band/deviation constants.

**Migration rule (apply to every listed test file):**
1. Construct the book with a `MockVol` (`mockVol = new MockVol(); mockVol.setSigma(<σ>);`) passed as the **final ctor arg** (`new EverlastingBook(vault, oracle, keeper, Kput, Wput, Kcall, putCap, callCap, mockVol)`); delete any `book.setVol(...)` call. Set the oracle spot via `oracle.setSpotWad(<S>)`.
2. Replace every `vm.prank(keeper); book.postMark(side, M);` (and bare `book.postMark(side, M)`) with `book.accrue(side);` **after** setting `oracle`/`mockVol` so `fairMark` equals the intended mark. To advance funding, `vm.warp(block.timestamp + n*FUNDING_PERIOD)` **then** `book.accrue(side)`.
3. To create **markGain** (a "winning" close) drive the oracle, not the mark: for CALL raise `S` (`fairMark(CALL)` rises); for PUT lower `S`. Assert PnL against `book.fairMark(side)` / the stored mark read from `sideState`, not a literal.
4. **Delete** `test/Book.markBand.t.sol` entirely (the band is gone) and any `MAX_MARK_DEV_BPS`/`"mark deviation"`/`"mark band"` assertions.
5. In `test/Book.admin.t.sol` remove `setVol`/`setUtilKappa`/`setUMax`/`setAdaptiveParams` tests (Task 6 handles their constant replacements); keep `setKeeper`, `pause`, `transferOwnership`.

Worked example (before → after), `test/Book.call.close.t.sol`:
```solidity
// BEFORE
vm.prank(keeper); book.postMark(Side.COVERED_CALL, 3e18);   // entry mark $3
book.openLong(Side.COVERED_CALL, 0.1e18);
vm.prank(keeper); book.postMark(Side.COVERED_CALL, 5e18);   // ramped to $5 → markGain
book.close(Side.COVERED_CALL);
// AFTER
mockVol.setSigma(0.8e18); oracle.setSpotWad(48e18);         // fairMark(CALL) ≈ $3 at S=$48
book.accrue(Side.COVERED_CALL);
book.openLong(Side.COVERED_CALL, 0.1e18);
oracle.setSpotWad(56e18);                                    // S↑ → fairMark(CALL)↑ → markGain
book.accrue(Side.COVERED_CALL);
book.close(Side.COVERED_CALL);
// assert close paid markGain sourced from the cover sale (unchanged I3 asserts)
```

- [ ] **Step 1: Migrate the tests** per the rule above; delete `Book.markBand.t.sol`.
- [ ] **Step 2: Delete `postMark` + band/deviation** from `EverlastingBook.sol`; make `openLong` call `accrue(side)` first (both branches), then `require(sideState[uint8(side)].mark > 0, "no mark")`; drop the `block.timestamp <= lastMarkTime + MAX_MARK_AGE` stale guard (accrue just refreshed it) and the `MAX_MARK_AGE`/`MARK_BAND_BPS`/`MAX_MARK_DEV_BPS` constants if now unused.
- [ ] **Step 3: Run the full book suite**

Run: `forge test --mp 'test/Book.*' --mp test/UtilPremium.t.sol -vv`
Expected: PASS across all migrated files.

- [ ] **Step 4: Run the whole suite** — `forge test` → all green except the known env fork test.
- [ ] **Step 5: Commit**

```bash
git add src/EverlastingBook.sol test/
git commit -m "feat(book): remove keeper postMark + band/deviation; openLong auto-accrues (autonomous mark)"
```

### Task 6: Hardcode κ / uMax / adaptive gains as constants

**Files:**
- Modify: `src/EverlastingBook.sol` (state vars `utilKappa`/`uMax`/`adaptiveK`/`uStar` → constants `UTIL_KAPPA`/`U_MAX`/`ADAPT_K`/`U_STAR`; delete `setUtilKappa`/`setUMax`/`setAdaptiveParams` + their events; ctor drops their seeding except `adaptiveMult=WAD`)
- Test: `test/UtilPremium.t.sol`, `test/Book.adaptive.t.sol`
- **Ripple:** turning `UTIL_KAPPA` on makes the P(U) surcharge **always-on** (was inert at κ=0). Any book test that asserts exact funding/close numbers at U>0 (e.g. `test/Book.call.close.t.sol`, `test/Book.put.t.sol`, `test/UtilPremium.t.sol`) may shift — run the FULL suite and update the affected numeric assertions. This is expected, not a regression.

**Interfaces:**
- Produces: constants `UTIL_KAPPA = 0.05e18`, `U_MAX = 0.8e18`, `ADAPT_K = 0.02e18`, `U_STAR = 0.5e18` (values chosen conservatively: κ small so P(U) is a gentle surcharge; uMax 80% survivability cap; k well under `MAX_ADAPT_K=0.1e18`). `_utilSurcharge`/`utilization`/`openLong` u-cap/`_updateAdaptiveMult` read the constants.

- [ ] **Step 1: Write/adjust failing tests** — `UtilPremium.t.sol`: assert `_utilSurcharge` now non-zero at U>0 **without** any setter call (P(U) always-on); `openLong` reverts `"u-cap"` when `netWritten` would exceed `U_MAX*cap`. `Book.adaptive.t.sol`: adaptive mult moves after `accrue` over a period with U≠U\* **without** `setAdaptiveParams`.
- [ ] **Step 2: Run, verify fail** — those tests currently rely on setters / inert defaults.
- [ ] **Step 3: Implement** — replace the four state vars with constants, update all references, delete the three setters + `UtilKappaSet`/`UMaxSet`/`AdaptiveParamsSet` events, and the ctor lines that seeded `uMax=WAD`/`uStar=0.5e18` (keep `adaptiveMult[...]=WAD`). Keep `MAX_ADAPT_K` as a documented ceiling comment or delete.
- [ ] **Step 4: Run full suite** — `forge test` → green (except env fork).
- [ ] **Step 5: Commit**

```bash
git add src/EverlastingBook.sol test/
git commit -m "feat(book): hardcode kappa/uMax/adaptive gains as constants (no owner tuning knobs)"
```

### Task 7: Conservation fuzz with the autonomous controller active

**Files:**
- Modify: `test/Book.invariant.t.sol` (handler: replace `postMark` actions with `accrue`; the handler already sets util/adaptive via setters → now they're constants, so drop those handler calls; add a `warp+accrue` action so funding + the adaptive integral fold during the run)

**Interfaces:**
- Consumes: `accrue(Side)`, `openLong`, `close`, `settle`, `deposit`, `withdraw`, `lpDeposit`, `lpWithdraw`.

- [ ] **Step 1: Update the invariant handler** — actions: `deposit`, `openLong`, `warpAndAccrue(side)` (`vm.warp` a random 0–2 periods then `accrue`), `close`, `settle`, `lpDeposit`, `lpWithdraw`. Oracle spot randomized within a sane band each action so `fairMark` varies. Keep the existing conservation assertion `poolUsdc == poolFree + putEscrow + totalCollateral`.
- [ ] **Step 2: Run** — `forge test --mp test/Book.invariant.t.sol` (256×~128k depth per foundry.toml) → **0 reverts**, invariant holds.
- [ ] **Step 3: Commit**

```bash
git add test/Book.invariant.t.sol
git commit -m "test(book): conservation fuzz drives autonomous accrue + always-on P(U)/adaptive"
```

### Task 8: Whole-branch adversarial re-audit (angry persona)

**Files:** none (review only) — findings → follow-up commits.

- [ ] **Step 1: Dispatch an independent opus auditor** over the branch diff with the angry/pessimistic-coder persona. Focus: (a) funding-accrual correctness under the computed mark (period-start rate = stored mark; no under/over-charge; `periods≤2` overflow bound intact via any staleness handling); (b) `accrue` cannot brick `close`/`settle` (they must not call `fairMark`/`accrue`); (c) no owner/keeper path can influence a price anywhere; (d) conservation; (e) `_computedMark` PUT floor/cap correctness; (f) re-derive σ/skew/adaptive scaling. 
- [ ] **Step 2: Triage findings**; fix Criticals/Highs inline (new TDD test per fix); record accepted/deferred with rationale.
- [ ] **Step 3: Commit** each fix; push the branch.

```bash
git push
```

---

## Phase 3 — Redeploy from `main` + autonomous live demo

### Task 9: Update `DeployBook.s.sol` for the immutable-vol ctor

**Files:**
- Modify: `script/DeployBook.s.sol`

- [ ] **Step 1:** Change the deploy to construct `RealizedVol` **before** the book and pass it into the ctor (now the final immutable arg); delete the `book.setVol(vol)` line and any `setUtilKappa/uMax/adaptive` calls (constants now).

```solidity
RealizedVol vol = new RealizedVol(ISpotOracle(address(oracle)));
EverlastingBook book = new EverlastingBook(
    ICoverVault(address(vault)), ISpotOracle(address(oracle)),
    deployer, Kput, Wput, Kcall, putCap, callCap, IVolSource(address(vol))
);
vault.initBook(address(book));
```

- [ ] **Step 2:** `forge build` green; `forge script script/DeployBook.s.sol --rpc-url $HYPEREVM_TESTNET_RPC` (dry-run, no broadcast) executes without revert.
- [ ] **Step 3: Commit**

```bash
git add script/DeployBook.s.sol
git commit -m "chore(deploy): wire RealizedVol via immutable ctor arg (drop setVol/param setters)"
```

### Task 10: Rebuild ops helper + redeploy the stack (big blocks)

**Files:**
- Create: `scratchpad/hl_ops.py` (throwaway; not committed) — HL SDK helpers: `bridge_evm_to_core(amt)`, `spot_send(amt, dest)`, `use_big_blocks(bool)`, `spot_state(addr)`, `bbo()` read.

- [ ] **Step 1:** Rebuild `scratchpad/hl_ops.py` from the anaconda `hyperliquid` SDK (reads `DEPLOYER_PRIVATE_KEY` from `.env`). Verify with a read (`spot_state(0xe7e5)`).
- [ ] **Step 2:** `python3 scratchpad/hl_ops.py use_big_blocks true` for `0xe7e5`.
- [ ] **Step 3:** Deploy:

```bash
forge script script/DeployBook.s.sol:DeployBook --rpc-url $HYPEREVM_TESTNET_RPC \
  --private-key $DEPLOYER_PRIVATE_KEY --broadcast --slow
```
If `--slow` times out (~2 min), read `broadcast/DeployBook.s.sol/998/run-latest.json` and finish `vault.initBook(book)` manually via `cast send`.
- [ ] **Step 4:** Record the 4 new addresses (OracleLib, EvmUsdcCoverVault, EverlastingBook, RealizedVol) in `docs/RUNBOOK-3b.md` and verify wiring via `cast call` (`vault.book()==book`, `book.vol()==vol`, `book.owner/keeper`, `book.Kcall`). Toggle big blocks off.
- [ ] **Step 5: Commit** the runbook address update.

```bash
git add docs/RUNBOOK-3b.md
git commit -m "docs(runbook): autonomous-mark stack live addresses (testnet 998)"
```

### Task 11: Live autonomous covered-call demo (funding-carry) + market-driven cover

**Files:**
- Modify: `docs/RUNBOOK-3b.md` (append the live run)

- [ ] **Step 1:** Fund + seed cover: `hl_ops.py bridge_evm_to_core 13` (0xe7e5 EVM→Core) → `hl_ops.py spot_send 13 <vaultCore>` (activate + fund vault Core float) → keeper `cast send vault "buyCover(uint256,uint256)" 0.2e18 14e6`. Poll `cast call vault "coverHype()(uint256)"` until it rises (async settle) — proves the **market-driven buy crossing the $62.989 ask** with the vault's own float.
- [ ] **Step 2:** LP seed: `usdc.approve(vault)` + `book.lpDeposit(<amt>)`.
- [ ] **Step 3:** `book.accrue(1)` (CALL) → establishes `mark = fairMark(CALL)`; read `book.fairMark(1)` + `sideState`.
- [ ] **Step 4:** Trader: `usdc.approve(vault)` → `book.deposit(1, im)` → `book.openLong(1, 0.1e18)` (cover-gated; auto-accrues). Read the open position.
- [ ] **Step 5:** Wait ≥1h (or a real elapsed period) → `book.accrue(1)` → funding accrues to the pool. Show `pendingFunding(1, trader)` rising.
- [ ] **Step 6:** Trader `book.close(1)` → long pays the accrued funding → **pool/LP earns the carry**. `book.withdraw(1, remaining)`.
- [ ] **Step 7:** Keeper `book.` unwinds cover: `cast send vault "sellCover(uint256)" <coverHype>` (or `emergencyUnwindCover` after pause) → market-driven `bbo.bid` sell into the $33 bid → proves the live cover **sell** path. Verify conservation via `book.poolUsdc()` vs derived ledgers at each step.
- [ ] **Step 8:** Append the run (tx hashes, `coverHype` up/down, funding realized, conservation) to `docs/RUNBOOK-3b.md`. Commit + push.

```bash
git add docs/RUNBOOK-3b.md
git commit -m "docs(runbook): live autonomous covered-call demo — market-driven cover + funding carry"
git push
```

---

## Self-Review

**Spec coverage:** Component A (autonomous mark) → Tasks 4-5. Component B (hardcode params + immutable vol) → Tasks 3, 6. Component C (market-driven cover) → Tasks 1-2. Component D (kept levers) → untouched by design (verified in Task 8 audit). Component E (redeploy) → Tasks 9-10. Component F (demo) → Task 11. Fuzz/audit → Tasks 7-8. All spec sections mapped.

**Placeholder scan:** No "TBD"/"add error handling". Bulk test migration is a **precise mechanical rule with a worked before/after example**, not a placeholder — inlining 300 test edits is neither possible nor useful; the rule is the instruction. Constant values are pinned (κ=0.05e18, uMax=0.8e18, k=0.02e18, u\*=0.5e18, COVER_CROSS_BPS=50).

**Type consistency:** `accrue(Side)`, `_computedMark(Side)`, `fairMark(Side)`, `IVolSource.{sigma,ready,updateVol}`, `buyCover(uint256,uint256)`/`sellCover(uint256)` signatures consistent across tasks. Book ctor final arg `IVolSource _vol` used identically in Task 3 (contract), Task 9 (deploy), and the test migration (Task 5).

**Known deferral:** exact `foundry.toml` fuzz depth for Task 7 is whatever the repo already sets (do not lower it).
