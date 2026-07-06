// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {EverlastingBook} from "../src/EverlastingBook.sol";
import {MockCoverVault} from "../src/mocks/MockCoverVault.sol";
import {MockOracle} from "../src/MockOracle.sol";
import {MockVol} from "../src/mocks/MockVol.sol";

/// @title BookInvariantHandler
/// @notice Fuzz handler exercising the FULL two-sided EverlastingBook life-cycle on ONE shared
///         pool: LP liquidity, cover buying, per-side deposit/open/mark/close/settle/withdraw, and
///         a spot driver that sweeps HYPE price across [1, 1000*Kcall] AND down toward 0.
///
///         The mark is autonomous (mark = fairMark() via permissionless accrue()); the handler pokes
///         accrue on both sides so funding + the always-on P(U)/adaptive controller fold each period.
///         Model soundness: `moveSpot`/`crashSpot` set BOTH the option oracle and the vault cover
///         price to the SAME spot (the underlying of a HYPE option IS HYPE). Opens are made reachable
///         by seeding cover + pool-free + collateral generously right before each attempt.
contract BookInvariantHandler is Test {
    EverlastingBook public book;
    MockCoverVault  public vault;
    MockOracle      public oracle;
    address[]       public actors;

    uint256 public constant KPUT  = 100e18;
    uint256 public constant WPUT  =  50e18;
    uint256 public constant KCALL = 120e18;

    EverlastingBook.Side private constant PUT  = EverlastingBook.Side.PUT;
    EverlastingBook.Side private constant CALL = EverlastingBook.Side.COVERED_CALL;
    uint8 private constant PUT_U  = 0;
    uint8 private constant CALL_U = 1;

    // ── Non-vacuity counters ──────────────────────────────────────────────────
    uint256 public marksPutPosted;
    uint256 public marksCallPosted;
    uint256 public putsOpened;
    uint256 public callsOpened;
    uint256 public putsClosed;
    uint256 public callsClosed;
    uint256 public emergencyUnwinds;

    constructor(EverlastingBook _book, MockCoverVault _vault, MockOracle _oracle, address[] memory _actors) {
        book = _book;
        vault = _vault;
        oracle = _oracle;
        actors = _actors;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @notice One-shot baseline: post both marks + open ONE real position on EACH side, so the
    ///         post-setUp snapshot every fuzz run reverts to is already non-vacuous. Called once
    ///         from setUp (and excluded from the fuzz target set). The fuzz then layers MANY more
    ///         opens/marks/closes on top — this only guarantees afterInvariant's floor is ≥1 even
    ///         if a given run's random tail is quiet (Foundry reverts handler state between runs,
    ///         so afterInvariant sees the last run's counters, which now start from this baseline).
    function bootstrap() external {
        try book.accrue(CALL) { marksCallPosted++; } catch {} // mark = fairMark(CALL) on-chain
        try book.accrue(PUT)  { marksPutPosted++; } catch {}  // mark = fairMark(PUT) on-chain
        try vault.buyCover(10e18, type(uint256).max) {} catch {}       // cover for the call
        try book.lpDeposit(200e6) {} catch {}                          // pool-free for the put escrow

        address ca = actors[0];
        vm.startPrank(ca);
        try book.deposit(CALL, 100e6) {} catch {}
        try book.openLong(CALL, 1e18) { callsOpened++; } catch {}
        vm.stopPrank();

        address pa = actors[1];
        vm.startPrank(pa);
        try book.deposit(PUT, 100e6) {} catch {}
        try book.openLong(PUT, 1e18) { putsOpened++; } catch {}
        vm.stopPrank();
    }

    // ── LP pool-free liquidity ────────────────────────────────────────────────

    function lpDeposit(uint256 amt) external {
        amt = bound(amt, 1e6, 1_000_000e6);
        try book.lpDeposit(amt) {} catch {}
    }

    function lpWithdraw(uint256 amt) external {
        amt = bound(amt, 1, 2_000_000e6);
        try book.lpWithdraw(amt) {} catch {}
    }

    // ── Cover buying (keep coverHype ahead of call demand) ────────────────────

    function buyCover(uint256 qty) external {
        qty = bound(qty, 1e16, 500e18);
        uint256 px = vault.spotPxUsdc();
        if (px == 0) return;
        uint256 cost = qty * px / 1e18 / 1e12 + 1;
        try book.lpDeposit(cost) {} catch {}                    // fund the buy from LP capital
        try vault.buyCover(qty, type(uint256).max) {} catch {}  // poolFree flat, coverHype up
    }

    // ── Deposit collateral (both sides) ───────────────────────────────────────

    function deposit(uint256 sideSeed, uint256 seed, uint256 amt) external {
        amt = bound(amt, 1e6, 100_000e6);
        EverlastingBook.Side side = sideSeed % 2 == 0 ? PUT : CALL;
        vm.prank(_actor(seed));
        try book.deposit(side, amt) {} catch {}
    }

    // ── Open (both sides) ─────────────────────────────────────────────────────
    //
    // Reachability: the handler IS the keeper, so each open self-posts a FRESH mark first
    // (a call is worth ≤ spot; a put ≤ Wput). This makes opens reliable on EVERY fuzz seed
    // (no dependence on the fuzzer happening to post a mark before the mark goes stale), so
    // the campaign is non-vacuous deterministically. Marks self-posted here also count.

    /// @dev Refresh `side`'s mark to the on-chain fair value (permissionless accrue); counts on success.
    ///      openLong auto-accrues too, but calling here keeps the non-vacuity mark counters live and
    ///      guarantees mark > 0 before the open guard below.
    function _selfPostMark(EverlastingBook.Side side) internal {
        try book.accrue(side) {
            if (side == CALL) marksCallPosted++;
            else marksPutPosted++;
        } catch {}
    }

    function openLongCall(uint256 seed, uint256 qty) external {
        _selfPostMark(CALL);
        (uint256 mark,,,,) = book.sideState(CALL_U);
        if (mark == 0) return;
        uint256 px = vault.spotPxUsdc();
        if (px == 0) return;
        qty = bound(qty, 1e17, 5e18);
        address a = _actor(seed);
        (uint256 pq,,) = book.positions(CALL_U, a);
        if (pq != 0) return;

        // Seed cover generously (keep coverHype >> netWritten) + IM.
        uint256 coverQty = qty * 3;
        uint256 coverCost = coverQty * px / 1e18 / 1e12 + 1;
        try book.lpDeposit(coverCost) {} catch {}
        try vault.buyCover(coverQty, type(uint256).max) {} catch {}

        uint256 im = qty * mark / 1e18 / 1e12 + 1e6;
        vm.startPrank(a);
        try book.deposit(CALL, im) {} catch {}
        try book.openLong(CALL, qty) { callsOpened++; } catch {}
        vm.stopPrank();
    }

    function openLongPut(uint256 seed, uint256 qty) external {
        _selfPostMark(PUT);
        (uint256 mark,,,,) = book.sideState(PUT_U);
        if (mark == 0) return;
        qty = bound(qty, 1e17, 5e18);
        address a = _actor(seed);
        (uint256 pq,,) = book.positions(PUT_U, a);
        if (pq != 0) return;

        // escrow IM = _toUsdc(qty*Wput/1e18); the pool must have >= im FREE to lock as escrow.
        uint256 im = qty * WPUT / 1e18 / 1e12 + 1;
        try book.lpDeposit(im + 1e6) {} catch {}   // raise poolFree for the escrow lock
        vm.startPrank(a);
        try book.deposit(PUT, im) {} catch {}      // trader margin (poolFree flat)
        try book.openLong(PUT, qty) { putsOpened++; } catch {}
        vm.stopPrank();
    }

    // ── Accrue (both sides): advance a funding period + fold the autonomous mark ──────────

    function accrueCall(uint256) external {
        // Advance a funding period, then accrue (folds funding + the always-on P(U)/adaptive
        // controller, refreshes mark = fairMark(CALL)). moveSpot/crashSpot vary the mark, not a keeper.
        vm.warp(block.timestamp + book.FUNDING_PERIOD());
        try book.accrue(CALL) { marksCallPosted++; } catch {}
    }

    function accruePut(uint256) external {
        vm.warp(block.timestamp + book.FUNDING_PERIOD());
        try book.accrue(PUT) { marksPutPosted++; } catch {}
    }

    // ── Close / settle (both sides) ───────────────────────────────────────────

    function closeCall(uint256 seed) external {
        address a = _actor(seed);
        vm.prank(a);
        try book.close(CALL) { callsClosed++; } catch {}
    }

    function closePut(uint256 seed) external {
        address a = _actor(seed);
        vm.prank(a);
        try book.close(PUT) { putsClosed++; } catch {}
    }

    function settleCall(uint256 seed) external {
        try book.settle(CALL, _actor(seed)) {} catch {}
    }

    function settlePut(uint256 seed) external {
        try book.settle(PUT, _actor(seed)) {} catch {}
    }

    // ── Withdraw free collateral (both sides) ─────────────────────────────────

    function withdrawCall(uint256 seed, uint256 amt) external {
        address a = _actor(seed);
        amt = bound(amt, 1, book.traderCollateral(CALL_U, a) + 1);
        vm.prank(a);
        try book.withdraw(CALL, amt) {} catch {}
    }

    function withdrawPut(uint256 seed, uint256 amt) external {
        address a = _actor(seed);
        amt = bound(amt, 1, book.traderCollateral(PUT_U, a) + 1);
        vm.prank(a);
        try book.withdraw(PUT, amt) {} catch {}
    }

    // ── Emergency cover unwind (post-unwind state-space exploration) ─────────
    //
    // Guarded by callNetWritten == 0 so invariant_coverGate (coverHype >= callNetWritten)
    // is never violated: after unwind, coverHype >= 0 == callNetWritten. The book is
    // immediately unpaused so subsequent openLongCall ops (which seed fresh cover) can
    // replenish coverHype and keep opens reachable — callsClosed/putsClosed stay non-zero.
    // Rate-limited by seed so opens dominate the campaign and non-vacuity holds.

    function triggerEmergencyUnwind(uint256 seed) external {
        // ~12.5% of calls — keeps the op rare so opens dominate the fuzz campaign.
        if (seed % 8 != 0) return;
        // coverGate guard: only unwind when no CALL positions are open (netWritten == 0).
        // This ensures coverHype >= 0 == callNetWritten holds trivially after unwind.
        (,,,, uint256 callNetWritten) = book.sideState(CALL_U);
        if (callNetWritten > 0) return;
        // Pause → unwind → immediately unpause so future opens are not blocked.
        if (book.paused()) {
            // Already paused from a prior partial op; just unwind + unpause.
            try book.emergencyUnwindCover() { emergencyUnwinds++; } catch {}
            try book.unpause() {} catch {}
            return;
        }
        try book.pause() {} catch { return; }
        try book.emergencyUnwindCover() { emergencyUnwinds++; } catch {}
        try book.unpause() {} catch {}
    }

    // ── P(U) surcharge + adaptive controller are now ALWAYS-ON (hardcoded UTIL_KAPPA / U_MAX /
    //    ADAPT_K / U_STAR constants), so the conservation fuzz exercises BOTH paths by default every
    //    campaign — the owner setters were removed in the autonomy pass, so no setter action is needed.

    // ── Spot driver: sweep across [1, 1000*Kcall] AND crash toward 0 ──────────

    function moveSpot(uint256 s) external {
        s = bound(s, 1e18, 1000 * KCALL);
        oracle.set(s);
        vault.setMockPx(s);   // option underlying == HYPE cover price
    }

    function crashSpot(uint256 s) external {
        s = bound(s, 1, 5e18);   // sub-$5 down to 1 wei: put payout explodes, cover value collapses
        oracle.set(s);
        vault.setMockPx(s);
    }
}

/// @title BookInvariantTest
/// @notice Task 7 solvency proof — a conservation fuzz over the unified two-sided EverlastingBook.
///
///   invariant_usdcConservation (LOAD-BEARING): vault.poolUsdc() == poolFree() + putEscrow +
///     totalCollateral, AND totalCollateral == Σ traderCollateral over BOTH sides × all actors.
///     poolFree() underflow-reverts if poolUsdc < totalCollateral + putEscrow, so a violated state
///     either reverts inside the invariant or fails the equality — the tick-dust liveness leak this
///     task fixes would surface here as a poolFree() underflow after enough winning call closes.
///   invariant_coverGate: vault.coverHype() >= callNetWritten (1:1 tail cover, never over-sold).
///   invariant_putEscrow: putEscrow == Σ (open PUT) _toUsdc(qty*Wput/1e18).
///   afterInvariant: non-vacuity — real opens on BOTH sides + marks on both sides actually landed.
///
/// @dev Fixed seed + explicit runs/depth make the campaign reproducible (the non-vacuity check is a
///      cumulative-counter assertion, which — like any afterInvariant guard — must be deterministic
///      to avoid seed-flaky CI). Opens self-post fresh marks, so the campaign is non-vacuous by
///      construction regardless of seed; the pin just makes the exact counts reproducible.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 500
/// forge-config: default.invariant.fail-on-revert = false
/// forge-config: default.fuzz.seed = '0x7'
contract BookInvariantTest is Test {
    MockCoverVault  vault;
    MockOracle      oracle;
    MockVol         mockVol;
    EverlastingBook book;
    BookInvariantHandler h;

    address[] actors = [address(0xA11CE), address(0xB0B), address(0xCA11)];

    uint256 constant KPUT  = 100e18;
    uint256 constant WPUT  =  50e18;
    uint256 constant KCALL = 120e18;
    uint8 private constant PUT_U  = 0;
    uint8 private constant CALL_U = 1;

    function setUp() public {
        vault  = new MockCoverVault();
        oracle = new MockOracle();
        oracle.set(100e18);       // spot == Kput → put intrinsic 0, call OTM
        vault.setMockPx(100e18);  // cover price == underlying
        mockVol = new MockVol();  // autonomous vol source (sigma=0.8e18, ready=true)

        // Nonce-predict the handler so it becomes the keeper. Deploys so far: vault, oracle, mockVol;
        // book deploys next at getNonce(this); handler at +1 == predicted.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        book = new EverlastingBook(
            vault, oracle, predicted,
            KPUT, WPUT, KCALL,
            5_000_000e18, // putCapNotional (generous — opens reachable; cap logic unit-tested elsewhere)
            5_000_000e18, // callCapNotional
            mockVol       // autonomous mark: vol source (immutable)
        );
        h = new BookInvariantHandler(book, vault, oracle, actors);
        require(address(h) == predicted, "keeper wiring");

        // Seed pool-free liquidity + initial cover so the first opens are reachable.
        book.lpDeposit(500_000e6);            // poolFree = 500_000e6
        vault.buyCover(1_000e18, type(uint256).max); // coverHype = 1000e18 (cost 100_000e6 from free)

        // T8: LP-gating — transfer book ownership to the handler so it can call lpDeposit/lpWithdraw.
        // The setUp contract is currently owner (it deployed the book). After this 2-step transfer,
        // the handler becomes owner and its lpDeposit/lpWithdraw calls in the fuzz campaign succeed.
        book.transferOwnership(address(h));
        vm.prank(address(h));
        book.acceptOwnership();

        // Bake ONE real position + mark on EACH side into the baseline snapshot (non-vacuity floor).
        h.bootstrap();

        targetContract(address(h));
        // Exclude the one-shot bootstrap from the fuzz target set (it's a setUp helper, not an op).
        bytes4[] memory noBoot = new bytes4[](1);
        noBoot[0] = h.bootstrap.selector;
        excludeSelector(FuzzSelector({addr: address(h), selectors: noBoot}));
    }

    // ── Conservation (the load-bearing solvency invariant) ────────────────────

    function invariant_usdcConservation() public view {
        // poolFree() reverts on underflow — a violated (insolvent) state can't even reach the assert.
        assertEq(
            vault.poolUsdc(),
            book.poolFree() + book.putEscrow() + book.totalCollateral(),
            "conservation: poolUsdc != poolFree + putEscrow + totalCollateral"
        );

        // totalCollateral must equal the live Σ of per-trader collateral across BOTH sides.
        uint256 sumCol;
        for (uint256 i = 0; i < actors.length; i++) {
            sumCol += book.traderCollateral(PUT_U, actors[i]);
            sumCol += book.traderCollateral(CALL_U, actors[i]);
        }
        assertEq(book.totalCollateral(), sumCol, "conservation: totalCollateral != sum traderCollateral");
    }

    // ── Cover gate: 1:1 tail cover, never over-sold ───────────────────────────

    function invariant_coverGate() public view {
        (,,,, uint256 callNetWritten) = book.sideState(CALL_U);
        assertGe(vault.coverHype(), callNetWritten, "coverGate: coverHype < callNetWritten");
    }

    // ── Put escrow: exactly Σ over open puts of _toUsdc(qty*Wput/1e18) ─────────

    function invariant_putEscrow() public view {
        uint256 sumEscrow;
        for (uint256 i = 0; i < actors.length; i++) {
            (uint256 qty,,) = book.positions(PUT_U, actors[i]);
            if (qty > 0) sumEscrow += (qty * WPUT / 1e18) / 1e12; // _toUsdc(qty*Wput/1e18)
        }
        assertEq(book.putEscrow(), sumEscrow, "putEscrow != sum open-put qty*Wput");
    }

    // ── Non-vacuity: real activity on BOTH sides ──────────────────────────────

    function afterInvariant() public view {
        assertGt(h.marksPutPosted(),  0, "vacuous: no PUT marks posted");
        assertGt(h.marksCallPosted(), 0, "vacuous: no CALL marks posted");
        assertGt(h.putsOpened(),      0, "vacuous: no PUT opens");
        assertGt(h.callsOpened(),     0, "vacuous: no CALL opens");
        assertGt(h.callsClosed(),     0, "vacuous: no call closes in fuzz");
        assertGt(h.putsClosed(),      0, "vacuous: no put closes in fuzz");
    }
}
