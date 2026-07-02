# Everlasting HYPE Hedging Suite (Slice 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generalize the everlasting put into one `EverlastingMarket(side, K, W)` contract, add a fully-collateralized capped call (so the venue hedges both directions of a HYPE spot/perp position), and wire the clearinghouse economics (protocol fee on funding carry + opt-in yield-adapter float) — all on testnet, no new unbounded risk.

**Architecture:** Both a put and a capped call are *bounded-payout* instruments. Everywhere Slice 1 used the strike `K` as the pool's per-unit obligation, we substitute `W = max payout per unit` (`PUT: W=K`, `CALL: W=K_hi−K`). The put becomes the `W=K` case, so its audited solvency proof carries over verbatim. Fee and float are additive, opt-in, and by construction cannot touch escrow or trader collateral. Two isolated markets are deployed (one pool each).

**Tech Stack:** Solidity 0.8.35 (Foundry), OpenZeppelin ERC20, `hyper-evm-lib` HyperCore precompiles, TypeScript keeper (ethers v6).

## Global Constraints

- **solc `0.8.35`, `evm_version = cancun`** (verbatim from `foundry.toml`; do not change).
- **`W` = max payout per unit, WAD.** `PUT: W=K`. `CALL: W=K_hi−K`. Every per-unit obligation (escrow, mark upper-guard, intrinsic clamp) keys off `W`, never `K`.
- **Generalize, do not fork.** Refactor `EverlastingPut` → `EverlastingMarket`; the put is a construction case. One contract, one place to fix. Do **not** leave a second drifting copy.
- **Preserve the Slice-1 audit invariants (comments F1–F5)** through the refactor; re-verify each with `W`. The existing test suite is the regression gate — it must stay green.
- **Fee = funding-carry cut only** (no trade fee this slice). Fee is skimmed from pool surplus *after* the trader is paid, floored at available `poolFree` — it can never cause a trader-payout shortfall.
- **Float = 100% protocol, opt-in.** `yieldAdapter == address(0)` ⇒ disabled ⇒ exact Slice-1 behavior. Float deploys **only free pool capital above a reserve**; it **never** sources `poolLocked` or `traderCollateral`. Testnet ships `MockYieldAdapter`/`NullYieldAdapter` only — a real adapter is an audit-gated decision, never shipped here.
- **Isolated pool per market** this slice (shared cross-margin vault is Slice 3).
- **Testnet + MockUSDC only. Never real keys / real funds.** Secrets stay in gitignored `.env`.
- **Commits** follow repo convention (`feat:`/`test:`/`refactor:` + body) and append the two trailers used on this branch (`Co-Authored-By: Claude Opus 4.8 (1M context) …` and `Claude-Session: …`).
- **Codegen offload:** steps tagged **[qwen-ok]** are mechanical — generate with `scripts/qwen.sh -o <out>` (qwen3-coder via Ollama), then Claude reviews the diff before commit. Steps tagged **[claude]** (solvency-critical contract logic, invariants) are authored/verified by Claude directly.

## File Structure

**Created:**
- `src/EverlastingMarket.sol` — generalized bounded market (replaces `EverlastingPut.sol`).
- `src/interfaces/IYieldAdapter.sol` — float venue interface.
- `src/MockYieldAdapter.sol` — testnet adapter, simulated fixed APR.
- `src/NullYieldAdapter.sol` — no-op adapter (holds USDC 1:1), for explicit-disabled tests.
- `test/EverlastingCall.intrinsic.t.sol` — capped-call intrinsic clamp.
- `test/EverlastingCall.lifecycle.t.sol` — call open/funding/close/auto-settle.
- `test/EverlastingCall.invariant.t.sol` — call-market solvency + conservation (spot fuzzed above `K_hi`).
- `test/Fee.t.sol` — funding-fee accounting + owner gates.
- `test/Float.t.sol` — sweep/harvest/ensure-liquidity + float-safety invariants.
- `test/CrossMarket.t.sol` — put + call side-by-side scenario.
- `test/EverlastingCall.fork.t.sol` — call market reads live testnet oracle.

**Modified:**
- All `test/EverlastingPut.*.t.sol` — retarget to `EverlastingMarket(Side.PUT, K, K)` (mechanical).
- `script/Deploy.s.sol` — deploy put + capped call, set fee.
- `keeper/postMark.ts` — post marks for both markets (put basket + call-spread basket).
- `README.md` — status table + hedging-suite note.

**Deleted:**
- `src/EverlastingPut.sol` (content moves to `EverlastingMarket.sol`).

---

### Task 1: Generalize `EverlastingPut` → `EverlastingMarket` (put behavior preserved) [claude]

**Files:**
- Create: `src/EverlastingMarket.sol`
- Delete: `src/EverlastingPut.sol`
- Modify: all `test/EverlastingPut.*.t.sol` (import + constructor), `script/Deploy.s.sol` (import + constructor)

**Interfaces:**
- Produces: `contract EverlastingMarket` with `enum Side { PUT, CALL }`; constructor `(IERC20 usdc, ISpotOracle oracle, Side side, uint256 K, uint256 W, address keeper)`; unchanged public surface otherwise (`K()`, `W()`, `side()`, `poolFree()`, `poolLocked()`, `mark()`, `cumFunding()`, `intrinsicWad()`, `positions()`, `traderCollateral()`, `lpDeposit/lpWithdraw/deposit/withdraw/openLong/postMark/pendingFunding/settle/close`).

- [ ] **Step 1: Create `src/EverlastingMarket.sol`** (put branch implemented; call branch reverts, added in Task 2)

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISpotOracle} from "./interfaces/ISpotOracle.sol";

