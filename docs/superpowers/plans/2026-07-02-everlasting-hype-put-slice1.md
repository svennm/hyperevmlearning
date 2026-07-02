# Everlasting HYPE Put — Slice 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a peer-to-pool, fully-collateralized **everlasting HYPE put** on HyperEVM testnet — traders go long, the pool writes, funding = `mark − intrinsic` settles hourly off the live HYPE oracle.

**Architecture:** One market contract (`EverlastingPut`) custodies USDC, tracks an LP pool and per-trader margin/positions, reads the HYPE oracle via `hyper-evm-lib`'s `PrecompileLib`, and accrues funding through a cumulative-funding index (perp-style, no per-trader iteration). A keeper posts the mark hourly under on-chain guards. Puts have bounded payoff (`≤ K`), so the pool is provably solvent with no hedge and no liquidation engine — solvency edge cases resolve via penalty-free **auto-settle**.

**Tech Stack:** Solidity 0.8.35, Foundry (forge/cast/anvil), `hyper-evm-lib` (`@hyper-evm-lib/src/PrecompileLib.sol`), OpenZeppelin ERC-20 (transitive via hyper-evm-lib), a TypeScript/Node keeper (ethers v6).

## Global Constraints

- Solc **0.8.35**, `evm_version = "cancun"`, optimizer on (200 runs). Copy verbatim into `foundry.toml`.
- HYPE oracle: `PrecompileLib` perp index **135**, `szDecimals = 2`. Spot(WAD) = `oraclePx(135) * 10^(12 + szDecimals)` = `raw * 1e14`.
- Fixed-point: prices, strike, qty, mark, funding in **WAD (1e18)**. Collateral token = **MockUSDC (6 dp)**. Convert WAD→USDC by `/1e12`.
- Funding period = **3600 s**. Guards: `mark ≥ intrinsic`, `mark ≤ K`, `age ≤ MAX_MARK_AGE (2h)`, `|Δmark| ≤ MAX_MARK_DEV_BPS (2000 = 20%)`.
- Never commit secrets. Deploy/keeper read keys from gitignored `.env` (throwaway testnet key only).
- Files < 500 lines, one responsibility each. TDD: failing test → run-fail → implement → run-pass → commit.

---

## Slice-1 Economic Model (read before coding)

- **Instrument:** everlasting put on HYPE, single strike `K`. `intrinsic = max(K − S, 0)`, bounded by `K`.
- **Sides:** pool (LPs) is the sole **writer/short**; traders are **long only** (Slice-1). Trader shorts + calls = later slices.
- **Swap mechanics (no upfront premium):** open `qty` at current `mark` → record `entryMark`. Two cash-flow channels:
  - **Funding** (hourly): long pays pool `qty·(mark − intrinsic)`. Accrued via a global `cumFunding` index; a position owes `qty·(cumFunding − entryCumFunding)`.
  - **Mark PnL** (on close): `qty·(closeMark − entryMark)`, signed; pool is the counterparty.
- **Collateralization (conservative, provably solvent):** on open, trader posts IM = `qty·K` and the pool locks escrow = `qty·K`. Since `0 ≤ mark ≤ K` for a put, `qty·K` dominates both the trader's max downside (`mark→0`) and the pool's max payout (`mark→K`). Over-collateralized on purpose; real margin is Slice-2.
- **No liquidation → auto-settle:** anyone may call `settle(trader)` to close a position whose margin can't cover owed funding, at current mark, no penalty.
- **Solvency invariant (asserted in tests):** `usdc.balanceOf(market) == poolFree + poolLocked + Σ traderCollateral` at all times.
- **Rounding:** WAD→USDC truncation (`/1e12`) rounds funding/PnL down toward the pool (≤1e-6 USDC dust per close) — pool-favorable, never creates value.
- **Access control:** only the deploying `lp` may `lpDeposit`/`lpWithdraw`; only `keeper` may `postMark`; `close`/`settle` are permissionless (exits never blocked).

---

## File Structure

| File | Responsibility |
|---|---|
| `foundry.toml` | Compiler/config (Task 1) |
| `remappings.txt` | Explicit remaps (Task 1) |
| `src/MockUSDC.sol` | Testnet ERC-20 collateral, 6 dp, open `mint` |
| `src/OracleLib.sol` | HYPE oracle read → WAD spot; `intrinsic(K)` helper |
| `src/interfaces/ISpotOracle.sol` | `spotWad()` interface (lets tests inject a mock spot) |
| `src/MockOracle.sol` | Test-only `ISpotOracle` with settable spot |
| `src/EverlastingPut.sol` | Market: pool + trader accounting, funding index, open/close/auto-settle, postMark |
| `script/Deploy.s.sol` | Deploy MockUSDC + oracle wiring + EverlastingPut from `.env` |
| `test/*.t.sol` | Unit + invariant + fork tests |
| `keeper/postMark.ts` | Off-chain hourly mark poster (basket price) |

---

## Task 1: Repo config + clean scaffold

**Files:**
- Modify: `foundry.toml`
- Create: `remappings.txt`
- Delete: `src/Counter.sol`, `test/Counter.t.sol`, `script/Counter.s.sol`

- [ ] **Step 1: Write `foundry.toml`**
```toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
solc = "0.8.35"
evm_version = "cancun"
optimizer = true
optimizer_runs = 200
fs_permissions = [{ access = "read", path = "./"}]

[rpc_endpoints]
hyperevm_testnet = "${HYPEREVM_TESTNET_RPC}"
```

- [ ] **Step 2: Write `remappings.txt`**
```
@hyper-evm-lib/=lib/hyper-evm-lib/
forge-std/=lib/forge-std/src/
@openzeppelin/contracts/=lib/hyper-evm-lib/lib/openzeppelin-contracts/contracts/
```

