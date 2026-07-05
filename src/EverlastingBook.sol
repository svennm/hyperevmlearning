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

    // ── Utilization-premium funding (P(U), AmPO-style) ────────────────────────

    /// @notice WAD scalar (1e18).
    uint256 public constant WAD             = 1e18;
    /// @notice Ceiling on the funding surcharge multiplier κ (WAD).
    uint256 public constant MAX_UTIL_KAPPA  = 1e18;
    /// @notice Ceiling on the hard utilization cap uMax (0.95·WAD) — keeps (WAD−U)^3 > 0.
    uint256 public constant MAX_UMAX        = 95e16;
    /// @notice Clamp on the (divergent) call-side surcharge shape (WAD).
    uint256 public constant MAX_UTIL_SHAPE  = 1000e18;

    // ── Immutables ─────────────────────────────────────────────────────────────

    /// @notice Vault holding all USDC/HYPE collateral. The book holds no cash itself.
    ICoverVault public immutable vault;

    /// @notice Spot price oracle (WAD).
    ISpotOracle public immutable oracle;

    /// @notice Privileged address permitted to post marks (mutable; settable by owner).
    address public keeper;

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

    // ── Roles & pause switch (T8) ─────────────────────────────────────────────

    /// @notice Contract owner (single-LP pool operator). Set in constructor; transferable via 2-step.
    address public owner;

    /// @notice Pending owner during a 2-step transfer. Must call acceptOwnership() to promote.
    address public pendingOwner;

    /// @notice When true, openLong (both sides) reverts. Exit paths always remain open.
    bool public paused;

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

    // ── Utilization-premium params (owner-set, hard-capped; P(U)) ──────────────

    /// @notice Funding surcharge multiplier κ (WAD). Default 0 ⇒ surcharge OFF until owner activates.
    uint256 public utilKappa;

    /// @notice Hard utilization cap (WAD). Seeded to WAD in the constructor ⇒ no extra cap until the
    ///         owner tightens it. 0 would brick openLong, so setUMax rejects 0 and the ctor seeds WAD.
    uint256 public uMax;

    // ── Events ────────────────────────────────────────────────────────────────

    event Deposited(Side indexed side, address indexed trader, uint256 amt);
    event Opened(Side indexed side, address indexed trader, uint256 qty, uint256 mark);
    event MarkPosted(Side indexed side, uint256 mark, uint256 cumFunding);
    /// @notice Emitted on every close and settle.
    /// @param coverSold  HYPE WAD sold from cover to fund a winning payout (0 on loss branch).
    event Closed(address indexed trader, int256 net, uint256 coverSold);
    /// @notice Emitted when a trader withdraws free (position-closed) collateral out of the pool.
    event Withdrawn(Side indexed side, address indexed trader, uint256 amt);
    /// @notice Emitted when an LP deposits its OWN capital into pool-free USDC (raises poolFree).
    event LpDeposited(address indexed lp, uint256 amt);
    /// @notice Emitted when an LP withdraws pool-free USDC (lowers poolFree).
    event LpWithdrawn(address indexed lp, uint256 amt);
    // ── T8 admin events ───────────────────────────────────────────────────────
    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event KeeperChanged(address indexed oldKeeper, address indexed newKeeper);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    /// @notice Emitted by emergencyUnwindCover; hypeWad is the tick-floored amount sold.
    event EmergencyUnwind(uint256 hypeWad);
    /// @notice Emitted when the owner changes the utilization surcharge multiplier κ.
    event UtilKappaSet(uint256 oldKappa, uint256 newKappa);
    /// @notice Emitted when the owner changes the hard utilization cap uMax.
    event UMaxSet(uint256 oldUMax, uint256 newUMax);

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

        owner            = msg.sender;
        vault            = _vault;
        oracle           = _oracle;
        keeper           = _keeper;
        Kput             = _Kput;
        Wput             = _Wput;
        Kcall            = _Kcall;
        putCapNotional   = _putCapNotional;
        callCapNotional  = _callCapNotional;
        uMax             = WAD; // fail-safe: 0 would brick openLong's u-cap
    }

    // ── Modifiers (T8) ───────────────────────────────────────────────────────

    modifier onlyOwner() {
        require(msg.sender == owner, "only owner");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "paused");
        _;
    }

    // ── Admin functions (T8) ─────────────────────────────────────────────────

    /// @notice Update the keeper address (must be non-zero).
    function setKeeper(address newKeeper) external onlyOwner {
        require(newKeeper != address(0), "keeper=0");
        emit KeeperChanged(keeper, newKeeper);
        keeper = newKeeper;
    }

    /// @notice Set the funding surcharge multiplier κ (WAD). Owner only; hard-capped at MAX_UTIL_KAPPA.
    ///         κ=0 disables the surcharge (funding reverts to pure mark−intrinsic).
    function setUtilKappa(uint256 newKappa) external onlyOwner {
        require(newKappa <= MAX_UTIL_KAPPA, "kappa>max");
        emit UtilKappaSet(utilKappa, newKappa);
        utilKappa = newKappa;
    }

    /// @notice Set the hard utilization cap uMax (WAD). Owner only; must be in (0, MAX_UMAX].
    ///         Bounds U ≤ uMax at open, which enforces the survivability cap AND keeps the divergent
    ///         call surcharge curve finite. Never settable to 0 (would brick openLong).
    function setUMax(uint256 newUMax) external onlyOwner {
        require(newUMax > 0, "uMax=0");
        require(newUMax <= MAX_UMAX, "uMax>max");
        emit UMaxSet(uMax, newUMax);
        uMax = newUMax;
    }

    /// @notice Initiate a 2-step ownership transfer. Does NOT change owner until acceptOwnership().
    /// @dev OZ Ownable2Step semantics: no single-tx owner loss.
    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Complete the 2-step transfer. Callable only by pendingOwner.
    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "not pending");
        address oldOwner = owner;
        owner        = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(oldOwner, owner);
    }

    /// @notice Pause new openLong on both sides. Exit paths (close/settle/withdraw/lpWithdraw/
    ///         postMark/deposit) remain fully open — pause is a de-risk switch, never a fund trap.
    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Re-enable openLong on both sides.
    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Emergency wind-down: sell the entire cover position into the pool.
    /// @dev Owner-only; requires the market to be paused (no new opens possible).
    ///      Respects szDecimals=2 tick floor: sub-tick dust remains in coverHype.
    ///      After this call, any remaining open call positions can still be closed — their payouts
    ///      will be sourced from poolFree() (replenished by the proceeds of this cover sale).
    function emergencyUnwindCover() external onlyOwner {
        require(paused, "not paused");
        uint256 ch = vault.coverHype();
        // forge-lint: disable-next-line(divide-before-multiply) -- intentional floor-to-tick
        uint256 flooredCoverHype = (ch / 1e16) * 1e16;
        if (flooredCoverHype > 0) {
            vault.sellCover(flooredCoverHype);
        }
        emit EmergencyUnwind(flooredCoverHype);
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

    // ── Utilization surcharge (P(U), AmPO-style; on-chain, references no oracle) ──

    /// @notice Current utilization U = netWritten/cap for the given side (WAD, ∈[0,WAD]).
    /// @dev Internal pool state only (open interest over capacity) — no price input.
    function utilization(Side side) public view returns (uint256 U) {
        uint256 cap = side == Side.PUT ? putCapNotional : callCapNotional;
        if (cap == 0) return 0;
        U = sideState[uint8(side)].netWritten * WAD / cap;
        if (U > WAD) U = WAD;
    }

    /// @notice Per-period funding surcharge κ·P(U) for the given side (WAD). PUT: P=U (linear,
    ///         ceiling at U=1). CALL: P=2U/(1−U)^3 (divergent), clamped at MAX_UTIL_SHAPE. Returns 0
    ///         when utilKappa==0 or U==0. Purely a function of internal state — references no oracle.
    /// @dev WAD math: shape_call = 2·U·WAD^3/(WAD−U)^3, rescaled by (1e6)^3=1e18 in the denominator so
    ///      intermediates stay < 2^256 and near-saturation rounds the denominator to 0 → clamp. The
    ///      hard uMax cap + MAX_UMAX keep U<WAD in normal flow; the clamp is belt-and-suspenders.
    function _utilSurcharge(Side side) internal view returns (uint256) {
        if (utilKappa == 0) return 0; // no-op fast path: change is inert until owner activates
        uint256 U = utilization(side);
        if (U == 0) return 0;

        uint256 shape;
        if (side == Side.PUT) {
            shape = U; // linear: P_put(U) = U
        } else if (U >= WAD) {
            shape = MAX_UTIL_SHAPE;
        } else {
            // forge-lint: disable-next-line(divide-before-multiply) -- intentional rescale-then-cube
            uint256 denom = (WAD - U) / 1e6;
            denom = denom * denom * denom; // = (WAD−U)^3 / 1e18
            if (denom == 0) {
                shape = MAX_UTIL_SHAPE; // near-saturation: denom rounded to 0 → clamp
            } else {
                uint256 num = 2 * U * 1e36; // = 2·U·WAD^3 / 1e18; ≤ 2e54 < 2^256
                shape = num / denom;        // = 2·U·WAD^3 / (WAD−U)^3
                if (shape > MAX_UTIL_SHAPE) shape = MAX_UTIL_SHAPE;
            }
        }
        return utilKappa * shape / WAD;
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
    function openLong(Side side, uint256 qty) external whenNotPaused {
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
            // Hard utilization cap: netWritten ≤ uMax·cap. Overflow-safe: netWritten·WAD ≤ ~1e38.
            // forge-lint: disable-next-line(divide-before-multiply) -- intentional cross-multiply
            require(ps.netWritten * WAD <= uMax * putCapNotional, "u-cap");

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
        // Hard utilization cap: (netWritten+qty) ≤ uMax·cap. Overflow-safe: ·WAD ≤ ~1e38.
        // forge-lint: disable-next-line(divide-before-multiply) -- intentional cross-multiply
        require((ss.netWritten + qty) * WAD <= uMax * callCapNotional, "u-cap");

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
                f += _utilSurcharge(side); // P(U): endogenous concentration surcharge (0 when κ=0)
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

        uint256 coverSoldHype; // set in gain branch; stays 0 on loss branch

        if (markGainU >= markLossU + fundingU) {
            // ── Gain branch ──────────────────────────────────────────────────
            uint256 g = markGainU - markLossU - fundingU;
            if (g > 0) {
                // I3: realize g by selling cover HYPE → USDC into the pool.
                uint256 spotPxWad = vault.spotPxUsdc();        // WAD USDC per HYPE
                // g (6dp) → WAD → divide by spot → HYPE WAD needed to raise exactly g.
                uint256 hypeForG = (g * 1e12) * 1e18 / spotPxWad;
                // T7 tick-dust fix: CEIL to the szDecimals=2 tick (NOT floor). Flooring retained the
                // sub-tick HYPE as cover dust while the payout debited a full g, eroding poolFree() by
                // (g − proceeds) < 1 tick on every winning close — a slow LIVENESS leak a long fuzz
                // drives to underflow-revert. Ceiling sells one extra sub-tick so proceeds P ≥ g and
                // the pool keeps the excess as FREE USDC; poolFree() is never eroded. Value conserved.
                // forge-lint: disable-next-line(divide-before-multiply) -- intentional ceil-to-tick
                uint256 sellHype = ((hypeForG + 1e16 - 1) / 1e16) * 1e16; // tick = 0.01 HYPE = 1e16 WAD
                // coverGate guard: never sell cover still backing OTHER open calls. Cap the sale at
                // the surplus over netWritten_after (= ss.netWritten − p.qty), so coverHype − sellHype
                // ≥ netWritten_after and `coverHype ≥ callNetWritten` is preserved. In normal operation,
                // coverGate holds pre-close ⇒ coverHype ≥ ss.netWritten ≥ netWritten_after, so maxSell
                // ≥ p.qty ≥ 0 (no underflow). After emergencyUnwindCover(), coverHype ≈ 0 while
                // netWritten_after may be positive — clamp to 0 instead of underflowing so the winner
                // can still close with the payout sourced from poolFree() (replenished by the cover
                // sale proceeds). Normal-flow arithmetic is unchanged: ch > rem is always true when
                // coverGate holds pre-close. Floor the cap to a whole tick so sellCover transacts cleanly.
                uint256 ch  = vault.coverHype();
                uint256 rem = ss.netWritten - p.qty; // p.qty <= ss.netWritten for an open position
                uint256 maxSell = ch > rem ? ch - rem : 0;
                // forge-lint: disable-next-line(divide-before-multiply) -- intentional floor-to-tick
                if (sellHype > maxSell) sellHype = (maxSell / 1e16) * 1e16;
                coverSoldHype = sellHype;
                if (sellHype > 0) {
                    // M3: do NOT read the return value — sellCover's return is an estimate.
                    // MockCoverVault credits poolUsdc synchronously; CoreCoverVault is async (T9).
                    vault.sellCover(sellHype);
                }
                // Fail-closed solvency guard: pay g from the pool's OWN free USDC (now replenished by
                // the cover sale). poolFree() ≥ g ⟺ poolUsdc ≥ totalCollateral + putEscrow + g, so
                // crediting g leaves poolFree() ≥ 0 (the conservation invariant). Reverts rather than
                // dip into another party's collateral/escrow when cover is exhausted and P < g.
                require(poolFree() >= g, "pool");
            }
            // Credit trader; pool free decreases by g (offset by the cover-sale proceeds credited above).
            traderCollateral[s][t] += g;
            totalCollateral += g; // T6: keep Σ collateral in lockstep
            ss.netWritten -= p.qty;
            delete positions[s][t];
            // forge-lint: disable-next-line(unsafe-typecast)
            emit Closed(t, int256(g), coverSoldHype);
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

    // ── Withdraw (T7) ───────────────────────────────────────────────────────────

    /// @notice Withdraw free (position-closed) trader collateral out of the pool.
    /// @dev Guarded by the position-closed check: an open position's margin is committed and
    ///      cannot leave. Conservation-neutral: poolUsdc and totalCollateral both fall by `amt`,
    ///      so poolFree() and the identity poolUsdc == poolFree + putEscrow + totalCollateral are
    ///      preserved. `amt > collateral` underflow-reverts on the collateral debit (fail-closed),
    ///      and the trader's own collateral is physically part of poolUsdc so payoutUsdc can't short.
    function withdraw(Side side, uint256 amt) external {
        require(positions[uint8(side)][msg.sender].qty == 0, "open position");
        traderCollateral[uint8(side)][msg.sender] -= amt; // reverts if amt > collateral
        totalCollateral -= amt;
        vault.payoutUsdc(msg.sender, amt);
        emit Withdrawn(side, msg.sender, amt);
    }

    // ── LP pool-free liquidity (T7) ─────────────────────────────────────────────

    /// @notice Deposit the LP's OWN capital as pool-free USDC (distinct from trader collateral).
    /// @dev Physical USDC up, NO trader claim recorded — so poolFree() rises by `amt`. This is the
    ///      capital that backs put escrow and replenishes winning-call payouts. Conservation holds:
    ///      poolUsdc rises by `amt`, poolFree rises by `amt`, totalCollateral/putEscrow unchanged.
    function lpDeposit(uint256 amt) external onlyOwner {
        vault.pullUsdc(msg.sender, amt);
        emit LpDeposited(msg.sender, amt);
    }

    /// @notice Withdraw pool-free USDC (the pool's own uncommitted capital).
    /// @dev Only poolFree() may leave — trader collateral and put escrow are off-limits. Conservation
    ///      holds: poolUsdc falls by `amt`, poolFree falls by `amt`, totalCollateral/putEscrow flat.
    function lpWithdraw(uint256 amt) external onlyOwner {
        require(poolFree() >= amt, "pool-free");
        // Call-backing guard (M1): when covered calls are open but the cover no longer backs them 1:1
        // — i.e. after emergencyUnwindCover has converted cover→poolFree — that poolFree IS the open
        // call-winners' backing and must NOT be withdrawable, or the owner could strand their payouts.
        // Normal operation is unaffected: the cover-gate holds (coverHype ≥ callNetWritten) so this
        // passes; it only bites in the post-unwind window until those under-backed calls resolve.
        uint256 callNW = sideState[uint8(Side.COVERED_CALL)].netWritten;
        require(callNW == 0 || vault.coverHype() >= callNW, "call backing");
        vault.payoutUsdc(msg.sender, amt);
        emit LpWithdrawn(msg.sender, amt);
    }
}