contract EverlastingMarket {
    enum Side { PUT, CALL }

    IERC20 public immutable usdc;
    ISpotOracle public immutable oracle;
    Side public immutable side;
    uint256 public immutable K;          // strike, WAD
    uint256 public immutable W;          // max payout per unit, WAD (PUT: K; CALL: K_hi-K)
    address public immutable lp;         // sole LP (Slice-1/2) = deployer
    address public keeper;
    uint256 public lastIntrinsic;        // intrinsic sampled at the last postMark (WAD)

    uint256 public poolFree;    // USDC available (in-contract)
    uint256 public poolLocked;  // USDC escrowed vs open positions

    uint256 public constant FUNDING_PERIOD = 3600;
    uint256 public constant MAX_MARK_AGE = 7200;
    uint256 public constant MAX_MARK_DEV_BPS = 2000;

    struct Position { uint256 qty; uint256 entryMark; uint256 entryCumFunding; }
    mapping(address => uint256) public traderCollateral;
    mapping(address => Position) public positions;
    uint256 public mark;           // WAD
    uint256 public lastMarkTime;
    uint256 public cumFunding;     // WAD, funding per unit qty

    constructor(IERC20 _usdc, ISpotOracle _oracle, Side _side, uint256 _K, uint256 _W, address _keeper) {
        require(_W > 0, "W=0");
        usdc = _usdc; oracle = _oracle; side = _side; K = _K; W = _W; keeper = _keeper; lp = msg.sender;
    }

    function intrinsicWad() public view returns (uint256) {
        uint256 s = oracle.spotWad();
        if (side == Side.PUT) {
            uint256 v = s >= K ? 0 : K - s;
            return v > W ? W : v;                 // clamp to max payout (no-op when W==K)
        }
        revert("call: todo");                     // CALL branch implemented in Task 2
    }

    function _toUsdc(uint256 wad) internal pure returns (uint256) { return wad / 1e12; }

    function lpDeposit(uint256 amt) external {
        require(msg.sender == lp, "only LP");
        require(usdc.transferFrom(msg.sender, address(this), amt), "transfer");
        poolFree += amt;
    }
    function lpWithdraw(uint256 amt) external {
        require(msg.sender == lp, "only LP");                 // AUDIT F1
        require(amt <= poolFree, "pool: insufficient free");
        poolFree -= amt;
        require(usdc.transfer(msg.sender, amt), "transfer");
    }
    function deposit(uint256 amt) external {
        require(usdc.transferFrom(msg.sender, address(this), amt), "transfer");
        traderCollateral[msg.sender] += amt;
    }
    function withdraw(uint256 amt) external {
        require(positions[msg.sender].qty == 0, "close first");
        require(amt <= traderCollateral[msg.sender], "insufficient");
        traderCollateral[msg.sender] -= amt;
        require(usdc.transfer(msg.sender, amt), "transfer");
    }

    function _escrowUsdc(uint256 qtyWad) internal view returns (uint256) {
        return _toUsdc(qtyWad * W / 1e18);        // was K; now max payout per unit
    }

    function openLong(uint256 qtyWad) external {
        require(mark > 0, "no mark");
        require(block.timestamp <= lastMarkTime + MAX_MARK_AGE, "stale mark"); // AUDIT F5
        require(positions[msg.sender].qty == 0, "one position");
        uint256 im = _escrowUsdc(qtyWad);                 // IM = qty*W
        require(traderCollateral[msg.sender] >= im, "open: IM");
        require(poolFree >= im, "open: pool escrow");
        poolFree -= im; poolLocked += im;
        positions[msg.sender] = Position(qtyWad, mark, cumFunding);
    }

    event MarkPosted(uint256 mark, uint256 cumFunding);

    function postMark(uint256 newMark) external {
        require(msg.sender == keeper, "only keeper");
        uint256 intrinsic = intrinsicWad();
        require(newMark >= intrinsic, "mark<intrinsic");
        require(newMark <= W, "mark>W");                  // was <= K
        if (mark != 0) {
            uint256 age = block.timestamp - lastMarkTime;
            if (age <= MAX_MARK_AGE) {
                uint256 hi = mark + mark * MAX_MARK_DEV_BPS / 10_000;
                uint256 lo = mark - mark * MAX_MARK_DEV_BPS / 10_000;
                require(newMark <= hi && newMark >= lo, "mark deviation");
                uint256 periods = age / FUNDING_PERIOD;
                if (periods > 0) {
                    uint256 f = mark >= lastIntrinsic ? mark - lastIntrinsic : 0; // AUDIT F3
                    cumFunding += f * periods;
                }
            }
            // else: STALE gap -> recoverable re-seed; skip deviation + funding (AUDIT F5)
        }
        mark = newMark;
        lastMarkTime = block.timestamp;
        lastIntrinsic = intrinsic;
        emit MarkPosted(newMark, cumFunding);
    }

    function pendingFunding(address t) public view returns (uint256) {
        Position memory p = positions[t];
        if (p.qty == 0) return 0;
        return p.qty * (cumFunding - p.entryCumFunding) / 1e18; // WAD
    }

    event Closed(address indexed trader, int256 pnlUsdc);

    function settle(address t) external {
        Position memory p = positions[t];
        require(p.qty > 0, "no position");
        uint256 fundingU = _toUsdc(pendingFunding(t));
        require(fundingU > traderCollateral[t], "solvent");
        _closeFor(t);
    }

    function close() external { _closeFor(msg.sender); }

    function _closeFor(address t) internal {
        Position memory p = positions[t];
        require(p.qty > 0, "no position");
        uint256 fundingWad = p.qty * (cumFunding - p.entryCumFunding) / 1e18; // owed to pool
        int256 markPnlWad = int256(p.qty) * (int256(mark) - int256(p.entryMark)) / 1e18;

        uint256 fundingU = _toUsdc(fundingWad);
        int256 markPnlU = markPnlWad >= 0 ? int256(_toUsdc(uint256(markPnlWad)))
                                          : -int256(_toUsdc(uint256(-markPnlWad)));
        int256 netU = markPnlU - int256(fundingU); // trader delta

        // AUDIT F2: release THIS position's escrow FIRST so poolFree >= escrow >= max gain
        // (g <= qty*(mark-entryMark) <= qty*W = escrow), so the payout require can never false-revert.
        uint256 escrow = _escrowUsdc(p.qty);
        poolLocked -= escrow; poolFree += escrow;

        uint256 col = traderCollateral[t];
        if (netU >= 0) {
            uint256 g = uint256(netU);
            require(poolFree >= g, "pool insolvent"); // holds by construction
            poolFree -= g; col += g;
        } else {
            uint256 l = uint256(-netU);
            if (l > col) l = col;                     // auto-settle floor: never below 0
            col -= l; poolFree += l;
        }

        traderCollateral[t] = col;
        delete positions[t];
        emit Closed(t, netU);
    }
}
```

- [ ] **Step 2: Delete `src/EverlastingPut.sol`**

Run: `git rm src/EverlastingPut.sol`

- [ ] **Step 3: Retarget the existing put tests + deploy script [qwen-ok]**

Mechanical transform in every `test/EverlastingPut.*.t.sol` and `script/Deploy.s.sol`:
- Import line: `import {EverlastingPut} from "../src/EverlastingPut.sol";` → `import {EverlastingMarket} from "../src/EverlastingMarket.sol";`
- Type name `EverlastingPut` → `EverlastingMarket` (variable names like `put` may stay).
- Constructor: `new EverlastingPut(usdc, oracle, <K>, <keeper>)` → `new EverlastingMarket(usdc, oracle, EverlastingMarket.Side.PUT, <K>, <K>, <keeper>)` (pass `W == K`).
- In `test/EverlastingPut.invariant.t.sol`, the handler bound uses the strike as the mark ceiling: change `put.K()` to `put.W()` on the two `bound(...)` lines (equal for the put, but correct-by-meaning).

Generate the codemod with qwen, then Claude reviews every diff before Step 4:
```bash
scripts/qwen.sh -o /tmp/codemod.txt "Rewrite these Foundry test files: replace type EverlastingPut with EverlastingMarket, update the import path to ../src/EverlastingMarket.sol, and change every `new EverlastingPut(usdc, oracle, K, keeper)` to `new EverlastingMarket(usdc, oracle, EverlastingMarket.Side.PUT, K, K, keeper)` keeping the original K expression. Output unified diffs only." test/EverlastingPut.open.t.sol test/EverlastingPut.math.t.sol test/EverlastingPut.pool.t.sol test/EverlastingPut.funding.t.sol test/EverlastingPut.close.t.sol test/EverlastingPut.autosettle.t.sol test/EverlastingPut.invariant.t.sol
```

- [ ] **Step 4: Run the full existing suite — regression gate**

Run: `export PATH="$HOME/.foundry/bin:$PATH" && forge test --no-match-contract Fork`
Expected: PASS — the same 25 tests green (put behavior identical because `W==K`). If any fail, the refactor changed put behavior; fix before proceeding.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: generalize EverlastingPut -> EverlastingMarket(side,K,W)"
```