- [ ] **Step 3: Remove default template files**
```bash
rm -f src/Counter.sol test/Counter.t.sol script/Counter.s.sol
```

- [ ] **Step 4: Verify build**

Run: `forge build`
Expected: `Compiler run successful!` (compiles lib only; no src yet)

- [ ] **Step 5: Commit**
```bash
git add foundry.toml remappings.txt
git commit -m "chore: pin solc 0.8.35/cancun, remappings, drop template"
```

---

## Task 2: MockUSDC

**Files:**
- Create: `src/MockUSDC.sol`
- Test: `test/MockUSDC.t.sol`

**Interfaces — Produces:** `MockUSDC is IERC20` with `decimals()==6`, `mint(address,uint256)`.

- [ ] **Step 1: Failing test** — `test/MockUSDC.t.sol`
```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../src/MockUSDC.sol";

contract MockUSDCTest is Test {
    MockUSDC usdc;
    function setUp() public { usdc = new MockUSDC(); }

    function test_decimalsIsSix() public view { assertEq(usdc.decimals(), 6); }
    function test_mint() public {
        usdc.mint(address(0xBEEF), 1_000_000); // 1 USDC
        assertEq(usdc.balanceOf(address(0xBEEF)), 1_000_000);
    }
}
```

- [ ] **Step 2: Run — expect fail** — `forge test --match-contract MockUSDCTest` → FAIL (no `MockUSDC`).

- [ ] **Step 3: Implement** — `src/MockUSDC.sol`
```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USD Coin", "mUSDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}
```

- [ ] **Step 4: Run — expect pass** — `forge test --match-contract MockUSDCTest` → PASS.

- [ ] **Step 5: Commit** — `git add src/MockUSDC.sol test/MockUSDC.t.sol && git commit -m "feat: MockUSDC 6dp collateral"`

---

## Task 3: Oracle abstraction + live read

**Files:**
- Create: `src/interfaces/ISpotOracle.sol`, `src/OracleLib.sol`, `src/MockOracle.sol`
- Test: `test/OracleLib.fork.t.sol`, `test/MockOracle.t.sol`

**Interfaces — Produces:** `ISpotOracle.spotWad() returns (uint256)`; `OracleLib` implements it via `PrecompileLib.oraclePx(135)`; `MockOracle` implements it with a settable value.

- [ ] **Step 1: Interface** — `src/interfaces/ISpotOracle.sol`
```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
interface ISpotOracle { function spotWad() external view returns (uint256); }
```

- [ ] **Step 2: MockOracle + test** — `src/MockOracle.sol`
```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {ISpotOracle} from "./interfaces/ISpotOracle.sol";
contract MockOracle is ISpotOracle {
    uint256 private _px;
    function set(uint256 pxWad) external { _px = pxWad; }
    function spotWad() external view returns (uint256) { return _px; }
}
```
`test/MockOracle.t.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {Test} from "forge-std/Test.sol";
import {MockOracle} from "../src/MockOracle.sol";
contract MockOracleTest is Test {
    function test_setGet() public {
        MockOracle o = new MockOracle();
        o.set(48e18);
        assertEq(o.spotWad(), 48e18);
    }
}
```

- [ ] **Step 3: Run — expect fail then pass** — `forge test --match-contract MockOracleTest` (FAIL → implement → PASS).

- [ ] **Step 4: Implement OracleLib** — `src/OracleLib.sol`
```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {ISpotOracle} from "./interfaces/ISpotOracle.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";

/// Reads the HYPE perp oracle (index 135, szDecimals 2) and returns WAD USD.
contract OracleLib is ISpotOracle {
    uint32 public constant HYPE_INDEX = 135;
    uint256 public constant SCALE = 1e14; // 10^(12 + szDecimals=2)

    function spotWad() external view returns (uint256) {
        uint256 raw = uint256(PrecompileLib.oraclePx(HYPE_INDEX));
        require(raw > 0, "oracle zero");
        return raw * SCALE;
    }
}
```

- [ ] **Step 5: Fork test against live testnet** — `test/OracleLib.fork.t.sol`
```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {Test} from "forge-std/Test.sol";
import {OracleLib} from "../src/OracleLib.sol";

contract OracleLibForkTest is Test {
    function test_readsLiveHypePrice() public {
        vm.createSelectFork(vm.envString("HYPEREVM_TESTNET_RPC"));
        OracleLib o = new OracleLib();
        uint256 s = o.spotWad();
        // sanity band: $1 .. $10,000 in WAD
        assertGt(s, 1e18);
        assertLt(s, 10_000e18);
        emit log_named_decimal_uint("HYPE spot", s, 18);
    }
}
```

- [ ] **Step 6: Run fork test** — `forge test --match-contract OracleLibForkTest -vv`
Expected: PASS, logs `HYPE spot ~48`.

- [ ] **Step 7: Commit** — `git add src/OracleLib.sol src/MockOracle.sol src/interfaces test/OracleLib.fork.t.sol test/MockOracle.t.sol && git commit -m "feat: HYPE oracle read (WAD) + mock + fork test"`

---

## Task 4: EverlastingPut skeleton + intrinsic/mark math

**Files:**
- Create: `src/EverlastingPut.sol`
- Test: `test/EverlastingPut.math.t.sol`

**Interfaces — Consumes:** `ISpotOracle`, `IERC20 (MockUSDC)`. **Produces:** constructor `(IERC20 usdc, ISpotOracle oracle, uint256 K, address keeper)`; `intrinsicWad() view`; constants `FUNDING_PERIOD=3600`, `MAX_MARK_AGE=7200`, `MAX_MARK_DEV_BPS=2000`; `_toUsdc(uint256 wad) internal pure`.

