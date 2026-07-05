// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ICoverVault} from "./interfaces/ICoverVault.sol";

/// @title DeltaHedgeManager
/// @notice TIER 1 ONLY — trustless, on-chain spot-cover-trim delta module for the everlasting-options
///         venue. Reads an `EverlastingBook` (open interest, strikes, poolFree, oracle) and an
///         `ICoverVault` (spot HYPE cover) to provide net-delta accounting plus a keeper-gated
///         spot-cover trim/add lever that sheds the pool's excess-cover +delta toward the solvency floor.
///
/// @dev SCOPE: Tier 2 (off-chain-signed cross/1x perp short via an approved API wallet) is DEFERRED and
///      intentionally NOT present here — no perp, no CoreWriter of our own, no off-chain-agent seam.
///      With no agent, the manager is fully trustless. See `docs`/design §3 for the two-tier rationale.
///
/// @dev HARD CONSTRAINTS (from the repo — enforced below):
///      - CoreWriter fills are ASYNC / fire-and-forget: NEVER assume a submitted trim is filled. The
///        trim effect is lagged and realizes only when the Core block settles. All reads here are of
///        SETTLED state (vault.coverHype(), book.sideState) — verify-don't-assume.
///      - Only `poolFree()` capital may ever be spent — NEVER putEscrow or traderCollateral.
///      - coverGate `coverHype >= callNetWritten` must hold after any trim (even a full fill).
///
/// @dev Delta sign convention (WAD, +long / -short, HYPE units) — design §2.1:
///        Δ = coverHype − Qc·δc + Qp·δp     (Qc = COVERED_CALL netWritten, Qp = PUT netWritten)
///      Model A on-chain indicator delta (§2.3): δc = 1{S > Kcall}; δp = 1{(Kput−Wput) < S < Kput}.
///      Discontinuous at the strikes (whipsaw) and time-value-blind — a coarse on-chain bound, not the
///      keeper's sizing model. Good enough for the trustless trim lever and the structural safety rail.

/// @notice Minimal view surface of EverlastingBook consumed by the hedge manager.
interface IEverlastingBook {
    /// @dev Public mapping getter. Side index: PUT = 0, COVERED_CALL = 1. We use `netWritten` (5th).
    function sideState(uint8)
        external
        view
        returns (uint256 mark, uint256 lastMarkTime, uint256 cumFunding, uint256 lastIntrinsic, uint256 netWritten);
    /// @dev Pool's own uncommitted USDC (6dp). REVERTS on underflow — that revert IS the solvency
    ///      guard that putEscrow/traderCollateral are not breached.
    function poolFree() external view returns (uint256);
    function Kput() external view returns (uint256);
    function Wput() external view returns (uint256);
    function Kcall() external view returns (uint256);
    /// @dev The book's spot oracle; we price moneyness off the SAME oracle the book uses for intrinsic.
    function oracle() external view returns (address);
}

interface ISpotOracle {
    function spotWad() external view returns (uint256);
}