---

### Task 2: Capped-call intrinsic + call lifecycle [claude]

**Files:**
- Modify: `src/EverlastingMarket.sol:intrinsicWad` (implement CALL branch)
- Create: `test/EverlastingCall.intrinsic.t.sol`, `test/EverlastingCall.lifecycle.t.sol`

**Interfaces:**
- Consumes: `EverlastingMarket` (Task 1).
- Produces: CALL intrinsic `clamp(S−K, 0, W)`; a fully-working call market (escrow/funding/close already `W`-generalized in Task 1).

- [ ] **Step 1: Write the failing intrinsic test** — `test/EverlastingCall.intrinsic.t.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {Test} from "forge-std/Test.sol";
import {EverlastingMarket} from "../src/EverlastingMarket.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockOracle} from "../src/MockOracle.sol";

contract CallIntrinsicTest is Test {
    EverlastingMarket call_; MockUSDC usdc; MockOracle oracle;
    uint256 constant K = 48e18; uint256 constant KHI = 54e18; uint256 constant W = KHI - K; // 6e18
    function setUp() public {
        usdc = new MockUSDC(); oracle = new MockOracle();
        call_ = new EverlastingMarket(usdc, oracle, EverlastingMarket.Side.CALL, K, W, address(this));
    }
    function test_call_otm_isZero() public { oracle.set(45e18); assertEq(call_.intrinsicWad(), 0); }
    function test_call_atk_isZero() public { oracle.set(48e18); assertEq(call_.intrinsicWad(), 0); }
    function test_call_inRamp() public { oracle.set(50e18); assertEq(call_.intrinsicWad(), 2e18); }
    function test_call_cappedAtW_atKhi() public { oracle.set(54e18); assertEq(call_.intrinsicWad(), W); }
    function test_call_cappedAtW_aboveKhi() public { oracle.set(80e18); assertEq(call_.intrinsicWad(), W); }
}
```

- [ ] **Step 2: Run — verify it fails**

Run: `forge test --match-contract CallIntrinsicTest -vv`
Expected: FAIL with revert `call: todo`.

- [ ] **Step 3: Implement the CALL branch** — replace `revert("call: todo");` in `intrinsicWad()`:

```solidity
        // CALL: clamp(S - K, 0, W)
        uint256 v = s <= K ? 0 : s - K;
        return v > W ? W : v;
```

- [ ] **Step 4: Run — verify pass**

Run: `forge test --match-contract CallIntrinsicTest -vv`
Expected: PASS (5 tests).

- [ ] **Step 5: Write the call lifecycle test** — `test/EverlastingCall.lifecycle.t.sol` (mirrors the put open/funding/close/auto-settle on the call config; escrow is `qty*W`)

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {Test} from "forge-std/Test.sol";
import {EverlastingMarket} from "../src/EverlastingMarket.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockOracle} from "../src/MockOracle.sol";