- [ ] **Step 1: Failing test** — `test/EverlastingPut.math.t.sol`
```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {Test} from "forge-std/Test.sol";
import {EverlastingPut} from "../src/EverlastingPut.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockOracle} from "../src/MockOracle.sol";

contract PutMathTest is Test {
    EverlastingPut put; MockUSDC usdc; MockOracle oracle;
    function setUp() public {
        usdc = new MockUSDC(); oracle = new MockOracle();
        put = new EverlastingPut(usdc, oracle, 48e18, address(this)); // K=$48
    }
    function test_intrinsic_ITM() public { oracle.set(40e18); assertEq(put.intrinsicWad(), 8e18); }
    function test_intrinsic_OTM() public { oracle.set(60e18); assertEq(put.intrinsicWad(), 0); }
}
```

- [ ] **Step 2: Run — expect fail** — `forge test --match-contract PutMathTest` → FAIL.

- [ ] **Step 3: Implement skeleton** — `src/EverlastingPut.sol`
```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISpotOracle} from "./interfaces/ISpotOracle.sol";

contract EverlastingPut {
    IERC20 public immutable usdc;
    ISpotOracle public immutable oracle;
    uint256 public immutable K;          // strike, WAD
    address public immutable lp;         // sole LP (Slice-1) = deployer
    address public keeper;
    uint256 public lastIntrinsic;        // intrinsic sampled at the last postMark (WAD)

    uint256 public constant FUNDING_PERIOD = 3600;
    uint256 public constant MAX_MARK_AGE = 7200;
    uint256 public constant MAX_MARK_DEV_BPS = 2000;

    constructor(IERC20 _usdc, ISpotOracle _oracle, uint256 _K, address _keeper) {
        usdc = _usdc; oracle = _oracle; K = _K; keeper = _keeper; lp = msg.sender;
    }

    function intrinsicWad() public view returns (uint256) {
        uint256 s = oracle.spotWad();
        return s >= K ? 0 : K - s;
    }

    function _toUsdc(uint256 wad) internal pure returns (uint256) { return wad / 1e12; }
}
```

- [ ] **Step 4: Run — expect pass** — `forge test --match-contract PutMathTest` → PASS.

- [ ] **Step 5: Commit** — `git add src/EverlastingPut.sol test/EverlastingPut.math.t.sol && git commit -m "feat: EverlastingPut skeleton + intrinsic"`

---

## Task 5: LP pool deposit/withdraw

**Files:** Modify `src/EverlastingPut.sol`; Test `test/EverlastingPut.pool.t.sol`

**Interfaces — Produces:** `poolFree`/`poolLocked` (uint256, USDC); `lpDeposit(uint256)`, `lpWithdraw(uint256)`.

- [ ] **Step 1: Failing test**
```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {Test} from "forge-std/Test.sol";
import {EverlastingPut} from "../src/EverlastingPut.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockOracle} from "../src/MockOracle.sol";

contract PutPoolTest is Test {
    EverlastingPut put; MockUSDC usdc; MockOracle oracle;
    function setUp() public {
        usdc = new MockUSDC(); oracle = new MockOracle();
        put = new EverlastingPut(usdc, oracle, 48e18, address(this));
        usdc.mint(address(this), 1_000e6);
        usdc.approve(address(put), type(uint256).max);
    }
    function test_lpDepositWithdraw() public {
        put.lpDeposit(500e6);
        assertEq(put.poolFree(), 500e6);
        assertEq(usdc.balanceOf(address(put)), 500e6);
        put.lpWithdraw(200e6);
        assertEq(put.poolFree(), 300e6);
        assertEq(usdc.balanceOf(address(this)), 700e6);
    }
    function test_lpWithdraw_revertsOverFree() public {
        put.lpDeposit(100e6);
        vm.expectRevert(bytes("pool: insufficient free"));
        put.lpWithdraw(200e6);
    }
}
```

- [ ] **Step 2: Run — expect fail** → FAIL.

- [ ] **Step 3: Implement (add to EverlastingPut)**
```solidity
    uint256 public poolFree;    // USDC available
    uint256 public poolLocked;  // USDC escrowed vs open positions

    function lpDeposit(uint256 amt) external {
        require(msg.sender == lp, "only LP");
        require(usdc.transferFrom(msg.sender, address(this), amt), "transfer");
        poolFree += amt;
    }
    function lpWithdraw(uint256 amt) external {
        require(msg.sender == lp, "only LP");                 // AUDIT F1: gate pool withdrawals
        require(amt <= poolFree, "pool: insufficient free");
        poolFree -= amt;
        require(usdc.transfer(msg.sender, amt), "transfer");
    }
```
> NOTE (Slice-1): a single LP for simplicity — no LP shares. Multi-LP share accounting is Slice-2.

- [ ] **Step 4: Run — expect pass** → PASS.

- [ ] **Step 5: Commit** — `git commit -am "feat: single-LP pool deposit/withdraw"`

---

## Task 6: Trader margin + openLong (escrow + IM)

**Files:** Modify `src/EverlastingPut.sol`; Test `test/EverlastingPut.open.t.sol`

**Interfaces — Produces:** `struct Position { uint256 qty; uint256 entryMark; uint256 entryCumFunding; }`; `mapping(address=>uint256) traderCollateral`; `mapping(address=>Position) positions`; `deposit(uint256)`, `withdraw(uint256)`, `openLong(uint256 qtyWad)`; internal `_escrowUsdc(uint256 qtyWad) = _toUsdc(qtyWad*K/1e18)`. Reads `mark` (added Task 7 — for Task 6 use a settable `mark` via a temporary `setMarkForTest`, replaced in Task 7).

> To keep tasks independently testable, Task 6 introduces `uint256 public mark;` and a guarded `postMark` stub `_setMark(uint256)` used internally; Task 7 replaces the stub with the full guarded keeper entrypoint + funding index. `openLong` requires `mark > 0`.

