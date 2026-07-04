// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ICoverVault} from "../interfaces/ICoverVault.sol";

/// @title MockCoverVault
/// @notice Pure-Foundry test double for ICoverVault.
///         Maintains internal ledgers only — no real ERC20, no CoreWriter, no HyperCore.
///         `setMockPx` wires the price oracle; all accounting follows the seam spec exactly.
///
/// @dev HYPE szDecimals = 2: the exchange only accepts 0.01-HYPE increments.
///      `sellCover` floors the requested WAD amount to the nearest 1e16 tick; the
///      sub-tick remainder stays in `coverHype` as unsellable dust. Callers must tolerate it.
contract MockCoverVault is ICoverVault {
    // ── Constants ─────────────────────────────────────────────────────────────

    uint256 internal constant WAD       = 1e18;
    /// @dev 0.01 HYPE expressed as WAD — the minimum tradable increment (szDecimals=2)
    uint256 internal constant HYPE_TICK = 1e16;

    // ── State ─────────────────────────────────────────────────────────────────

    /// @inheritdoc ICoverVault
    uint256 public poolUsdc;   // 6dp

    /// @inheritdoc ICoverVault
    uint256 public coverHype;  // WAD

    /// @dev Settable mock price: USDC per HYPE, expressed as WAD
    uint256 private _mockPx;

    // ── Admin ─────────────────────────────────────────────────────────────────

    /// @notice Set the mock spot price (WAD, e.g. 20e18 == $20/HYPE).
    function setMockPx(uint256 pxWad) external {
        _mockPx = pxWad;
    }

    // ── ICoverVault: view ─────────────────────────────────────────────────────

    /// @inheritdoc ICoverVault
    function spotPxUsdc() external view returns (uint256) {
        return _mockPx;
    }

    /// @inheritdoc ICoverVault
    /// @dev coverEquityUsdc = _toUsdc(coverHype * mockPx / WAD)
    function coverEquityUsdc() external view returns (uint256) {
        return _toUsdc(coverHype * _mockPx / WAD);
    }

    // ── ICoverVault: mutating ─────────────────────────────────────────────────

    /// @inheritdoc ICoverVault
    /// @dev cost = _toUsdc(hypeWad * mockPx / WAD). Reverts on slippage or pool short.
    function buyCover(uint256 hypeWad, uint256 maxUsdc) external {
        require(hypeWad > 0, "qty=0");
        uint256 cost = _toUsdc(hypeWad * _mockPx / WAD);
        require(cost <= maxUsdc, "slippage");
        require(poolUsdc >= cost, "pool: insufficient");
        poolUsdc -= cost;
        coverHype += hypeWad;
    }

    /// @inheritdoc ICoverVault
    /// @dev Floors hypeWad to the nearest HYPE_TICK (0.01 HYPE = 1e16 WAD).
    ///      Only the floored amount is deducted from coverHype; the sub-tick remainder
    ///      stays in coverHype as dust — this is the intended szDecimals=2 behavior.
    function sellCover(uint256 hypeWad) external returns (uint256 usdcOut) {
        // forge-lint: disable-next-line(divide-before-multiply) -- intentional floor-to-tick
        uint256 floored = (hypeWad / HYPE_TICK) * HYPE_TICK;
        require(floored > 0, "qty: below min tick");
        require(coverHype >= floored, "cover: insufficient");
        usdcOut = _toUsdc(floored * _mockPx / WAD);
        coverHype -= floored;
        poolUsdc  += usdcOut;
    }

    /// @inheritdoc ICoverVault
    /// @dev In the mock the `to` address is ignored (no real ERC20); only the ledger moves.
    function payoutUsdc(address /*to*/, uint256 amt) external {
        require(poolUsdc >= amt, "pool: insufficient");
        poolUsdc -= amt;
    }

    /// @inheritdoc ICoverVault
    /// @dev In the mock the `from` address is ignored (no real ERC20); only the ledger moves.
    function pullUsdc(address /*from*/, uint256 amt) external {
        poolUsdc += amt;
    }

    // ── Internal ──────────────────────────────────────────────────────────────

    /// @dev WAD → USDC 6dp. Matches CoveredCallMarket._toUsdc exactly.
    function _toUsdc(uint256 wad) internal pure returns (uint256) {
        return wad / 1e12;
    }
}
