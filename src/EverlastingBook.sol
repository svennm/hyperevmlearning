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
}