- [ ] **Step 1: Failing test**
```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {Test} from "forge-std/Test.sol";
import {EverlastingPut} from "../src/EverlastingPut.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockOracle} from "../src/MockOracle.sol";

contract PutOpenTest is Test {
    EverlastingPut put; MockUSDC usdc; MockOracle oracle;
    address trader = address(0xA11CE);
    function setUp() public {
        usdc = new MockUSDC(); oracle = new MockOracle();
        put = new EverlastingPut(usdc, oracle, 48e18, address(this));
        oracle.set(48e18);
        // LP funds pool
        usdc.mint(address(this), 100_000e6); usdc.approve(address(put), type(uint256).max);
        put.lpDeposit(100_000e6);
        put.postMark(6e18); // ATM put ~ time value; mark ≤ K holds
        // trader funds margin
        usdc.mint(trader, 100_000e6);
        vm.prank(trader); usdc.approve(address(put), type(uint256).max);
    }
    function test_openLong_locksEscrowAndIM() public {
        vm.startPrank(trader);
        put.deposit(48e6);           // IM for qty=1 put = K = $48
        put.openLong(1e18);          // 1 put
        vm.stopPrank();
        (uint256 qty,,) = put.positions(trader);
        assertEq(qty, 1e18);
        assertEq(put.poolLocked(), 48e6);          // escrow = qty*K
        assertEq(put.traderCollateral(trader), 48e6);
    }
    function test_openLong_revertsInsufficientIM() public {
        vm.startPrank(trader);
        put.deposit(10e6);
        vm.expectRevert(bytes("open: IM"));
        put.openLong(1e18);
        vm.stopPrank();
    }
    function test_openLong_revertsPoolCantCover() public {
        // drain pool below one escrow
        put.lpWithdraw(100_000e6 - 10e6);
        vm.startPrank(trader);
        put.deposit(48e6);
        vm.expectRevert(bytes("open: pool escrow"));
        put.openLong(1e18);
        vm.stopPrank();
    }

    // AUDIT F6: trader withdraw() coverage
    function test_withdraw_happyPath() public {
        vm.startPrank(trader);
        put.deposit(48e6);
        put.withdraw(20e6);
        vm.stopPrank();
        assertEq(put.traderCollateral(trader), 28e6);
        assertEq(usdc.balanceOf(trader), 100_000e6 - 48e6 + 20e6);
    }
    function test_withdraw_revertsWithOpenPosition() public {
        vm.startPrank(trader);
        put.deposit(48e6);
        put.openLong(1e18);
        vm.expectRevert(bytes("close first"));
        put.withdraw(1e6);
        vm.stopPrank();
    }
    function test_withdraw_revertsInsufficient() public {
        vm.startPrank(trader);
        put.deposit(10e6);
        vm.expectRevert(bytes("insufficient"));
        put.withdraw(20e6);
        vm.stopPrank();
    }

    // AUDIT F5: opens are paused while the mark is stale (close/settle are NOT gated)
    function test_openLong_revertsWhenMarkStale() public {
        vm.warp(block.timestamp + put.MAX_MARK_AGE() + 1);
        vm.startPrank(trader);
        put.deposit(48e6);
        vm.expectRevert(bytes("stale mark"));
        put.openLong(1e18);
        vm.stopPrank();
    }
}
```

- [ ] **Step 2: Run — expect fail** → FAIL.

- [ ] **Step 3: Implement**
```solidity
    struct Position { uint256 qty; uint256 entryMark; uint256 entryCumFunding; }
    mapping(address => uint256) public traderCollateral;
    mapping(address => Position) public positions;
    uint256 public mark;              // WAD
    uint256 public lastMarkTime;
    uint256 public cumFunding;        // WAD, funding per unit qty (Task 7 advances it)

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
        return _toUsdc(qtyWad * K / 1e18);
    }
    function openLong(uint256 qtyWad) external {
        require(mark > 0, "no mark");
        require(block.timestamp <= lastMarkTime + MAX_MARK_AGE, "stale mark"); // AUDIT: pause opens when stale
        require(positions[msg.sender].qty == 0, "one position"); // Slice-1: no add/scale
        uint256 im = _escrowUsdc(qtyWad);                 // IM = qty*K
        require(traderCollateral[msg.sender] >= im, "open: IM");
        require(poolFree >= im, "open: pool escrow");
        poolFree -= im; poolLocked += im;
        positions[msg.sender] = Position(qtyWad, mark, cumFunding);
    }

    // temporary in Task 6; replaced by guarded keeper entrypoint in Task 7
    function postMark(uint256 newMark) external { mark = newMark; lastMarkTime = block.timestamp; }
```

- [ ] **Step 4: Run — expect pass** → PASS.

- [ ] **Step 5: Commit** — `git commit -am "feat: trader margin + openLong with escrow/IM"`

---

## Task 7: Guarded postMark + funding index

**Files:** Modify `src/EverlastingPut.sol`; Test `test/EverlastingPut.funding.t.sol`

**Interfaces — Produces:** `postMark(uint256 newMark)` (keeper-only, guarded; advances `cumFunding` by `(prevMark − prevIntrinsic)` — the contemporaneous start-of-period pair via `lastIntrinsic` — once per elapsed period; after a `> MAX_MARK_AGE` gap it re-seeds without funding); `pendingFunding(address) view returns (uint256)`; event `MarkPosted(uint256 mark, uint256 cumFunding)`.

