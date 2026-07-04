// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ISpotOracle} from "./interfaces/ISpotOracle.sol";
import {ICoverVault} from "./interfaces/ICoverVault.sol";

/// @title EverlastingBook
/// @notice Two-sided everlasting options book: PUT + COVERED_CALL, unified pool via ICoverVault.
///         The book holds NO cash — all USDC/HYPE lives in `vault`.
///         Tasks 4-7 implement openLong, close, settle, funding, and escrow.
contract EverlastingBook {
    // ── Side enum ─────────────────────────────────────────────────────────────

    enum Side { PUT, COVERED_CALL }

    // ── Constants ─────────────────────────────────────────────────────────────

    uint256 public constant FUNDING_PERIOD   = 3600;   // seconds (1 hour)
    uint256 public constant MAX_MARK_AGE     = 7200;   // seconds (2 hours)
    uint256 public constant MAX_MARK_DEV_BPS = 2000;   // 20% max deviation per update

    // ── Immutables ─────────────────────────────────────────────────────────────

    /// @notice Vault holding all USDC/HYPE collateral. The book holds no cash itself.
    ICoverVault public immutable vault;

    /// @notice Spot price oracle (WAD).
    ISpotOracle public immutable oracle;

    /// @notice Privileged address permitted to post marks.
    address public immutable keeper;

    /// @notice PUT strike (WAD).
    uint256 public immutable Kput;

    /// @notice PUT max payout cap per unit (WAD). PUT intrinsic is clamped to this.
    uint256 public immutable Wput;

    /// @notice COVERED_CALL strike (WAD). Call intrinsic is uncapped.
    uint256 public immutable Kcall;

    /// @notice Maximum aggregate notional outstanding on the PUT side (WAD).
    uint256 public immutable putCapNotional;

    /// @notice Maximum aggregate notional outstanding on the COVERED_CALL side (WAD).
    uint256 public immutable callCapNotional;

    // ── Per-side state ────────────────────────────────────────────────────────

    /// @notice Per-side market state (independent marks, funding, and open interest).
    struct SideState {
        uint256 mark;          // WAD — current mid-market mark price
        uint256 lastMarkTime;  // unix timestamp of last postMark
        uint256 cumFunding;    // WAD — cumulative funding per unit qty
        uint256 lastIntrinsic; // WAD — intrinsic sampled at last postMark
        uint256 netWritten;    // WAD — total qty open (long) on this side
    }

    /// @dev Keyed by uint8(Side): 0 = PUT, 1 = COVERED_CALL.
    mapping(uint8 => SideState) public sideState;

    // ── Positions ─────────────────────────────────────────────────────────────

    /// @notice Open long position for a single trader on one side.
    struct Position {
        uint256 qty;
        uint256 entryMark;
        uint256 entryCumFunding;
    }

    /// @dev positions[uint8(side)][trader]
    mapping(uint8 => mapping(address => Position)) public positions;

    // ── Trader collateral (per-side, 6dp USDC) ────────────────────────────────

    /// @notice Trader collateral per (side, trader) in 6dp USDC.
    /// @dev Minimal deposit path only; full withdraw flow deferred to T7.
    ///      deposit() calls vault.pullUsdc — in MockCoverVault the `from` address is ignored
    ///      and poolUsdc is simply credited (no real ERC20 transfer in tests).
    mapping(uint8 => mapping(address => uint256)) public traderCollateral;

    // ── Shared-pool logical ledgers (T6) ──────────────────────────────────────
    //
    // The book holds NO cash: vault.poolUsdc() is the ONE physical USDC balance shared
    // by both sides. On top of it the book tracks logical ledgers so each side can only
    // ever spend its own funds:
    //   • traderCollateral[side][t] — per-side trader margin (already exists from T4)
    //   • totalCollateral           — running Σ of ALL traderCollateral (both sides)
    //   • putEscrow                 — pool USDC locked as qty·W escrow vs open puts
    // Derived: poolFree() = poolUsdc − totalCollateral − putEscrow (the pool's own
    // uncommitted USDC). Conservation invariant (T7 fuzzes this):
    //   vault.poolUsdc() == poolFree() + putEscrow + totalCollateral, always.

    /// @notice Pool USDC locked as escrow against open PUT positions (6dp).
    /// @dev PUT uses the slice-2 fully-collateralized escrow model: each open put locks
    ///      qty·Wput of the pool's own USDC until close. Released FIRST on close (F2).
    uint256 public putEscrow;

    /// @notice Running sum of ALL traderCollateral across BOTH sides (6dp).
    /// @dev Maintained incrementally on every collateral mutation so poolFree() stays O(1).
    uint256 public totalCollateral;

    // ── Events ────────────────────────────────────────────────────────────────

    event Deposited(Side indexed side, address indexed trader, uint256 amt);
    event Opened(Side indexed side, address indexed trader, uint256 qty, uint256 mark);
    event MarkPosted(Side indexed side, uint256 mark, uint256 cumFunding);
    /// @notice Emitted on every close and settle.
    /// @param coverSold  HYPE WAD sold from cover to fund a winning payout (0 on loss branch).
    event Closed(address indexed trader, int256 net, uint256 coverSold);

    // ── Constructor ───────────────────────────────────────────────────────────

    constructor(
        ICoverVault _vault,
        ISpotOracle _oracle,
        address     _keeper,
        uint256     _Kput,
        uint256     _Wput,
        uint256     _Kcall,
        uint256     _putCapNotional,
        uint256     _callCapNotional
    ) {
        require(address(_vault)  != address(0), "vault=0");
        require(address(_oracle) != address(0), "oracle=0");
        require(_keeper != address(0), "keeper=0");
        require(_Kput  > 0, "Kput=0");
        require(_Wput  > 0, "Wput=0");
        require(_Kcall > 0, "Kcall=0");

        vault            = _vault;
        oracle           = _oracle;
        keeper           = _keeper;
        Kput             = _Kput;
        Wput             = _Wput;
        Kcall            = _Kcall;
        putCapNotional   = _putCapNotional;
        callCapNotional  = _callCapNotional;
    }

    // ── Pool view — delegates to vault; book holds no cash ────────────────────

    /// @notice USDC available in the pool (6dp). Delegates to vault.
    function poolUsdc() external view returns (uint256) {
        return vault.poolUsdc();
    }

    /// @notice The pool's own uncommitted USDC (6dp): physical pool minus all trader
    ///         collateral claims minus put escrow.
    /// @dev Reverts on underflow — and that underflow is precisely the solvency-invariant
    ///      violation Task 7 fuzzes against (poolUsdc must always cover collateral + escrow).
    function poolFree() public view returns (uint256) {
        return vault.poolUsdc() - totalCollateral - putEscrow;
    }

    // ── Intrinsic ─────────────────────────────────────────────────────────────

    /// @notice Intrinsic value for the given side (WAD).
    ///
    ///   PUT          : clamp(Kput − S, 0, Wput)   — per slice-2 EverlastingMarket
    ///   COVERED_CALL : max(S − Kcall, 0)           — uncapped, per slice-3a CoveredCallMarket
    function intrinsic(Side side) public view returns (uint256) {
        uint256 s = oracle.spotWad();
        if (side == Side.PUT) {
            uint256 pv = s >= Kput ? 0 : Kput - s;
            return pv > Wput ? Wput : pv;
        }
        // COVERED_CALL: no upper clamp
        return s > Kcall ? s - Kcall : 0;
    }

    // ── Internal helpers ──────────────────────────────────────────────────────

    /// @dev WAD → USDC 6dp. Matches house style from EverlastingMarket / CoveredCallMarket.
    function _toUsdc(uint256 wad) internal pure returns (uint256) {
        return wad / 1e12;
    }

    // ── Deposit ───────────────────────────────────────────────────────────────

    /// @notice Deposit USDC collateral for the given side.
    /// @dev Minimal deposit path — full withdraw flow deferred to T7.
    ///      Calls vault.pullUsdc(msg.sender, amt); MockCoverVault credits poolUsdc directly
    ///      (no real ERC20). Core-native deposit flow also deferred to T7.
    function deposit(Side side, uint256 amt) external {
        vault.pullUsdc(msg.sender, amt);
        traderCollateral[uint8(side)][msg.sender] += amt;
        totalCollateral += amt; // T6: keep Σ collateral in lockstep (poolFree stays flat here)
        emit Deposited(side, msg.sender, amt);
    }

    // ── openLong ──────────────────────────────────────────────────────────────

    /// @notice Open a long position on the given side.
    /// @dev PUT (slice-2 escrow model): fresh mark, one position per (side, trader),
    ///      escrow IM = qty·Wput of the trader's collateral, and the pool locks a matching
    ///      qty·Wput of its OWN free USDC as escrow (fully collateralized). Cap on open qty.
    ///      COVERED_CALL: fresh mark required, one position per (side, trader), premium IM check,
    ///      D3 cover gate reads vault.coverHype() on-chain (not optimistic local state), cap check.
    function openLong(Side side, uint256 qty) external {
        if (side == Side.PUT) {
            // ── PUT branch (port of EverlastingMarket.openLong) ──────────────
            uint8 sp = uint8(Side.PUT);
            SideState storage ps = sideState[sp];
            require(qty > 0, "qty=0");
            require(ps.mark > 0, "no mark");
            require(block.timestamp <= ps.lastMarkTime + MAX_MARK_AGE, "stale mark");
            require(positions[sp][msg.sender].qty == 0, "one position");

            uint256 im = _toUsdc(qty * Wput / 1e18);                // escrow IM = qty·W
            require(traderCollateral[sp][msg.sender] >= im, "put: IM");
            require(poolFree() >= im, "put: pool escrow");          // pool can lock qty·W

            putEscrow += im;
            ps.netWritten += qty;
            require(ps.netWritten <= putCapNotional, "cap");        // WAD cap on open put qty

            positions[sp][msg.sender] = Position(qty, ps.mark, ps.cumFunding);
            emit Opened(Side.PUT, msg.sender, qty, ps.mark);
            return;
        }

        // COVERED_CALL branch
        SideState storage ss = sideState[uint8(side)];
        require(qty > 0, "qty=0");
        require(ss.mark > 0, "no mark");
        require(block.timestamp <= ss.lastMarkTime + MAX_MARK_AGE, "stale mark");
        require(positions[uint8(side)][msg.sender].qty == 0, "one position");
        require(
            traderCollateral[uint8(side)][msg.sender] >= _toUsdc(qty * ss.mark / 1e18),
            "IM"
        );
        // D3 pre-funded model: read vault on-chain (not optimistic local netWritten)
        require(vault.coverHype() >= ss.netWritten + qty, "cover");
        require(ss.netWritten + qty <= callCapNotional, "cap");

        ss.netWritten += qty;
        positions[uint8(side)][msg.sender] = Position(qty, ss.mark, ss.cumFunding);
        emit Opened(side, msg.sender, qty, ss.mark);
    }

    // ── postMark ──────────────────────────────────────────────────────────────

    /// @notice Keeper posts a new mark price for the given side.
    /// @dev PUT: keeper-gated, ≤Wput upper clamp (slice-2 payout cap), deviation +
    ///      recoverable-staleness guards, F3 funding advance using contemporaneous lastIntrinsic.
    ///      COVERED_CALL: keeper-gated, uncapped (no ≤W), deviation + recoverable-staleness guards,
    ///      F3 funding advance using contemporaneous lastIntrinsic.
    ///      The deviation/staleness/funding block below is shared and behaviourally identical for
    ///      both sides; the ONLY per-side difference is the PUT ≤Wput clamp.
    function postMark(Side side, uint256 newMark) external {
        require(msg.sender == keeper, "only keeper");

        SideState storage ss = sideState[uint8(side)];
        uint256 intr = intrinsic(side);
        require(newMark >= intr, "mark<intrinsic");
        if (side == Side.PUT) {
            require(newMark <= Wput, "mark>W"); // PUT-side payout clamp (slice-2); call side uncapped
        }

        bool isFresh = (ss.mark != 0) && (block.timestamp <= ss.lastMarkTime + MAX_MARK_AGE);
        if (isFresh) {
            uint256 hi = ss.mark + ss.mark * MAX_MARK_DEV_BPS / 10_000;
            uint256 lo = ss.mark - ss.mark * MAX_MARK_DEV_BPS / 10_000;
            require(newMark <= hi && newMark >= lo, "mark deviation");

            uint256 age = block.timestamp - ss.lastMarkTime;
            uint256 periods = age / FUNDING_PERIOD;
            if (periods > 0) {
                // F3: contemporaneous lastIntrinsic from the prior mark time
                uint256 f = ss.mark >= ss.lastIntrinsic ? ss.mark - ss.lastIntrinsic : 0;
                ss.cumFunding += f * periods;
            }
        }

        ss.mark = newMark;
        ss.lastMarkTime = block.timestamp;
        ss.lastIntrinsic = intr;
        emit MarkPosted(side, newMark, ss.cumFunding);
    }

    // ── pendingFunding ────────────────────────────────────────────────────────

    /// @notice Pending funding owed by trader `t` on the given side (WAD).
    /// @dev Mirrors CoveredCallMarket.pendingFunding, parameterised by side.
    function pendingFunding(Side side, address t) public view returns (uint256) {
        Position memory p = positions[uint8(side)][t];
        if (p.qty == 0) return 0;
        return p.qty * (sideState[uint8(side)].cumFunding - p.entryCumFunding) / 1e18;
    }

    // ── netLossUsdc (I2 insolvency predicate) ─────────────────────────────────

    /// @notice Trader's net loss in USDC for the given side (6dp). Zero when net gain.
    ///         The I2 insolvency predicate: settle fires when netLossUsdc > traderCollateral.
    ///         Mirrors CoveredCallMarket.netLossUsdc, parameterised by side.
    /// @dev    Side-agnostic: the long-option PnL split (markGain/markLoss less funding) is
    ///         identical for PUT and COVERED_CALL, so this powers settle() on both sides (T6).
    function netLossUsdc(Side side, address t) public view returns (uint256) {
        uint8 s = uint8(side);
        Position memory p = positions[s][t];
        if (p.qty == 0) return 0;
        SideState storage ss = sideState[s];
        uint256 fundingU = _toUsdc(p.qty * (ss.cumFunding - p.entryCumFunding) / 1e18);
        uint256 markGainU;
        uint256 markLossU;
        if (ss.mark >= p.entryMark) {
            markGainU = _toUsdc(p.qty * (ss.mark - p.entryMark) / 1e18);
        } else {
            markLossU = _toUsdc(p.qty * (p.entryMark - ss.mark) / 1e18);
        }
        uint256 debit = markLossU + fundingU;
        return debit > markGainU ? debit - markGainU : 0;
    }

    // ── Close / Settle ────────────────────────────────────────────────────────

    /// @dev Internal: close a COVERED_CALL position for trader `t`.
    ///
    ///      I3 (cover→USDC): on a positive trader net g, sell cover to fund the payout:
    ///        1. Compute hypeForG = (g in WAD) / spotPx — the HYPE needed to raise g USDC.
    ///        2. Floor to szDecimals=2 tick (0.01 HYPE = 1e16 WAD). Dust stays in coverHype.
    ///        3. Call vault.sellCover(flooredHype) if flooredHype > 0 and cover is available.
    ///        4. Source the payout from vault.poolUsdc() — NEVER from sellCover's return (M3).
    ///
    ///      M3 SAFETY: vault.sellCover returns an ESTIMATE; the real CoreCoverVault fill is
    ///      async (T9 concern). MockCoverVault credits poolUsdc synchronously, making T5 testable,
    ///      but the book MUST rely on the physical vault.poolUsdc() balance, not the return value.
    ///      Reading the return to credit any ledger would double-count the proceeds.
    ///
    ///      No int256 intermediate: gain/loss split kept in uint256, cast only at emit boundary.
    ///      Precision favours the pool: _toUsdc truncates and szDecimals floor leaves dust.
    function _closeCall(address t) internal {
        uint8 s = uint8(Side.COVERED_CALL);
        SideState storage ss = sideState[s];
        Position memory p = positions[s][t];
        require(p.qty > 0, "no position");

        uint256 fundingU = _toUsdc(p.qty * (ss.cumFunding - p.entryCumFunding) / 1e18);

        // Mark PnL split in uint256 — avoids int256 intermediate (mirrors CoveredCallMarket._closeFor)
        uint256 markGainU;
        uint256 markLossU;
        if (ss.mark >= p.entryMark) {
            markGainU = _toUsdc(p.qty * (ss.mark - p.entryMark) / 1e18);
        } else {
            markLossU = _toUsdc(p.qty * (p.entryMark - ss.mark) / 1e18);
        }

        uint256 flooredHype; // set in gain branch; stays 0 on loss branch

        if (markGainU >= markLossU + fundingU) {
            // ── Gain branch ──────────────────────────────────────────────────
            uint256 g = markGainU - markLossU - fundingU;
            // I3: fund g by selling cover
            uint256 spotPxWad = vault.spotPxUsdc();            // WAD USDC per HYPE
            // g (6dp) → WAD → divide by spot → HYPE WAD
            uint256 hypeForG = (g * 1e12) * 1e18 / spotPxWad;
            // forge-lint: disable-next-line(divide-before-multiply) -- intentional szDecimals floor
            flooredHype = (hypeForG / 1e16) * 1e16;            // tick = 0.01 HYPE = 1e16 WAD
            if (flooredHype > 0 && flooredHype <= vault.coverHype()) {
                // M3: do NOT read the return value — sellCover's return is an estimate.
                // MockCoverVault credits poolUsdc synchronously; CoreCoverVault is async (T9).
                vault.sellCover(flooredHype);
            }
            // Source payout from physical vault balance (M3 safety — never from sellCover return)
            require(vault.poolUsdc() >= g, "pool");
            // Credit trader; pool free (= poolUsdc − totalCollateral − putEscrow) decreases by g
            traderCollateral[s][t] += g;
            totalCollateral += g; // T6: keep Σ collateral in lockstep
            ss.netWritten -= p.qty;
            delete positions[s][t];
            // forge-lint: disable-next-line(unsafe-typecast)
            emit Closed(t, int256(g), flooredHype);
        } else {
            // ── Loss branch ──────────────────────────────────────────────────
            uint256 l = markLossU + fundingU - markGainU;
            if (l > traderCollateral[s][t]) l = traderCollateral[s][t]; // auto-settle floor
            traderCollateral[s][t] -= l;
            totalCollateral -= l; // T6: keep Σ collateral in lockstep
            // l implicitly accrues to pool free (poolUsdc unchanged; Σ traderCollateral drops)
            ss.netWritten -= p.qty;
            delete positions[s][t];
            // forge-lint: disable-next-line(unsafe-typecast)
            emit Closed(t, -int256(l), 0);
        }
    }

    /// @dev Internal: close a PUT position for trader `t` (port of EverlastingMarket._closeFor).
    ///
    ///      F2 (escrow-release-FIRST, no-false-revert): the put's qty·W escrow is released back to
    ///      poolFree BEFORE the payout is credited. Because any winning payout g is bounded by
    ///      qty·(mark−entryMark) ≤ qty·W = escrow (mark ≤ Wput is enforced at postMark), releasing
    ///      first guarantees poolFree ≥ g — the credit can never underflow poolFree / false-revert.
    ///
    ///      Shared pool: no vault cash moves on a put close. Only the logical ledgers rebalance —
    ///      putEscrow drops by the escrow, and (gain) collateral rises / poolFree falls by g, or
    ///      (loss) collateral falls / poolFree rises by l. Conservation holds by construction.
    ///
    ///      No int256 intermediate: gain/loss split kept in uint256; precision favours the pool.
    function _closePut(address t) internal {
        uint8 s = uint8(Side.PUT);
        SideState storage ss = sideState[s];
        Position memory p = positions[s][t];
        require(p.qty > 0, "no position");

        uint256 fundingU = _toUsdc(p.qty * (ss.cumFunding - p.entryCumFunding) / 1e18);

        // Mark PnL split in uint256 — avoids int256 intermediate (mirrors _closeFor)
        uint256 markGainU;
        uint256 markLossU;
        if (ss.mark >= p.entryMark) {
            markGainU = _toUsdc(p.qty * (ss.mark - p.entryMark) / 1e18);
        } else {
            markLossU = _toUsdc(p.qty * (p.entryMark - ss.mark) / 1e18);
        }

        // F2: release THIS put's escrow FIRST, so poolFree ≥ escrow ≥ g and the payout can't false-revert.
        uint256 escrow = _toUsdc(p.qty * Wput / 1e18);
        putEscrow -= escrow;

        if (markGainU >= markLossU + fundingU) {
            // ── Gain branch: trader net g (g ≤ markGainU ≤ escrow) ────────────
            uint256 g = markGainU - markLossU - fundingU;
            // Pool covers g from the just-released escrow; poolFree nets +escrow−g ≥ 0.
            traderCollateral[s][t] += g;
            totalCollateral += g;
            ss.netWritten -= p.qty;
            delete positions[s][t];
            // forge-lint: disable-next-line(unsafe-typecast)
            emit Closed(t, int256(g), 0);
        } else {
            // ── Loss branch: trader net −l, floored at collateral (auto-settle) ─
            uint256 l = markLossU + fundingU - markGainU;
            if (l > traderCollateral[s][t]) l = traderCollateral[s][t]; // auto-settle floor
            traderCollateral[s][t] -= l;
            totalCollateral -= l;
            // l accrues to poolFree; released escrow returns to poolFree too.
            ss.netWritten -= p.qty;
            delete positions[s][t];
            // forge-lint: disable-next-line(unsafe-typecast)
            emit Closed(t, -int256(l), 0);
        }
    }

    /// @notice Close msg.sender's position on the given side.
    function close(Side side) external {
        if (side == Side.PUT) {
            _closePut(msg.sender);
            return;
        }
        _closeCall(msg.sender);
    }

    /// @notice Permissionless force-close when the position's net loss exceeds collateral (I2).
    ///         Anyone may call this once a position is insolvent; keeper may call during mark updates.
    function settle(Side side, address t) external {
        require(positions[uint8(side)][t].qty > 0, "no position");
        require(netLossUsdc(side, t) > traderCollateral[uint8(side)][t], "solvent");
        if (side == Side.PUT) {
            _closePut(t);
            return;
        }
        _closeCall(t);
    }
}