contract CallLifecycleTest is Test {
    EverlastingMarket c; MockUSDC usdc; MockOracle oracle;
    uint256 constant K = 48e18; uint256 constant W = 6e18; // K_hi = 54
    address trader = address(0xA11CE);
    function setUp() public {
        usdc = new MockUSDC(); oracle = new MockOracle(); oracle.set(48e18);
        c = new EverlastingMarket(usdc, oracle, EverlastingMarket.Side.CALL, K, W, address(this));
        usdc.mint(address(this), 100_000e6); usdc.approve(address(c), type(uint256).max);
        c.lpDeposit(100_000e6);
        c.postMark(1e18);                       // time value; mark <= W holds
        usdc.mint(trader, 100_000e6);
        vm.prank(trader); usdc.approve(address(c), type(uint256).max);
    }
    function test_open_locksEscrowEqualsW() public {
        vm.startPrank(trader);
        c.deposit(6e6);                          // IM for qty=1 call = W = $6
        c.openLong(1e18);
        vm.stopPrank();
        assertEq(c.poolLocked(), 6e6);           // escrow = qty*W
        (uint256 qty,,) = c.positions(trader); assertEq(qty, 1e18);
    }
    function test_funding_accruesMarkMinusIntrinsic() public {
        vm.startPrank(trader); c.deposit(6e6); c.openLong(1e18); vm.stopPrank();
        // one funding period elapses, spot flat (intrinsic 0), mark 1e18 -> funding = 1e18/unit
        vm.warp(block.timestamp + 3600);
        c.postMark(1e18);
        assertEq(c.pendingFunding(trader), 1e18);
    }
    function test_close_paysMarkGainBoundedByEscrow() public {
        vm.startPrank(trader); c.deposit(6e6); c.openLong(1e18); vm.stopPrank();
        // mark rises to cap; trader closes. gain <= escrow (W). No funding elapsed.
        vm.warp(block.timestamp + 1);
        c.postMark(6e18);                        // mark == W (upper guard boundary)
        uint256 before = c.traderCollateral(trader);
        vm.prank(trader); c.close();
        assertGt(c.traderCollateral(trader), before);        // realized mark gain
        assertLe(c.traderCollateral(trader) - before, 6e6);  // bounded by escrow=W
    }
}
```

- [ ] **Step 6: Run — verify pass** (call machine works via the Task-1 generalization)

Run: `forge test --match-contract CallLifecycleTest -vv`
Expected: PASS (3 tests). If `test_close_*` reverts on `postMark(6e18)`, confirm the `mark<=W` guard uses `W` not `K`.

- [ ] **Step 7: Commit**

```bash
git add src/EverlastingMarket.sol test/EverlastingCall.intrinsic.t.sol test/EverlastingCall.lifecycle.t.sol
git commit -m "feat: capped everlasting call (clamp S-K to [0,W]) + lifecycle tests"
```

---

### Task 3: Call-market solvency invariant [claude]

**Files:**
- Create: `test/EverlastingCall.invariant.t.sol`

**Interfaces:**
- Consumes: `EverlastingMarket` CALL config.
- Produces: fuzzed solvency + conservation proof for the call, **including spot above `K_hi`** (intrinsic capped at `W`).

- [ ] **Step 1: Write the invariant harness** (adapts `test/EverlastingPut.invariant.t.sol`; bounds mark by `W`, fuzzes spot through and above `K_hi`)

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {Test} from "forge-std/Test.sol";
import {EverlastingMarket} from "../src/EverlastingMarket.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockOracle} from "../src/MockOracle.sol";

contract CallHandler is Test {
    EverlastingMarket public c; MockUSDC public usdc; MockOracle public oracle;
    address[] public actors; uint256 public marksPosted;
    constructor(EverlastingMarket _c, MockUSDC _u, MockOracle _o, address[] memory _a){ c=_c; usdc=_u; oracle=_o; actors=_a; }
    function _actor(uint256 seed) internal view returns (address){ return actors[seed % actors.length]; }
    function postMark(uint256 m) external {
        uint256 lo = c.intrinsicWad();
        if (c.mark() != 0) {
            uint256 dhi = c.mark() + c.mark()*2000/10000;
            uint256 dlo = c.mark() - c.mark()*2000/10000;
            lo = dlo > lo ? dlo : lo;
            m = bound(m, lo, dhi < c.W() ? dhi : c.W());
        } else { m = bound(m, lo, c.W()); }
        vm.warp(block.timestamp + 3600);
        try c.postMark(m) { marksPosted++; } catch {}
    }
    function moveSpot(uint256 s) external { oracle.set(bound(s, 1e18, 120e18)); } // spans above K_hi=54
    function deposit(uint256 seed, uint256 amt) external {
        address a=_actor(seed); amt=bound(amt,0,1_000e6);
        usdc.mint(a, amt); vm.startPrank(a); usdc.approve(address(c), amt);
        try c.deposit(amt) {} catch {} vm.stopPrank();
    }
    function openLong(uint256 seed, uint256 qty) external { address a=_actor(seed); qty=bound(qty,0,5e18); vm.prank(a); try c.openLong(qty) {} catch {} }
    function closePos(uint256 seed) external { address a=_actor(seed); vm.prank(a); try c.close() {} catch {} }
    function settlePos(uint256 seed) external { address a=_actor(seed); try c.settle(a) {} catch {} }
}

contract CallInvariantTest is Test {
    EverlastingMarket c; MockUSDC usdc; MockOracle oracle; CallHandler h;
    address[] actors;
    function setUp() public {
        usdc = new MockUSDC(); oracle = new MockOracle(); oracle.set(48e18);
        actors.push(address(0xA11CE)); actors.push(address(0xB0B)); actors.push(address(0xCA11));
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        c = new EverlastingMarket(usdc, oracle, EverlastingMarket.Side.CALL, 48e18, 6e18, predicted);
        h = new CallHandler(c, usdc, oracle, actors);
        require(address(h) == predicted, "keeper wiring");
        usdc.mint(address(this), 1_000_000e6); usdc.approve(address(c), type(uint256).max);
        c.lpDeposit(500_000e6);
        targetContract(address(h));
    }
    function invariant_solvency() public view {
        uint256 sum = c.traderCollateral(address(this));
        for (uint256 i=0;i<actors.length;i++) sum += c.traderCollateral(actors[i]);
        assertEq(usdc.balanceOf(address(c)), c.poolFree() + c.poolLocked() + sum);
    }
    function afterInvariant() public view { assertGt(h.marksPosted(), 0, "no marks -> vacuous"); }
}
```

- [ ] **Step 2: Run — verify pass**

Run: `forge test --match-contract CallInvariantTest -vv`
Expected: PASS — `invariant_solvency` holds across runs; `marksPosted > 0`.

- [ ] **Step 3: Commit**

```bash
git add test/EverlastingCall.invariant.t.sol
git commit -m "test: call-market solvency invariant (spot fuzzed above K_hi)"
```

---

### Task 4: Protocol fee — funding-carry cut [claude]

**Files:**
- Modify: `src/EverlastingMarket.sol` (add fee state, owner, setter, skim in `_closeFor`, `withdrawFees`)
- Create: `test/Fee.t.sol`

**Interfaces:**
- Produces: `owner()`, `protocolFeeBps()`, `feeAccrued()`, `setProtocolFeeBps(uint256)`, `withdrawFees(address,uint256)`. Conservation becomes `balanceOf(market) == poolFree + poolLocked + Σtrader + feeAccrued`.

- [ ] **Step 1: Add fee state + owner** — after `address public keeper;` add:

```solidity
    address public owner;
    uint256 public protocolFeeBps;   // cut of funding carry, <= MAX_FEE_BPS
    uint256 public feeAccrued;       // USDC owed to protocol
    uint256 public constant MAX_FEE_BPS = 2000;
```
In the constructor body add `owner = msg.sender;`.

- [ ] **Step 2: Add setter + withdrawal** — after the constructor:

```solidity
    function setProtocolFeeBps(uint256 bps) external {
        require(msg.sender == owner, "only owner");
        require(bps <= MAX_FEE_BPS, "fee too high");
        protocolFeeBps = bps;
    }
    function withdrawFees(address to, uint256 amt) external {
        require(msg.sender == owner, "only owner");
        require(amt <= feeAccrued, "fee: insufficient");
        feeAccrued -= amt;
        require(usdc.transfer(to, amt), "transfer");
    }
```

- [ ] **Step 3: Skim the fee in `_closeFor`** — immediately before `traderCollateral[t] = col;` insert:

```solidity
        // Protocol fee = cut of funding carry, taken from pool surplus AFTER the trader is
        // paid, floored at poolFree so it can never cause a trader-payout shortfall.
        if (protocolFeeBps > 0 && fundingU > 0) {
            uint256 feeU = fundingU * protocolFeeBps / 10_000;
            if (feeU > poolFree) feeU = poolFree;
            poolFree -= feeU; feeAccrued += feeU;
        }
```

