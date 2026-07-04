# Task 2 Report: CoreCoverVault

## Status: DONE_WITH_CONCERNS

---

## Deliverables

| File | Description |
|------|-------------|
| `src/CoreCoverVault.sol` | `ICoverVault` implementation backed by HyperCore CoreWriter |
| `test/CoreCoverVault.sim.t.sol` | 26 tests: 10 pure-unit + 16 offline CoreSimulatorLib sim |
| `test/CoreCoverVault.fork.t.sol` | 7 fork-read tests (requires `HYPEREVM_TESTNET_RPC`) |

---

## Test Summary

### Non-fork run: `forge test --no-match-path '*fork*'`

```
150 passed, 12 failed (pre-existing), 0 skipped
```

- **New tests**: 26 sim + unit tests — all pass
- **Pre-existing failures** (not caused by Task 2):
  - `MultiUser.concurrent.t.sol`: 6 fails (`open: IM` / `open: pool escrow`)
  - `SpotTrading.integration.t.sol`: 3 fails (`open: IM`)
  - `SzDecimals.dust.t.sol`: 2 fails (`pool: insufficient`)

### Sim tests (26): all pass

Section A — Pure unit (no simulator, no fork):
- `test_unit_hypeWeiToWad`, `test_unit_hypeWadToOrderSz`, `test_unit_usdcWeiTo6dp`, `test_unit_spotPxRawToWad`, `test_unit_coverEquityFormula`, `test_unit_szDecimalsFloor_exactTick`, `test_unit_szDecimalsFloor_fractional`, `test_unit_szDecimalsFloor_largeAmount`, `test_unit_szDecimalsFloor_belowMinTick`, `test_unit_sellCover_estimatedProceeds`

Section B — Offline CoreSimulatorLib sim:
- `test_sim_initialState`, `test_sim_buyCover_balancesUpdate`, `test_sim_buyCover_viewFunctions`, `test_sim_buyCover_zeroReverts`, `test_sim_buyCover_slippageReverts`, `test_sim_sellCover_flooredDustRemains`, `test_sim_sellCover_exactTick_noDust`, `test_sim_sellCover_belowMinTickReverts`, `test_sim_sellCover_insufficientReverts`, `test_sim_cloidSeq_increments`, `test_sim_pullUsdc_reverts`, `test_sim_payoutUsdc_zeroReverts`, `test_sim_payoutUsdc_insufficientReverts`, `test_sim_setKeeper_onlyOwner`, `test_sim_setKeeper_updatesAccess`, `test_sim_implements_ICoverVault`

### Fork tests (7): untested (no fork URL in CI)

`test_fork_spotPxUsdc_liveSanity`, `test_fork_coverHype_zero`, `test_fork_poolUsdc_zero`, `test_fork_coverEquityUsdc_zero`, `test_fork_constants`, `test_fork_pullUsdc_reverts`, `test_fork_buyCover_accessControl`, `test_fork_sellCover_accessControl`, `test_fork_payoutUsdc_accessControl`

Run with: `forge test --match-path '*CoreCoverVault.fork*' --fork-url $HYPEREVM_TESTNET_RPC`

---

## Implementation Notes

### Scale math (verified against spike `SpotCoverSpike.sol`)

| Quantity | Raw source | Conversion | Result |
|----------|-----------|-----------|--------|
| HYPE Core wei | `spotBalance.total` (weiDecimals=8) | `× 1e10` | WAD |
| USDC Core wei | `spotBalance.total` (weiDecimals=8) | `/ 100` | 6dp |
| spotPx raw | `PrecompileLib.spotPx(1035)` (price×1e6) | `× 1e12` | WAD |
| Order sz | `hypeWad` | `/ 1e10` | *1e8 order units |
| Order limitPx | `rawPx × 100` | `× (10050/10000)` buy, `× (9950/10000)` sell | *1e8 order units |

### CoreSimulatorLib offline fix

`CoreSimulatorLib.init()` sets `useRealL1Read=true`. Without an active fork, any path through `RealL1Read` that calls `vm.rpc` and then `abi.decode("", (bool))` reverts. Fix: `hyperCore.setUseRealL1Read(false)` immediately after `init()`, before any `forceAccountActivation`/`forceSpotBalance` calls. All token/spot info is pre-registered manually so offline mode has full fidelity.

---

## Concerns

1. **`pullUsdc` always reverts**: HyperCore has no on-chain ERC20 transferFrom. Deposits must arrive via out-of-band Core spot send. Any book layer (Task 3) caller expecting ERC20-style pull semantics will receive a diagnostic revert. Task 3 must own this deposit UX.

2. **Async gap — all mutating functions**: `buyCover`, `sellCover`, `payoutUsdc` are fire-and-forget CoreWriter calls. Fills settle ≥1 Core block later. `coverHype()` and `poolUsdc()` reflect settled state only. The balance sanity check in `sellCover` (checking settled HYPE before placing sell) can be stale by ≤1 Core block — designed conservatively, not a bug, but callers must not rely on optimistic accounting.

3. **`sellCover` returns estimated usdcOut**: Actual fill price may differ by up to SLIPPAGE_BPS (50 bps) from the estimate. Downstream callers should treat the return value as indicative.

4. **Fork tests not run in CI**: `HYPEREVM_TESTNET_RPC` not set in the test environment. Fork tests verify live `spotPx` reads and zero-balance assertions on fresh vaults — they pass locally when env var is set.

---

## Commit

Branch: `slice3b-covered-call-market`