- [ ] **Step 1: Failing test**
```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {Test} from "forge-std/Test.sol";
import {EverlastingPut} from "../src/EverlastingPut.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockOracle} from "../src/MockOracle.sol";

contract PutFundingTest is Test {
    EverlastingPut put; MockUSDC usdc; MockOracle oracle;
    function setUp() public {
        usdc = new MockUSDC(); oracle = new MockOracle();
        put = new EverlastingPut(usdc, oracle, 48e18, address(this));
        oracle.set(48e18);
    }
    function test_guard_markBelowIntrinsicReverts() public {
        oracle.set(40e18); // intrinsic = 8
        vm.expectRevert(bytes("mark<intrinsic"));
        put.postMark(5e18);
    }
    function test_guard_markAboveKReverts() public {
        vm.expectRevert(bytes("mark>K"));
        put.postMark(49e18);
    }
    function test_guard_deviationReverts() public {
        put.postMark(6e18);
        vm.warp(block.timestamp + 3600);
        vm.expectRevert(bytes("mark deviation"));
        put.postMark(9e18); // +50% > 20%
    }
    function test_guard_onlyKeeper() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(bytes("only keeper"));
        put.postMark(6e18);
    }
    function test_cumFundingAdvances() public {
        put.postMark(6e18);                 // establishes mark, no elapsed period yet
        uint256 c0 = put.cumFunding();
        vm.warp(block.timestamp + 3600);
        put.postMark(6e18);                 // one period: funding += (6 - 0) = 6e18
        assertEq(put.cumFunding(), c0 + 6e18);
    }

    // AUDIT F5: a >MAX_MARK_AGE keeper gap must be recoverable and must NOT back-charge funding
    function test_stale_recoversWithoutFunding() public {
        put.postMark(6e18);
        vm.warp(block.timestamp + put.MAX_MARK_AGE() + 1);
        uint256 c = put.cumFunding();
        put.postMark(6e18);                 // re-seeds; no funding accrued over the un-observed gap
        assertEq(put.cumFunding(), c);
        assertEq(put.mark(), 6e18);
    }
}
```

- [ ] **Step 2: Run — expect fail** → FAIL (old `postMark` is unguarded).

- [ ] **Step 3: Implement — replace the Task-6 `postMark` stub**
```solidity
    event MarkPosted(uint256 mark, uint256 cumFunding);

    function postMark(uint256 newMark) external {
        require(msg.sender == keeper, "only keeper");
        uint256 intrinsic = intrinsicWad();
        require(newMark >= intrinsic, "mark<intrinsic");   // always-on bounds
        require(newMark <= K, "mark>K");
        if (mark != 0) {
            uint256 age = block.timestamp - lastMarkTime;
            if (age <= MAX_MARK_AGE) {
                // FRESH: enforce deviation + accrue funding for elapsed periods.
                uint256 hi = mark + mark * MAX_MARK_DEV_BPS / 10_000;
                uint256 lo = mark - mark * MAX_MARK_DEV_BPS / 10_000;
                require(newMark <= hi && newMark >= lo, "mark deviation");
                uint256 periods = age / FUNDING_PERIOD;
                if (periods > 0) {
                    // AUDIT F3: contemporaneous start-of-period pair (mark & lastIntrinsic both from prior post)
                    uint256 f = mark >= lastIntrinsic ? mark - lastIntrinsic : 0; // time value per unit
                    cumFunding += f * periods;
                }
            }
            // else: STALE gap (> MAX_MARK_AGE) -> recoverable re-seed; skip deviation + funding (AUDIT F5)
        }
        mark = newMark;
        lastMarkTime = block.timestamp;
        lastIntrinsic = intrinsic;                          // sample intrinsic with the mark
        emit MarkPosted(newMark, cumFunding);
    }

    function pendingFunding(address t) public view returns (uint256) {
        Position memory p = positions[t];
        if (p.qty == 0) return 0;
        return p.qty * (cumFunding - p.entryCumFunding) / 1e18; // WAD
    }
```
> NOTE: the deviation guard must run before the first `mark != 0` branch executes; on the very first post `mark==0` so guards other than intrinsic/K are skipped. The `test_guard_deviationReverts` posts once to seed `mark`, warps a period, then trips deviation.

- [ ] **Step 4: Run — expect pass** — `forge test --match-contract PutFundingTest` → PASS.

- [ ] **Step 5: Commit** — `git commit -am "feat: guarded postMark + cumulative funding index"`

---

## Task 8: close() — settle funding + mark PnL + release escrow

**Files:** Modify `src/EverlastingPut.sol`; Test `test/EverlastingPut.close.t.sol`

**Interfaces — Produces:** `close()`; internal `_settle(address, uint256 closeMark)`; event `Closed(address,int256 pnlUsdc)`.

- [ ] **Step 1: Failing test (funding-only, mark flat → trader pays theta)**
```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {Test} from "forge-std/Test.sol";
import {EverlastingPut} from "../src/EverlastingPut.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockOracle} from "../src/MockOracle.sol";

contract PutCloseTest is Test {
    EverlastingPut put; MockUSDC usdc; MockOracle oracle;
    address trader = address(0xA11CE);
    function setUp() public {
        usdc = new MockUSDC(); oracle = new MockOracle();
        put = new EverlastingPut(usdc, oracle, 48e18, address(this));
        oracle.set(48e18);
        usdc.mint(address(this), 1_000_000e6); usdc.approve(address(put), type(uint256).max);
        put.lpDeposit(500_000e6);
        put.postMark(6e18);
        usdc.mint(trader, 1_000e6);
        vm.prank(trader); usdc.approve(address(put), type(uint256).max);
        vm.prank(trader); put.deposit(48e6);
        vm.prank(trader); put.openLong(1e18);
    }
    function test_close_flatMark_traderPaysFunding() public {
        vm.warp(block.timestamp + 3600);
        put.postMark(6e18);                    // funding += 6 (time value), mark unchanged
        uint256 poolBefore = put.poolFree();
        vm.prank(trader); put.close();
        // trader owed funding = 1 * 6 = $6 → col 48 - 6 = 42; escrow released to pool
        assertEq(put.traderCollateral(trader), 42e6);
        assertEq(put.poolLocked(), 0);
        assertEq(put.poolFree(), poolBefore + 48e6 + 6e6); // escrow back + funding
        (uint256 q,,) = put.positions(trader); assertEq(q, 0);
    }
    function test_close_markRose_traderGainsFromPool() public {
        // HYPE drops → put more valuable → mark up (long profits), within dev/K bounds
        oracle.set(45e18);                     // intrinsic 3
        vm.warp(block.timestamp + 3600);
        put.postMark(7e18);                    // +16% ≤ 20%; funding used PRE mark (6-0)=6
        vm.prank(trader); put.close();
        // markPnL = 1*(7-6)=+$1 ; funding = 1*(6)=$6 → net -5 → col 43
        assertEq(put.traderCollateral(trader), 43e6);
    }
}
```