- [ ] **Step 4: Write the fee test** — `test/Fee.t.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {Test} from "forge-std/Test.sol";
import {EverlastingMarket} from "../src/EverlastingMarket.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockOracle} from "../src/MockOracle.sol";

contract FeeTest is Test {
    EverlastingMarket p; MockUSDC usdc; MockOracle oracle;
    address trader = address(0xA11CE);
    function setUp() public {
        usdc = new MockUSDC(); oracle = new MockOracle(); oracle.set(48e18);
        p = new EverlastingMarket(usdc, oracle, EverlastingMarket.Side.PUT, 48e18, 48e18, address(this));
        usdc.mint(address(this), 1_000_000e6); usdc.approve(address(p), type(uint256).max);
        p.lpDeposit(500_000e6);
        p.setProtocolFeeBps(1000);               // 10%
        p.postMark(6e18);
        usdc.mint(trader, 100_000e6); vm.prank(trader); usdc.approve(address(p), type(uint256).max);
    }
    function test_setFee_ownerOnly() public {
        vm.prank(trader); vm.expectRevert(bytes("only owner")); p.setProtocolFeeBps(500);
    }
    function test_setFee_capEnforced() public {
        vm.expectRevert(bytes("fee too high")); p.setProtocolFeeBps(2001);
    }
    function test_fee_takes10pctOfFunding_onClose() public {
        vm.startPrank(trader); p.deposit(48e6); p.openLong(1e18); vm.stopPrank();
        // accrue 1 period of funding: f = mark - lastIntrinsic = 6 - 0 = 6 per unit
        vm.warp(block.timestamp + 3600); p.postMark(6e18);
        uint256 fundingU = 6e6;                  // qty=1 * 6 wad -> $6
        vm.prank(trader); p.close();
        assertEq(p.feeAccrued(), fundingU * 1000 / 10_000);  // $0.60
    }
    function test_conservation_includesFee() public {
        vm.startPrank(trader); p.deposit(48e6); p.openLong(1e18); vm.stopPrank();
        vm.warp(block.timestamp + 3600); p.postMark(6e18);
        vm.prank(trader); p.close();
        uint256 sum = p.traderCollateral(trader) + p.traderCollateral(address(this));
        assertEq(usdc.balanceOf(address(p)), p.poolFree() + p.poolLocked() + sum + p.feeAccrued());
    }
    function test_withdrawFees_ownerOnly() public {
        test_fee_takes10pctOfFunding_onClose();
        vm.prank(trader); vm.expectRevert(bytes("only owner")); p.withdrawFees(trader, 1);
        uint256 fa = p.feeAccrued(); p.withdrawFees(address(this), fa);
        assertEq(p.feeAccrued(), 0);
    }
}
```

- [ ] **Step 5: Run — verify pass, then re-run full suite (fee off by default keeps Slice-1 green)**

Run: `forge test --match-contract FeeTest -vv`
Expected: PASS (5 tests).
Run: `forge test --no-match-contract Fork`
Expected: PASS — all prior tests still green (fee defaults to 0, so the put/call invariants' `balanceOf == poolFree+poolLocked+Σtrader` still holds with `feeAccrued==0`).

- [ ] **Step 6: Commit**

```bash
git add src/EverlastingMarket.sol test/Fee.t.sol
git commit -m "feat: protocol fee as funding-carry cut (owner-gated, solvency-safe skim)"
```

---

### Task 5: Float — yield-adapter seam [claude]

**Files:**
- Create: `src/interfaces/IYieldAdapter.sol`, `src/MockYieldAdapter.sol`, `src/NullYieldAdapter.sol`
- Modify: `src/EverlastingMarket.sol` (adapter wiring, sweep/harvest/ensure-liquidity)
- Create: `test/Float.t.sol`

**Interfaces:**
- Produces: `IYieldAdapter { deposit(uint256); withdraw(uint256); balance() view returns(uint256); }`; on `EverlastingMarket`: `yieldAdapter()`, `reserveBps()`, `deployedToYield()`, `setYieldAdapter(address)`, `setReserveBps(uint256)`, `sweepToYield()`, `harvest()`. Invariant: `poolLocked + Σtrader` never leaves the contract.

- [ ] **Step 1: Create the interface** — `src/interfaces/IYieldAdapter.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
interface IYieldAdapter {
    function deposit(uint256 amt) external;               // pulls USDC from caller
    function withdraw(uint256 amt) external;              // returns USDC to caller
    function balance() external view returns (uint256);   // principal + accrued, for the caller
}
```

- [ ] **Step 2: Create the mock adapters [qwen-ok]** — `src/MockYieldAdapter.sol` (owner-funded fixed accrual to simulate yield) and `src/NullYieldAdapter.sol` (1:1 hold)

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IYieldAdapter} from "./interfaces/IYieldAdapter.sol";

// Testnet-only: simulates yield by letting anyone `accrue()` extra MockUSDC that was pre-funded.
contract MockYieldAdapter is IYieldAdapter {
    IERC20 public immutable usdc; address public immutable market;
    uint256 public principal;    // owed back to `market`
    constructor(IERC20 _usdc, address _market){ usdc=_usdc; market=_market; }
    function deposit(uint256 amt) external {
        require(msg.sender == market, "only market");
        require(usdc.transferFrom(msg.sender, address(this), amt), "transfer");
        principal += amt;
    }
    function withdraw(uint256 amt) external {
        require(msg.sender == market, "only market");
        require(amt <= usdc.balanceOf(address(this)), "insufficient");
        if (amt > principal) principal = 0; else principal -= amt;   // withdrawing yield first is fine
        require(usdc.transfer(market, amt), "transfer");
    }
    function balance() external view returns (uint256){ return usdc.balanceOf(address(this)); }
    // test helper: simulate interest, funded by whoever calls (mint + transfer in the test)
    function accrue(uint256 amt) external { require(usdc.transferFrom(msg.sender, address(this), amt), "transfer"); }
}
```
```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IYieldAdapter} from "./interfaces/IYieldAdapter.sol";
contract NullYieldAdapter is IYieldAdapter {
    IERC20 public immutable usdc; address public immutable market;
    constructor(IERC20 _usdc, address _market){ usdc=_usdc; market=_market; }
    function deposit(uint256 amt) external { require(msg.sender==market,"only market"); require(usdc.transferFrom(msg.sender,address(this),amt),"transfer"); }
    function withdraw(uint256 amt) external { require(msg.sender==market,"only market"); require(usdc.transfer(market,amt),"transfer"); }
    function balance() external view returns (uint256){ return usdc.balanceOf(address(this)); }
}
```

- [ ] **Step 3: Wire the adapter into `EverlastingMarket`** — add state after `feeAccrued`:

```solidity
    address public yieldAdapter;      // address(0) => float disabled (Slice-1 behavior)
    uint256 public reserveBps = 2000; // keep >=20% of free capital liquid in-contract
    uint256 public deployedToYield;   // principal currently at the adapter (USDC)