contract DeltaHedgeManager {
    // ── Constants ─────────────────────────────────────────────────────────────
    uint256 internal constant WAD = 1e18;
    uint8 internal constant PUT_SIDE = 0;   // Side.PUT
    uint8 internal constant CALL_SIDE = 1;  // Side.COVERED_CALL

    // ── Wiring ────────────────────────────────────────────────────────────────
    IEverlastingBook public immutable book;
    ICoverVault public immutable vault;
    address public immutable owner;
    /// @notice Operator permitted to move the trim/add lever. NOTE: for the vault's own onlyKeeper gate
    ///         on sellCover/buyCover to pass, THIS contract must additionally be authorized as a vault
    ///         keeper (external wiring — not handled here).
    address public keeper;

    // ── Events (design §5) ──────────────────────────────────────────────────────
    event CoverTrimmed(uint256 hypeWad, int256 newNetDelta);
    event CoverBufferAdded(uint256 hypeWad, uint256 usdcSpent, int256 newNetDelta);
    event KeeperChanged(address indexed oldKeeper, address indexed newKeeper);

    // ── Modifiers ───────────────────────────────────────────────────────────────
    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    modifier onlyKeeper() {
        require(msg.sender == owner || msg.sender == keeper, "not keeper");
        _;
    }

    constructor(IEverlastingBook _book, ICoverVault _vault, address _keeper) {
        require(address(_book) != address(0), "book zero");
        require(address(_vault) != address(0), "vault zero");
        require(_keeper != address(0), "keeper zero");
        book = _book;
        vault = _vault;
        owner = msg.sender;
        keeper = _keeper;
    }

    /// @notice Transfer the keeper role (owner only).
    function setKeeper(address _keeper) external onlyOwner {
        require(_keeper != address(0), "keeper zero");
        emit KeeperChanged(keeper, _keeper);
        keeper = _keeper;
    }

    // ── Net-delta accounting (views) ────────────────────────────────────────────

    /// @notice Pool net HYPE delta (WAD, signed, +long / −short) under the Model-A indicator delta.
    /// @dev    Δ = coverHype − Qc·1{S>Kcall} + Qp·1{(Kput−Wput)<S<Kput}. Reads SETTLED state only.
    function poolNetDelta() public view returns (int256 deltaHypeWad) {
        uint256 H = vault.coverHype();
        uint256 Qc = _callNetWritten();
        uint256 Qp = _putNetWritten();
        uint256 S = _spot();

        // forge-lint: disable-next-line(unsafe-typecast)
        int256 d = int256(H);
        if (S > book.Kcall()) {
            // forge-lint: disable-next-line(unsafe-typecast)
            d -= int256(Qc); // short call: −delta once ITM
        }

        uint256 kput = book.Kput();
        uint256 wput = book.Wput();
        uint256 putLo = kput > wput ? kput - wput : 0; // guard: avoids 0.8 underflow if Wput > Kput
        if (S > putLo && S < kput) {
            // forge-lint: disable-next-line(unsafe-typecast)
            d += int256(Qp); // short put: +delta in the linear (uncapped) region
        }

        return d;
    }

    /// @notice Model-free structural envelope [H−Qc, H+Qp] (WAD). Under the coverGate (H≥Qc) both
    ///         endpoints are ≥ 0; computed signed and honestly (not forced) so a transient async gate
    ///         dip surfaces as a negative `lo` rather than being masked.
    function deltaBounds() public view returns (int256 lo, int256 hi) {
        uint256 H = vault.coverHype();
        // forge-lint: disable-next-line(unsafe-typecast)
        lo = int256(H) - int256(_callNetWritten());
        // forge-lint: disable-next-line(unsafe-typecast)
        hi = int256(H) + int256(_putNetWritten());
    }

    // ── Tier 1: on-chain spot-cover trim lever (trustless, long-only reduction) ──

    /// @notice Keeper sells cover HYPE toward the Qc solvency floor to shed +delta (the core Tier-1 lever).
    /// @dev    Reverts if a FULL fill would breach the coverGate (`coverHype − hypeWad < callNetWritten`).
    ///         H and Qc are read FRESH (settled) — no optimistic local state.
    ///         ASYNC: `sellCover` is CoreWriter fire-and-forget; the emitted `newNetDelta` is the CURRENT
    ///         (pre-settlement) value — the trim reduces delta by up to `hypeWad` only once the Core block
    ///         settles. Do NOT treat the submitted trim as filled.
    function trimCoverForDelta(uint256 hypeWad) external onlyKeeper {
        require(hypeWad > 0, "qty=0");

        uint256 H = vault.coverHype();
        uint256 Qc = _callNetWritten();

        // Conservative coverGate floor: even a full fill must leave coverHype ≥ callNetWritten.
        require(H >= Qc + hypeWad, "coverGate floor");

        vault.sellCover(hypeWad);
        emit CoverTrimmed(hypeWad, poolNetDelta());
    }

    /// @notice Keeper buys cover back to restore the async-robustness buffer / raise +delta.
    /// @dev    Spends `poolFree()` ONLY: requiring `poolFree ≥ maxUsdc` (buyCover spends at most maxUsdc)
    ///         guarantees the buy can never touch putEscrow/traderCollateral. `maxUsdc` is the AUTHORIZED
    ///         cap; actual USDC spent is async/estimated at the vault. ASYNC fill — do not assume.
    function addCoverBuffer(uint256 hypeWad, uint256 maxUsdc) external onlyKeeper {
        require(hypeWad > 0, "qty=0");
        require(book.poolFree() >= maxUsdc, "poolFree");

        vault.buyCover(hypeWad, maxUsdc);
        emit CoverBufferAdded(hypeWad, maxUsdc, poolNetDelta());
    }

    // ── Solvency guard ──────────────────────────────────────────────────────────

    /// @notice Reverts unless the hedge state keeps the two load-bearing invariants:
    ///         (a) coverGate `coverHype ≥ callNetWritten`; and
    ///         (b) poolFree solvency — putEscrow/traderCollateral not breached (poolFree() underflow-reverts).
    function assertHedgeInvariants() external view {
        require(vault.coverHype() >= _callNetWritten(), "coverGate");
        book.poolFree(); // reverts on underflow ⇒ putEscrow/traderCollateral intact
    }

    // ── Internal reads (DRY, all settled state) ─────────────────────────────────

    function _callNetWritten() internal view returns (uint256) {
        (,,,, uint256 netWritten) = book.sideState(CALL_SIDE);
        return netWritten;
    }

    function _putNetWritten() internal view returns (uint256) {
        (,,,, uint256 netWritten) = book.sideState(PUT_SIDE);
        return netWritten;
    }

    function _spot() internal view returns (uint256) {
        return ISpotOracle(book.oracle()).spotWad();
    }
}
