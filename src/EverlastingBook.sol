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

    // ── Events ────────────────────────────────────────────────────────────────

    event Deposited(Side indexed side, address indexed trader, uint256 amt);
    event Opened(Side indexed side, address indexed trader, uint256 qty, uint256 mark);
    event MarkPosted(Side indexed side, uint256 mark, uint256 cumFunding);

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
        emit Deposited(side, msg.sender, amt);
    }

    // ── openLong ──────────────────────────────────────────────────────────────

    /// @notice Open a long position on the given side.
    /// @dev PUT: temporary placeholder — T6 implements.
    ///      COVERED_CALL: fresh mark required, one position per (side, trader), premium IM check,
    ///      D3 cover gate reads vault.coverHype() on-chain (not optimistic local state), cap check.
    function openLong(Side side, uint256 qty) external {
        if (side == Side.PUT) revert("put: enabled in T6");

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
    /// @dev PUT: temporary placeholder — T6 implements.
    ///      COVERED_CALL: keeper-gated, uncapped (no ≤W), deviation + recoverable-staleness guards,
    ///      F3 funding advance using contemporaneous lastIntrinsic.
    function postMark(Side side, uint256 newMark) external {
        require(msg.sender == keeper, "only keeper");
        if (side == Side.PUT) revert("put: enabled in T6");

        // COVERED_CALL branch
        SideState storage ss = sideState[uint8(side)];
        uint256 intr = intrinsic(side);
        require(newMark >= intr, "mark<intrinsic");

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
}