```
Add imports at top: `import {IYieldAdapter} from "./interfaces/IYieldAdapter.sol";`
Add owner setters + float ops (place after `withdrawFees`):

```solidity
    function setYieldAdapter(address a) external {
        require(msg.sender == owner, "only owner");
        require(deployedToYield == 0, "unwind first");   // switch only when nothing is out
        yieldAdapter = a;
    }
    function setReserveBps(uint256 bps) external {
        require(msg.sender == owner, "only owner");
        require(bps <= 10_000, "bps");
        reserveBps = bps;
    }
    // Push free capital above the reserve out to yield. Never touches poolLocked/traderCollateral.
    function sweepToYield() external {
        require(yieldAdapter != address(0), "no adapter");
        uint256 reserve = poolFree * reserveBps / 10_000;
        require(poolFree > reserve, "nothing to sweep");
        uint256 amt = poolFree - reserve;
        poolFree -= amt; deployedToYield += amt;
        require(usdc.approve(yieldAdapter, amt), "approve");
        IYieldAdapter(yieldAdapter).deposit(amt);
    }
    // Realize adapter gains (balance - principal) to the protocol fee bucket.
    function harvest() external {
        require(yieldAdapter != address(0), "no adapter");
        uint256 bal = IYieldAdapter(yieldAdapter).balance();
        if (bal > deployedToYield) {
            uint256 gain = bal - deployedToYield;
            IYieldAdapter(yieldAdapter).withdraw(gain);   // yield returns to contract
            feeAccrued += gain;                            // 100% protocol (per spec default)
        }
    }
    // Pull `need` USDC back from yield into poolFree if in-contract free is short.
    function _ensureLiquidity(uint256 need) internal {
        if (poolFree >= need || yieldAdapter == address(0)) return;
        uint256 pull = need - poolFree;
        if (pull > deployedToYield) pull = deployedToYield;
        if (pull == 0) return;
        deployedToYield -= pull; poolFree += pull;
        IYieldAdapter(yieldAdapter).withdraw(pull);
    }
```
Add `_ensureLiquidity` calls before the two places that spend free capital:
- In `lpWithdraw`, change the guard to draw on total free and top up first:
  ```solidity
      require(amt <= poolFree + deployedToYield, "pool: insufficient free");
      _ensureLiquidity(amt);
      require(amt <= poolFree, "pool: illiquid");
  ```
- In `openLong`, before `require(poolFree >= im, "open: pool escrow");` insert:
  ```solidity
      _ensureLiquidity(im);
  ```
(The trader-payout path in `_closeFor` releases this position's escrow into `poolFree` first, so `g <= escrow <= poolFree` already holds without a pull.)

- [ ] **Step 4: Write the float tests** — `test/Float.t.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {Test} from "forge-std/Test.sol";
import {EverlastingMarket} from "../src/EverlastingMarket.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockOracle} from "../src/MockOracle.sol";
import {MockYieldAdapter} from "../src/MockYieldAdapter.sol";

contract FloatTest is Test {
    EverlastingMarket p; MockUSDC usdc; MockOracle oracle; MockYieldAdapter ya;
    address trader = address(0xA11CE);
    function setUp() public {
        usdc = new MockUSDC(); oracle = new MockOracle(); oracle.set(48e18);
        p = new EverlastingMarket(usdc, oracle, EverlastingMarket.Side.PUT, 48e18, 48e18, address(this));
        ya = new MockYieldAdapter(usdc, address(p));
        usdc.mint(address(this), 2_000_000e6); usdc.approve(address(p), type(uint256).max);
        p.lpDeposit(100_000e6); p.postMark(6e18);
        p.setYieldAdapter(address(ya));
        usdc.mint(trader, 100_000e6); vm.prank(trader); usdc.approve(address(p), type(uint256).max);
    }
    function test_sweep_movesFreeAboveReserve() public {
        p.sweepToYield();
        assertEq(p.poolFree(), 100_000e6 * 2000 / 10_000);       // 20% reserve stays
        assertEq(p.deployedToYield(), 100_000e6 * 8000 / 10_000);// 80% out
        assertEq(ya.balance(), p.deployedToYield());
    }
    function test_floatNeverTouchesLockedOrTrader() public {
        vm.startPrank(trader); p.deposit(48e6); p.openLong(1e18); vm.stopPrank();  // locks $48 escrow
        p.sweepToYield();
        // locked escrow + trader collateral remain fully in-contract:
        assertGe(usdc.balanceOf(address(p)), p.poolLocked() + p.traderCollateral(trader));
    }
    function test_harvest_routesYieldToFee() public {
        p.sweepToYield();
        usdc.mint(address(this), 500e6); usdc.approve(address(ya), 500e6); ya.accrue(500e6); // +$500 "interest"
        p.harvest();
        assertEq(p.feeAccrued(), 500e6);
        assertEq(ya.balance(), p.deployedToYield());             // only principal remains out
    }
    function test_ensureLiquidity_onLpWithdraw() public {
        p.sweepToYield();                                         // most capital out at yield
        p.lpWithdraw(90_000e6);                                   // exceeds in-contract poolFree -> pulls back
        assertEq(usdc.balanceOf(address(this)), 2_000_000e6 - 100_000e6 + 90_000e6);
    }
    function test_conservation_withFloat() public {
        vm.startPrank(trader); p.deposit(48e6); p.openLong(1e18); vm.stopPrank();
        p.sweepToYield();
        uint256 sum = p.traderCollateral(trader) + p.traderCollateral(address(this));
        // in-contract conservation (deployedToYield left the contract with poolFree):
        assertEq(usdc.balanceOf(address(p)), p.poolFree() + p.poolLocked() + sum + p.feeAccrued());
        assertGe(ya.balance(), p.deployedToYield());             // yield >= 0
    }
}
```

- [ ] **Step 5: Run — verify pass, then full suite (adapter unset elsewhere keeps Slice-1 green)**

Run: `forge test --match-contract FloatTest -vv`
Expected: PASS (5 tests).
Run: `forge test --no-match-contract Fork`
Expected: PASS — all prior tests green (`yieldAdapter==address(0)` ⇒ `_ensureLiquidity` no-ops, `deployedToYield==0`).

- [ ] **Step 6: Commit**

```bash
git add src/interfaces/IYieldAdapter.sol src/MockYieldAdapter.sol src/NullYieldAdapter.sol src/EverlastingMarket.sol test/Float.t.sol
git commit -m "feat: opt-in yield-adapter float (sweep/harvest/ensure-liquidity, protocol-only)"
```

---

### Task 6: Cross-market scenario [claude]

**Files:**
- Create: `test/CrossMarket.t.sol`

- [ ] **Step 1: Write the scenario** — one LP-funded put + one call, a trader hedges both, funding accrues, both close; balances reconcile.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {Test} from "forge-std/Test.sol";
import {EverlastingMarket} from "../src/EverlastingMarket.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockOracle} from "../src/MockOracle.sol";

contract CrossMarketTest is Test {
    EverlastingMarket put; EverlastingMarket call_; MockUSDC usdc; MockOracle oracle;
    address trader = address(0xA11CE);
    function setUp() public {
        usdc = new MockUSDC(); oracle = new MockOracle(); oracle.set(48e18);
        put  = new EverlastingMarket(usdc, oracle, EverlastingMarket.Side.PUT, 48e18, 48e18, address(this));
        call_= new EverlastingMarket(usdc, oracle, EverlastingMarket.Side.CALL, 48e18, 6e18, address(this));
        usdc.mint(address(this), 2_000_000e6); usdc.approve(address(put), type(uint256).max); usdc.approve(address(call_), type(uint256).max);
        put.lpDeposit(500_000e6); call_.lpDeposit(500_000e6);
        put.postMark(6e18); call_.postMark(1e18);
        usdc.mint(trader, 200_000e6);
        vm.startPrank(trader); usdc.approve(address(put), type(uint256).max); usdc.approve(address(call_), type(uint256).max); vm.stopPrank();
    }
    function test_hedgeBothDirections_isolatedPools() public {
        vm.startPrank(trader);
        put.deposit(48e6);  put.openLong(1e18);     // downside hedge
        call_.deposit(6e6); call_.openLong(1e18);   // upside hedge (capped)
        vm.stopPrank();
        // one funding period
        vm.warp(block.timestamp + 3600); put.postMark(6e18); call_.postMark(1e18);
        vm.startPrank(trader); put.close(); call_.close(); vm.stopPrank();
        // each market conserves independently (isolated pools)
        uint256 sP = put.traderCollateral(trader) + put.traderCollateral(address(this));
        uint256 sC = call_.traderCollateral(trader) + call_.traderCollateral(address(this));
        assertEq(usdc.balanceOf(address(put)),  put.poolFree()  + put.poolLocked()  + sP + put.feeAccrued());
        assertEq(usdc.balanceOf(address(call_)),call_.poolFree()+ call_.poolLocked()+ sC + call_.feeAccrued());
    }
}
```

