// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {CoreWriterLib} from "@hyper-evm-lib/src/CoreWriterLib.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";
import {HLConstants} from "@hyper-evm-lib/src/common/HLConstants.sol";

/// @title PerpCoverSpike — THROWAWAY Slice-3b spike (NOT production)
/// @notice De-risks the Slice-3b covered-call cover leg: verifies that a HyperEVM *contract* can
///         open / read / close a 1x long HYPE perp "cover" via CoreWriter under a unified account,
///         and lets us observe the real margin, fees, fill delay and PnL→USDC settlement that the
///         docs don't specify. Findings dictate the real CoveredCallMarket3b funding design.
/// @dev Encoding facts pinned from hyper-evm-lib's own PerpTradingTest + live testnet meta:
///      - Main perp dex (dex 0): order asset id == read perp index == 135 (HYPE). The 100000+
///        HIP-3 offset applies ONLY to builder dexes (e.g. NVDA on xyz: order 110002 / read 10002).
///      - Order `sz` is coins*1e8; PrecompileLib position.szi is coins*10^szDecimals (HYPE=2).
///      - Marketable order = IOC with limitPx pushed through the book (buy: above ask; sell: below bid).
///      - CoreWriter is fire-and-forget: the order lands on a later Core block, so reads right after
///        a write may still show the pre-fill state. Poll coverPosition()/withdrawable() a block later.
contract PerpCoverSpike {
    uint32 public constant HYPE_PERP = 135;

    address public immutable owner;
    uint128 public cloidSeq;

    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "only owner");
        _;
    }

    // ── account mode ─────────────────────────────────────────────────────────
    /// Set this contract's HyperCore account to unifiedAccount (2) so spot USDC directly
    /// collateralizes the perp — no spot→perp transfer needed. Idempotent-ish; observe effect.
    function setUnified() external onlyOwner {
        CoreWriterLib.setAbstraction(address(this), 2);
    }

    /// Fallback path if the contract account is NOT unified: move `usdcNtl` (perp USDC, 6dp wire
    /// units) from spot to perp so it can margin the cover.
    function transferToPerp(uint64 usdcNtl) external onlyOwner {
        CoreWriterLib.transferUsdClass(usdcNtl, true);
    }

    // ── cover ops ────────────────────────────────────────────────────────────
    /// Open (increase) the long HYPE cover. `sz` = coins*1e8. `limitPx` in mark wire units,
    /// set above the ask for a marketable IOC buy.
    function openCover(uint64 sz, uint64 limitPx) external onlyOwner {
        CoreWriterLib.placeLimitOrder(
            HYPE_PERP, true, limitPx, sz, false, HLConstants.LIMIT_ORDER_TIF_IOC, ++cloidSeq
        );
    }

    /// Reduce/close the cover. reduceOnly sell. `sz` = coins*1e8. `limitPx` set below the bid
    /// (or 0) for a marketable IOC sell.
    function closeCover(uint64 sz, uint64 limitPx) external onlyOwner {
        CoreWriterLib.placeLimitOrder(
            HYPE_PERP, false, limitPx, sz, true, HLConstants.LIMIT_ORDER_TIF_IOC, ++cloidSeq
        );
    }

    // ── rescue (throwaway funds recovery) ────────────────────────────────────
    /// Send USDC out of this contract's Core spot balance (e.g. back to the funder).
    function spotSendUsdc(address to, uint64 amountWei) external onlyOwner {
        CoreWriterLib.spotSend(to, HLConstants.USDC_TOKEN_INDEX, amountWei);
    }

    receive() external payable {}

    /// Sweep EVM HYPE (gas) back out.
    function sweepHype(address payable to) external onlyOwner {
        (bool ok,) = to.call{value: address(this).balance}("");
        require(ok, "sweep");
    }

    // ── views (observation) ──────────────────────────────────────────────────
    function markPx() external view returns (uint64) {
        return PrecompileLib.markPx(HYPE_PERP);
    }

    function oraclePx() external view returns (uint64) {
        return PrecompileLib.oraclePx(HYPE_PERP);
    }

    function coverPosition() external view returns (PrecompileLib.Position memory) {
        return PrecompileLib.position(address(this), HYPE_PERP);
    }

    function withdrawableUsdc() external view returns (uint64) {
        return PrecompileLib.withdrawable(address(this));
    }

    function margin() external view returns (PrecompileLib.AccountMarginSummary memory) {
        return PrecompileLib.accountMarginSummary(HLConstants.DEFAULT_PERP_DEX, address(this));
    }

    function coreExists() external view returns (bool) {
        return PrecompileLib.coreUserExists(address(this));
    }
}