- [ ] **Step 2: Run — expect fail** → FAIL.

- [ ] **Step 3: Implement**
```solidity
    event Closed(address indexed trader, int256 pnlUsdc);

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
        // (g <= qty*(mark-entryMark) <= qty*K = escrow), so the payout require can never false-revert.
        uint256 escrow = _escrowUsdc(p.qty);
        poolLocked -= escrow; poolFree += escrow;

        // apply PnL to balances; pool is the counterparty
        uint256 col = traderCollateral[t];
        if (netU >= 0) {
            uint256 g = uint256(netU);
            require(poolFree >= g, "pool insolvent"); // now always holds by construction
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
```

- [ ] **Step 4: Run — expect pass** — `forge test --match-contract PutCloseTest` → PASS.

- [ ] **Step 5: Commit** — `git commit -am "feat: close() settles funding + mark PnL, releases escrow"`

---

## Task 9: Auto-settle on margin exhaustion

**Files:** Modify `src/EverlastingPut.sol`; Test `test/EverlastingPut.autosettle.t.sol`

**Interfaces — Produces:** `settle(address trader)` — permissionless; reverts unless the trader's collateral cannot cover pending funding.

- [ ] **Step 1: Failing test**
```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {Test} from "forge-std/Test.sol";
import {EverlastingPut} from "../src/EverlastingPut.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockOracle} from "../src/MockOracle.sol";

contract PutAutoSettleTest is Test {
    EverlastingPut put; MockUSDC usdc; MockOracle oracle;
    address trader = address(0xA11CE);
    function setUp() public {
        usdc = new MockUSDC(); oracle = new MockOracle();
        put = new EverlastingPut(usdc, oracle, 48e18, address(this));
        oracle.set(48e18);
        usdc.mint(address(this), 1_000_000e6); usdc.approve(address(put), type(uint256).max);
        put.lpDeposit(500_000e6); put.postMark(6e18);
        usdc.mint(trader, 1_000e6);
        vm.prank(trader); usdc.approve(address(put), type(uint256).max);
        vm.prank(trader); put.deposit(48e6);
        vm.prank(trader); put.openLong(1e18);
    }
    function test_settle_revertsWhenSolvent() public {
        vm.expectRevert(bytes("solvent"));
        put.settle(trader);
    }
    function test_settle_closesWhenFundingExceedsCollateral() public {
        // accrue many periods of funding > 48 collateral (6/period → >8 periods)
        for (uint256 i = 0; i < 9; i++) { vm.warp(block.timestamp + 3600); put.postMark(6e18); }
        assertGt(put.pendingFunding(trader) / 1e12, put.traderCollateral(trader));
        put.settle(trader); // anyone
        (uint256 q,,) = put.positions(trader); assertEq(q, 0);
        assertEq(put.traderCollateral(trader), 0); // drained to pool
        assertEq(put.poolLocked(), 0);
    }
}
```

- [ ] **Step 2: Run — expect fail** → FAIL.

- [ ] **Step 3: Implement**
```solidity
    function settle(address t) external {
        Position memory p = positions[t];
        require(p.qty > 0, "no position");
        uint256 fundingU = _toUsdc(pendingFunding(t));
        require(fundingU > traderCollateral[t], "solvent");
        _closeFor(t); // _closeFor already floors trader loss at their collateral
    }
```

- [ ] **Step 4: Run — expect pass** → PASS.

- [ ] **Step 5: Commit** — `git commit -am "feat: permissionless auto-settle on margin exhaustion"`

---

## Task 10: Solvency invariant test

**Files:** Test `test/EverlastingPut.invariant.t.sol`