- [ ] **Step 2: Run — verify pass**

Run: `forge test --match-contract CrossMarketTest -vv`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add test/CrossMarket.t.sol
git commit -m "test: cross-market put+call hedge scenario, isolated-pool conservation"
```

---

### Task 7: Deploy script — two markets + fee [claude]

**Files:**
- Modify: `script/Deploy.s.sol`
- Modify: `docs/RUNBOOK.md` (new env vars)

**Interfaces:**
- Consumes envs: `DEPLOYER_PRIVATE_KEY`, `KEEPER_PRIVATE_KEY`, `STRIKE_K`, `STRIKE_K_HI`, `PROTOCOL_FEE_BPS`.

- [ ] **Step 1: Rewrite `script/Deploy.s.sol:run()`**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {Script, console2} from "forge-std/Script.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {OracleLib} from "../src/OracleLib.sol";
import {EverlastingMarket} from "../src/EverlastingMarket.sol";

contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address keeper = vm.addr(vm.envUint("KEEPER_PRIVATE_KEY"));
        uint256 K   = vm.envUint("STRIKE_K");        // wad, computed off-chain (see RUNBOOK)
        uint256 KHI = vm.envUint("STRIKE_K_HI");     // wad, call upper strike; W = KHI - K
        uint256 feeBps = vm.envUint("PROTOCOL_FEE_BPS");
        require(KHI > K, "K_HI<=K");
        vm.startBroadcast(pk);
        MockUSDC usdc = new MockUSDC();
        OracleLib oracle = new OracleLib();
        EverlastingMarket put  = new EverlastingMarket(usdc, oracle, EverlastingMarket.Side.PUT,  K, K,        keeper);
        EverlastingMarket call_= new EverlastingMarket(usdc, oracle, EverlastingMarket.Side.CALL, K, KHI - K,  keeper);
        put.setProtocolFeeBps(feeBps);
        call_.setProtocolFeeBps(feeBps);
        vm.stopBroadcast();
        console2.log("MockUSDC", address(usdc));
        console2.log("OracleLib", address(oracle));
        console2.log("PUT",  address(put));
        console2.log("CALL", address(call_));
        console2.log("K(wad)", K); console2.log("K_HI(wad)", KHI); console2.log("feeBps", feeBps);
    }
}
```

- [ ] **Step 2: Build — verify it compiles**

Run: `forge build`
Expected: compiles clean.

- [ ] **Step 3: Document envs** — append to `docs/RUNBOOK.md` the new vars `STRIKE_K_HI`, `PROTOCOL_FEE_BPS`, and note two market addresses are now emitted (`PUT`, `CALL`). [qwen-ok]

- [ ] **Step 4: Commit**

```bash
git add script/Deploy.s.sol docs/RUNBOOK.md
git commit -m "feat: deploy put + capped call markets with protocol fee"
```

---

### Task 8: Keeper — post both marks (put basket + call-spread basket) [claude]

**Files:**
- Modify: `keeper/postMark.ts`

**Interfaces:**
- Consumes envs: `PUT_MARKET_ADDRESS`, `CALL_MARKET_ADDRESS`, `SIGMA`, `HYPEREVM_TESTNET_RPC`, `KEEPER_PRIVATE_KEY`.
- Uses contract getters `K()`, `W()`, `side()` (0=PUT,1=CALL), `intrinsicWad()`, `oracle()`, `postMark(uint256)`.

- [ ] **Step 1: Generalize the keeper to price by side [qwen-ok, Claude reviews the math]**

Replace `keeper/postMark.ts` body: add `bsCall`, derive the call-spread basket, and loop over both market addresses.

```typescript
import { ethers } from "ethers";
// PUT  mark = Σ 2^-i · BS_put(K, τ_i)
// CALL mark = Σ 2^-i · [BS_call(K, τ_i) − BS_call(K_hi, τ_i)]   (vertical spread, bounded by W)
const RPC = process.env.HYPEREVM_TESTNET_RPC!;
const KEEPER_PK = process.env.KEEPER_PRIVATE_KEY!;
const SIGMA = Number(process.env.SIGMA ?? "0.9");
const N = 12, PERIOD = 3600, YEAR = 31_536_000;
const MARKETS = [process.env.PUT_MARKET_ADDRESS!, process.env.CALL_MARKET_ADDRESS!].filter(Boolean);
const ABI = [
  "function K() view returns (uint256)",
  "function W() view returns (uint256)",
  "function side() view returns (uint8)",
  "function intrinsicWad() view returns (uint256)",
  "function oracle() view returns (address)",
  "function postMark(uint256) external",
];
const OABI = ["function spotWad() view returns (uint256)"];

function normCdf(x: number){ const t=1/(1+0.2316419*Math.abs(x)); const d=0.3989423*Math.exp(-x*x/2);
  let p=d*t*(0.3193815+t*(-0.3565638+t*(1.781478+t*(-1.821256+t*1.330274)))); return x>0?1-p:p; }
function bsPut(S:number,K:number,sig:number,tau:number){ if(tau<=0)return Math.max(K-S,0);
  const d1=(Math.log(S/K)+0.5*sig*sig*tau)/(sig*Math.sqrt(tau)); const d2=d1-sig*Math.sqrt(tau);
  return K*normCdf(-d2)-S*normCdf(-d1); }
function bsCall(S:number,K:number,sig:number,tau:number){ if(tau<=0)return Math.max(S-K,0);
  const d1=(Math.log(S/K)+0.5*sig*sig*tau)/(sig*Math.sqrt(tau)); const d2=d1-sig*Math.sqrt(tau);
  return S*normCdf(d1)-K*normCdf(d2); }

async function postOne(addr:string, provider:ethers.Provider, wallet:ethers.Wallet){
  const m = new ethers.Contract(addr, ABI, wallet);
  const side = Number(await m.side());                 // 0 PUT, 1 CALL
  const K = Number(ethers.formatUnits(await m.K(), 18));
  const W = Number(ethers.formatUnits(await m.W(), 18));
  const KHI = K + W;                                   // CALL upper strike
  const oracle = new ethers.Contract(await m.oracle(), OABI, provider);
  const S = Number(ethers.formatUnits(await oracle.spotWad(), 18));
  let basket = 0;
  for (let i=1;i<=N;i++){ const tau=i*PERIOD/YEAR;
    basket += Math.pow(2,-i) * (side===0 ? bsPut(S,K,SIGMA,tau) : (bsCall(S,K,SIGMA,tau)-bsCall(S,KHI,SIGMA,tau))); }
  const intrinsic = side===0 ? Math.max(K-S,0) : Math.min(Math.max(S-K,0), W);
  let mark = Math.max(basket, intrinsic);              // mark >= intrinsic
  mark = Math.min(mark, W);                            // mark <= W
  const markWad = ethers.parseUnits(mark.toFixed(12), 18);
  const tx = await m.postMark(markWad);
  console.log(`postMark side=${side} S=${S} K=${K} W=${W} mark=${mark} tx=${tx.hash}`);
  await tx.wait();
}
async function main(){
  const p = new ethers.JsonRpcProvider(RPC);
  const w = new ethers.Wallet(KEEPER_PK, p);
  for (const a of MARKETS) await postOne(a, p, w);
}
main().catch(e=>{ console.error(e); process.exit(1); });
```

