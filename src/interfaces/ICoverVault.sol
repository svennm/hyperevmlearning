// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @title ICoverVault
/// @notice Collateral-adapter seam between option accounting and the Core collateral layer.
///         All USDC values are 6dp; all HYPE quantities are WAD (1e18).
///         Implementations back this with either a pure-Foundry ledger (MockCoverVault)
///         or a real CoreWriter-backed vault (Task 2).
interface ICoverVault {
    // ── View ──────────────────────────────────────────────────────────────────

    /// @notice USDC held in the pool (6dp)
    function poolUsdc() external view returns (uint256);

    /// @notice HYPE held as cover collateral (WAD)
    function coverHype() external view returns (uint256);

    /// @notice Value of the cover position in USDC (6dp).
    ///         Defined as: _toUsdc(coverHype * spotPxUsdc / WAD)
    function coverEquityUsdc() external view returns (uint256);

    /// @notice Current HYPE spot price expressed as WAD (e.g. 20e18 == $20/HYPE).
    ///         Denominated in USDC; callers apply _toUsdc() themselves for 6dp conversion.
    function spotPxUsdc() external view returns (uint256);

    // ── Mutating ──────────────────────────────────────────────────────────────

    /// @notice Buy HYPE cover: debit poolUsdc, credit coverHype at spotPx.
    /// @param hypeWad  Amount of HYPE to acquire (WAD)
    /// @param maxUsdc  Maximum USDC willing to spend; reverts on slippage (6dp)
    function buyCover(uint256 hypeWad, uint256 maxUsdc) external;

    /// @notice Sell HYPE cover: floor hypeWad to HYPE szDecimals=2 (nearest 0.01 HYPE),
    ///         credit poolUsdc with proceeds at spotPx.
    ///         Sub-tick dust is left in coverHype — callers MUST tolerate this.
    /// @param hypeWad  Amount of HYPE to sell (WAD); floored to nearest 1e16 increment
    /// @return usdcOut USDC credited to pool (6dp), computed on the floored amount
    function sellCover(uint256 hypeWad) external returns (uint256 usdcOut);

    /// @notice Transfer USDC out of pool (e.g. option payout to trader).
    /// @param to   Recipient address (semantics are implementation-defined in mock)
    /// @param amt  Amount in USDC (6dp)
    function payoutUsdc(address to, uint256 amt) external;

    /// @notice Accept USDC into pool (e.g. trader deposit / collateral top-up).
    /// @param from  Source address (semantics are implementation-defined in mock)
    /// @param amt   Amount in USDC (6dp)
    function pullUsdc(address from, uint256 amt) external;
}