- [ ] **Step 1: Write invariant test** (Foundry invariant testing with a handler)
```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {Test} from "forge-std/Test.sol";
import {EverlastingPut} from "../src/EverlastingPut.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockOracle} from "../src/MockOracle.sol";

contract PutHandler is Test {
    EverlastingPut public put; MockUSDC public usdc; MockOracle public oracle;
    address[] public actors;
    uint256 public marksPosted;
    constructor(EverlastingPut _p, MockUSDC _u, MockOracle _o, address[] memory _a){ put=_p; usdc=_u; oracle=_o; actors=_a; }
    function _actor(uint256 seed) internal view returns (address) { return actors[seed % actors.length]; }

    function postMark(uint256 m) external {
        uint256 lo = put.intrinsicWad();
        if (put.mark() != 0) {
            uint256 dhi = put.mark() + put.mark()*2000/10000;
            uint256 dlo = put.mark() - put.mark()*2000/10000;
            lo = dlo > lo ? dlo : lo;
            m = bound(m, lo, dhi < put.K() ? dhi : put.K());
        } else { m = bound(m, lo, put.K()); }
        vm.warp(block.timestamp + 3600);
        try put.postMark(m) { marksPosted++; } catch {}     // keeper == this handler now
    }
    function moveSpot(uint256 s) external { oracle.set(bound(s, 1e18, 96e18)); }
    function deposit(uint256 seed, uint256 amt) external {
        address a = _actor(seed); amt = bound(amt, 0, 1_000e6);
        usdc.mint(a, amt); vm.startPrank(a); usdc.approve(address(put), amt);
        try put.deposit(amt) {} catch {} vm.stopPrank();
    }
    function openLong(uint256 seed, uint256 qty) external {
        address a = _actor(seed); qty = bound(qty, 0, 5e18);
        vm.prank(a); try put.openLong(qty) {} catch {}
    }
    function closePos(uint256 seed) external { address a=_actor(seed); vm.prank(a); try put.close() {} catch {} }
    function settlePos(uint256 seed) external { address a=_actor(seed); try put.settle(a) {} catch {} }
}

contract PutInvariantTest is Test {
    EverlastingPut put; MockUSDC usdc; MockOracle oracle; PutHandler h;
    address[] actors;
    function setUp() public {
        usdc = new MockUSDC(); oracle = new MockOracle(); oracle.set(48e18);
        actors.push(address(0xA11CE)); actors.push(address(0xB0B)); actors.push(address(0xCA11));
        // AUDIT F4: deploy ONCE and make the FUZZED handler the keeper (predict its address by nonce)
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        put = new EverlastingPut(usdc, oracle, 48e18, predicted); // nonce N; lp = this
        h = new PutHandler(put, usdc, oracle, actors);            // nonce N+1 == predicted
        require(address(h) == predicted, "keeper wiring");
        usdc.mint(address(this), 1_000_000e6); usdc.approve(address(put), type(uint256).max);
        put.lpDeposit(500_000e6);
        targetContract(address(h));
    }
    function invariant_solvency() public view {
        uint256 sum = put.traderCollateral(address(this));
        for (uint256 i = 0; i < actors.length; i++) sum += put.traderCollateral(actors[i]);
        assertEq(usdc.balanceOf(address(put)), put.poolFree() + put.poolLocked() + sum);
    }
    // AUDIT F4: fail if postMark never actually landed (would make invariant_solvency vacuous)
    function afterInvariant() public view { assertGt(h.marksPosted(), 0, "no marks posted -> vacuous"); }
}
```
> Invariant assertion form is identical to the spec (line 31): `usdc.balanceOf(put) == poolFree + poolLocked + Σ traderCollateral`. The handler now drives deposit/open/close/settle across 3 actors and the keeper is the fuzzed handler, so the sum is actually exercised.

- [ ] **Step 2: Run** — `forge test --match-contract PutInvariantTest` → PASS.

- [ ] **Step 3: Commit** — `git commit -am "test: solvency conservation invariant"`

---

## Task 11: Deploy script + off-chain keeper

**Files:** Create `script/Deploy.s.sol`, `keeper/postMark.ts`, `keeper/package.json`, `keeper/README.md`

**Interfaces — Consumes env:** `HYPEREVM_TESTNET_RPC`, `DEPLOYER_PRIVATE_KEY`, `KEEPER_PRIVATE_KEY`, `SIGMA`, `MARKET_ADDRESS`. (AUDIT nit: HYPE index 135 is a verified constant hardcoded in `OracleLib` — not env-wired; do not add it.)

- [ ] **Step 1: Deploy script** — `script/Deploy.s.sol`
```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {Script, console2} from "forge-std/Script.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {OracleLib} from "../src/OracleLib.sol";
import {EverlastingPut} from "../src/EverlastingPut.sol";

contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address keeper = vm.addr(vm.envUint("KEEPER_PRIVATE_KEY"));
        vm.startBroadcast(pk);
        MockUSDC usdc = new MockUSDC();
        OracleLib oracle = new OracleLib();
        uint256 spot = oracle.spotWad();
        uint256 K = (spot / 1e18) * 1e18;         // ATM-ish, whole-dollar strike
        EverlastingPut put = new EverlastingPut(usdc, oracle, K, keeper);
        vm.stopBroadcast();
        console2.log("MockUSDC", address(usdc));
        console2.log("OracleLib", address(oracle));
        console2.log("EverlastingPut", address(put));
        console2.log("K(wad)", K);
    }
}
```

- [ ] **Step 2: Dry-run compile** — `forge build` → success. (Do NOT broadcast yet.)

- [ ] **Step 3: Keeper** — `keeper/postMark.ts` (computes the geometric basket mark and posts hourly)
```ts
import { ethers } from "ethers";
// Basket: P = Σ_{i=1..N} 2^-i * BS_put(S,K,sigma,tau_i); tau_i = i * FUNDING_PERIOD (years)
// Slice-1: sigma is a hand-set constant (env SIGMA), later trailing realized vol.
const RPC = process.env.HYPEREVM_TESTNET_RPC!;
const KEEPER_PK = process.env.KEEPER_PRIVATE_KEY!;
const MARKET = process.env.MARKET_ADDRESS!;
const SIGMA = Number(process.env.SIGMA ?? "0.9");   // 90% annualized (HYPE ~ high vol)
const N = 12, PERIOD = 3600, YEAR = 31_536_000;
const ABI = [
  "function K() view returns (uint256)",
  "function intrinsicWad() view returns (uint256)",
  "function oracle() view returns (address)",
  "function postMark(uint256) external",
];
const OABI = ["function spotWad() view returns (uint256)"];

function normCdf(x: number){ // Abramowitz-Stegun
  const t = 1/(1+0.2316419*Math.abs(x));
  const d = 0.3989423*Math.exp(-x*x/2);
  let p = d*t*(0.3193815+t*(-0.3565638+t*(1.781478+t*(-1.821256+t*1.330274))));
  return x>0 ? 1-p : p;
}
function bsPut(S:number,K:number,sig:number,tau:number){
  if (tau<=0) return Math.max(K-S,0);
  const d1=(Math.log(S/K)+0.5*sig*sig*tau)/(sig*Math.sqrt(tau));
  const d2=d1-sig*Math.sqrt(tau);
  return K*normCdf(-d2)-S*normCdf(-d1);
}
async function main(){
  const p = new ethers.JsonRpcProvider(RPC);
  const w = new ethers.Wallet(KEEPER_PK, p);
  const m = new ethers.Contract(MARKET, ABI, w);
  const K = Number(ethers.formatUnits(await m.K(), 18));
  const oracle = new ethers.Contract(await m.oracle(), OABI, p);
  const S = Number(ethers.formatUnits(await oracle.spotWad(), 18));
  let basket = 0;
  for (let i=1;i<=N;i++){ basket += Math.pow(2,-i) * bsPut(S,K,SIGMA, i*PERIOD/YEAR); }
  const intrinsic = Math.max(K-S,0);
  let mark = Math.max(basket, intrinsic);          // enforce mark ≥ intrinsic
  mark = Math.min(mark, K);                         // enforce mark ≤ K
  const markWad = ethers.parseUnits(mark.toFixed(12), 18);
  const tx = await m.postMark(markWad);
  console.log(`postMark S=${S} K=${K} mark=${mark} tx=${tx.hash}`);
  await tx.wait();
}
main().catch(e=>{ console.error(e); process.exit(1); });
```
`keeper/package.json`:
```json
{ "name":"everlasting-keeper","private":true,"type":"module",
  "scripts":{"post":"tsx postMark.ts"},
  "dependencies":{"ethers":"^6.13.0"},"devDependencies":{"tsx":"^4.16.0"} }
```