- [ ] **Step 2: Type-check the keeper**

Run: `cd keeper && npx tsc --noEmit`
Expected: no errors. (If `keeper/package.json` lacks a tsconfig, add `"strict": true` type-check per its README.)

- [ ] **Step 3: Commit**

```bash
git add keeper/postMark.ts
git commit -m "feat: keeper posts put basket + call-spread basket for both markets"
```

---

### Task 9: Call fork test + README/docs update [claude]

**Files:**
- Create: `test/EverlastingCall.fork.t.sol`
- Modify: `README.md`

- [ ] **Step 1: Write the fork test** (reads the live testnet oracle; mirrors `test/OracleLib.fork.t.sol` setup — reuse its RPC/env pattern). Assert call intrinsic clamps to `W` when the live spot is far above `K_hi`, and is `0` when spot ≤ `K`.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {Test} from "forge-std/Test.sol";
import {EverlastingMarket} from "../src/EverlastingMarket.sol";
import {OracleLib} from "../src/OracleLib.sol";
import {MockUSDC} from "../src/MockUSDC.sol";

// Live fork: requires HYPEREVM_TESTNET_RPC. Run: forge test --match-contract CallForkTest --fork-url $HYPEREVM_TESTNET_RPC -vv
contract CallForkTest is Test {
    function test_call_intrinsic_readsLiveOracle_andClamps() public {
        OracleLib oracle = new OracleLib();
        uint256 s = oracle.spotWad();
        require(s > 0, "no live px");
        MockUSDC usdc = new MockUSDC();
        // strike far below spot so the call is deep ITM -> intrinsic must clamp to W
        uint256 K = s / 2; uint256 W = 1e18;
        EverlastingMarket c = new EverlastingMarket(usdc, oracle, EverlastingMarket.Side.CALL, K, W, address(this));
        assertEq(c.intrinsicWad(), W);         // deep ITM -> capped
        // strike far above spot -> OTM -> 0
        EverlastingMarket c2 = new EverlastingMarket(usdc, oracle, EverlastingMarket.Side.CALL, s * 2, W, address(this));
        assertEq(c2.intrinsicWad(), 0);
    }
}
```

- [ ] **Step 2: Run the fork test**

Run: `set -a; source .env; set +a; forge test --match-contract CallForkTest --fork-url $HYPEREVM_TESTNET_RPC -vv`
Expected: PASS (needs network + RPC env).

- [ ] **Step 3: Update `README.md`** — flip the status table to show Slice 2 (capped call + fee + float) and add a one-line "hedging use" note (put hedges longs; capped call hedges shorts up to `K_hi`). [qwen-ok]

- [ ] **Step 4: Run the whole local suite once more**

Run: `forge test --no-match-contract Fork`
Expected: PASS — full suite (put + call + fee + float + cross-market) green.

- [ ] **Step 5: Commit**

```bash
git add test/EverlastingCall.fork.t.sol README.md
git commit -m "test: call fork oracle read + docs: Slice-2 hedging suite status"
```

---

## Self-Review

**Spec coverage** (checked against `2026-07-02-everlasting-hype-hedging-suite-design.md`):
- §4 `W`-generalization → Task 1. CALL intrinsic → Task 2. Solvency proof survives (`g ≤ qty·W`) → Task 3 invariant.
- §5.1 funding-carry fee → Task 4. §5.2 float seam (Mock/Null, sweep/harvest/ensure-liquidity, protocol-only, never touches locked/trader) → Task 5.
- §6 keeper posts both baskets → Task 8. §7 invariants (solvency, conservation incl. `feeAccrued`, float-safety) → Tasks 3/4/5. §8 hedging recipes → README (Task 9).
- §9 testing (call unit/invariant, fee, float, cross-market, fork) → Tasks 2/3/4/5/6/9.
- §11 isolated pools → Task 6 asserts per-market conservation. §12 params (`K_hi`, `protocolFeeBps`, `reserveBps`) → Tasks 7 (deploy) + defaults in contract.
- Deferred correctly (not in plan): uncapped calls, margin, liquidation, perp hedger, shared vault, multi-strike ladder, mainnet/audit.

**Placeholder scan:** no TBD/TODO; every code step shows full code; the only in-contract `revert("call: todo")` is intentional (Task 1 → resolved Task 2).

**Type consistency:** `Side`, `K`, `W`, `_escrowUsdc`, `intrinsicWad`, `feeAccrued`, `protocolFeeBps`, `deployedToYield`, `yieldAdapter`, `sweepToYield`, `harvest`, `_ensureLiquidity` used consistently across tasks; keeper getters (`K/W/side/intrinsicWad/oracle/postMark`) match the contract surface; deploy envs (`STRIKE_K/STRIKE_K_HI/PROTOCOL_FEE_BPS`) match RUNBOOK (Task 7).

**Open audit note (carried from spec §10):** the fee skim and float `_ensureLiquidity` sit on the solvency path — the F2/F3 argument is preserved by construction (fee floored at `poolFree` after payout; float only moves free-above-reserve and tops up before spends), and Tasks 3–6 assert conservation with fee+float on. A dedicated re-audit of `_closeFor` with both features enabled is a pre-mainnet gate (out of scope for this testnet slice).
