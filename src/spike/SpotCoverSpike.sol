// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {CoreWriterLib} from "@hyper-evm-lib/src/CoreWriterLib.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";
import {HLConstants} from "@hyper-evm-lib/src/common/HLConstants.sol";

/// @title SpotCoverSpike — THROWAWAY Slice-3b spike (NOT production)
/// @notice Verifies the CHOSEN 3b cover: a HyperEVM *contract* buys and holds **spot HYPE** as the
///         covered-call cover (own the underlying → no leverage, no liquidation, ever), and can sell
///         it back to USDC on a payout. This maps 1:1 to what CoveredCallMarket3b will do; the perp
///         path was rejected because a contract-opened perp is stuck isolated-10x and liquidatable
///         (CoreWriter has no leverage/margin-mode action). See
///         docs/research/2026-07-03-perp-cover-spike-findings.md.
/// @dev Encoding (from the perp spike + HL docs, re-verified live for spot):
///      - HYPE/USDC canonical spot pair index = 1035 → order asset id = 10000 + 1035 = 11035.
///      - HYPE token index = 1105 (weiDecimals 8); USDC token index = 0.
///      - CoreWriter limit order `limitPx` and `sz` are BOTH human*1e8 (buy HYPE: sz = HYPE*1e8,
///        limitPx = USDC-per-HYPE * 1e8, set above the ask for a marketable IOC buy).
///      - spotBalance.total is in token wei (HYPE weiDecimals 8), so `total` is already HYPE*1e8 —
///        i.e. to sell the whole holding, pass sz = hypeBalance().total.
///      - CoreWriter is fire-and-forget: fills land a Core block later; poll balances.
contract SpotCoverSpike {
    uint32 public constant HYPE_SPOT_ASSET = 11035; // order asset id (10000 + pair index 1035)
    uint32 public constant HYPE_SPOT_INDEX = 1035;  // for spotPx read
    uint64 public constant HYPE_TOKEN = 1105;
    uint64 public constant USDC_TOKEN = 0;

    address public immutable owner;
    uint128 public cloidSeq;

    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "only owner");
        _;
    }

    // ── cover ops ────────────────────────────────────────────────────────────
    /// Buy spot HYPE cover with USDC. Both args human*1e8: `sz` = HYPE*1e8,
    /// `limitPx` = USDC/HYPE * 1e8, set above the ask for a marketable IOC buy.
    function buyCover(uint64 sz, uint64 limitPx) external onlyOwner {
        CoreWriterLib.placeLimitOrder(
            HYPE_SPOT_ASSET, true, limitPx, sz, false, HLConstants.LIMIT_ORDER_TIF_IOC, ++cloidSeq
        );
    }

    /// Sell spot HYPE cover back to USDC. Both args human*1e8; set `limitPx` below the bid for a
    /// marketable IOC sell. Pass sz = hypeBalance().total to unwind the whole holding.
    function sellCover(uint64 sz, uint64 limitPx) external onlyOwner {
        CoreWriterLib.placeLimitOrder(
            HYPE_SPOT_ASSET, false, limitPx, sz, false, HLConstants.LIMIT_ORDER_TIF_IOC, ++cloidSeq
        );
    }

    // ── rescue (throwaway funds recovery) ────────────────────────────────────
    function spotSendUsdc(address to, uint64 amountWei) external onlyOwner {
        CoreWriterLib.spotSend(to, USDC_TOKEN, amountWei);
    }

    function spotSendHype(address to, uint64 amountWei) external onlyOwner {
        CoreWriterLib.spotSend(to, HYPE_TOKEN, amountWei);
    }

    receive() external payable {}

    /// Sweep EVM HYPE (gas) back out.
    function sweepHype(address payable to) external onlyOwner {
        (bool ok,) = to.call{value: address(this).balance}("");
        require(ok, "sweep");
    }

    // ── views (observation) ──────────────────────────────────────────────────
    function spotPxHype() external view returns (uint64) {
        return PrecompileLib.spotPx(HYPE_SPOT_INDEX);
    }

    function hypeBalance() external view returns (PrecompileLib.SpotBalance memory) {
        return PrecompileLib.spotBalance(address(this), HYPE_TOKEN);
    }

    function usdcBalance() external view returns (PrecompileLib.SpotBalance memory) {
        return PrecompileLib.spotBalance(address(this), USDC_TOKEN);
    }

    function coreExists() external view returns (bool) {
        return PrecompileLib.coreUserExists(address(this));
    }
}