- [ ] **Step 4: Keeper README** — `keeper/README.md` documents: `npm i`, env vars, `npm run post`, and hourly scheduling (cron / launchd). No secrets committed.

- [ ] **Step 5: Commit** — `git add script keeper && git commit -m "feat: deploy script + off-chain basket-mark keeper"`

---

## Task 12: Testnet deploy + end-to-end smoke

**Files:** Create `script/Smoke.s.sol` (optional convenience), doc `docs/RUNBOOK.md`

- [ ] **Step 1: Deploy to testnet**
```bash
source .env
forge script script/Deploy.s.sol --rpc-url "$HYPEREVM_TESTNET_RPC" --broadcast
# record printed addresses into .env as MARKET_ADDRESS, MOCKUSDC_ADDRESS
```
Expected: 3 contracts deployed; addresses logged.

- [ ] **Step 2: Seed + open (cast)**
```bash
source .env
# mint mock USDC to deployer, approve, LP deposit, trader deposit + open
cast send $MOCKUSDC_ADDRESS "mint(address,uint256)" $DEPLOYER_ADDRESS 1000000000000 --private-key $DEPLOYER_PRIVATE_KEY --rpc-url $HYPEREVM_TESTNET_RPC
cast send $MOCKUSDC_ADDRESS "approve(address,uint256)" $MARKET_ADDRESS 1000000000000 --private-key $DEPLOYER_PRIVATE_KEY --rpc-url $HYPEREVM_TESTNET_RPC
cast send $MARKET_ADDRESS "lpDeposit(uint256)" 500000000000 --private-key $DEPLOYER_PRIVATE_KEY --rpc-url $HYPEREVM_TESTNET_RPC
cast send $MARKET_ADDRESS "deposit(uint256)" 48000000 --private-key $DEPLOYER_PRIVATE_KEY --rpc-url $HYPEREVM_TESTNET_RPC
```

- [ ] **Step 3: Post first mark (keeper) + open a put**
```bash
cd keeper && npm i && MARKET_ADDRESS=$MARKET_ADDRESS npm run post && cd ..
cast send $MARKET_ADDRESS "openLong(uint256)" 1000000000000000000 --private-key $DEPLOYER_PRIVATE_KEY --rpc-url $HYPEREVM_TESTNET_RPC
cast call $MARKET_ADDRESS "positions(address)(uint256,uint256,uint256)" $DEPLOYER_ADDRESS --rpc-url $HYPEREVM_TESTNET_RPC
```
Expected: position qty = 1e18.

- [ ] **Step 4: Advance funding + close; verify P&L moved**
```bash
# wait ≥1h (or repeat mark posts across an hour), then:
cast send $MARKET_ADDRESS "close()" --private-key $DEPLOYER_PRIVATE_KEY --rpc-url $HYPEREVM_TESTNET_RPC
cast call $MARKET_ADDRESS "traderCollateral(address)(uint256)" $DEPLOYER_ADDRESS --rpc-url $HYPEREVM_TESTNET_RPC
```
Expected: collateral reduced by funding paid; position cleared.

- [ ] **Step 5: Write `docs/RUNBOOK.md`** capturing the addresses, the commands above, and how to schedule the keeper hourly. Commit: `git commit -am "docs: testnet runbook + smoke complete"`

---

## Self-Review

**Spec coverage:** oracle read (T3) · intrinsic/funding = mark−intrinsic (T4,T7) · peer-to-pool (T5,T6) · guards mark≥intrinsic/≤K/staleness/deviation (T7) · fully-collateralized escrow+IM (T6) · no-liquidation auto-settle (T9) · keeper-posted basket mark (T11) · unit+fork+invariant+scenario tests (T2–T10,T12). Call market + hedger + multi-LP shares + on-chain σ = explicitly deferred (Slice-2/3), consistent with the spec.

**Placeholders:** none — every step has runnable code/commands. Two NOTES flag deliberate Slice-1 simplifications (single-LP, Task-6 temporary `postMark` replaced in Task-7) — both are resolved within the plan, not left open.

**Type consistency:** `Position{qty,entryMark,entryCumFunding}`, `cumFunding` (WAD), `pendingFunding`→WAD then `_toUsdc`, `poolFree`/`poolLocked`/`traderCollateral` all USDC (6dp), consistent across T6–T12. `postMark` signature identical in T6 (stub) and T7 (guarded).

**Open parameter (deploy-time):** `SIGMA` for the keeper (Slice-1 hand-set ~0.9); strike `K` = whole-dollar ATM at deploy.
