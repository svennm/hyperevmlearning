// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ICoverVault} from "./interfaces/ICoverVault.sol";
import {CoreWriterLib} from "@hyper-evm-lib/src/CoreWriterLib.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";
import {HLConstants} from "@hyper-evm-lib/src/common/HLConstants.sol";

/// @title CoreCoverVault
/// @notice `ICoverVault` implementation backed by HyperCore spot HYPE via CoreWriter.
///         Buy/sell cover = IOC spot limit orders on asset 11035 (HYPE/USDC pair 1035, testnet).
///         `payoutUsdc` = `spotSend` USDC to the recipient's Core account.
///
/// @dev Encoding verified on-chain (throwaway spike, 2026-07-03):
///      • HYPE Core token 1105, weiDecimals 8  → WAD:   total × 1e10
///      • USDC Core token 0,    weiDecimals 8  → 6dp:   total / 100
///      • spotPx(1035) returns  price × 1e6    → WAD:   raw × 1e12
///      • Order limitPx and sz = human × 1e8   → sz:    WAD / 1e10
///
/// @dev ASYNC GAP: all balance reads reflect **settled Core state** only.
///      CoreWriter is fire-and-forget; fills land ≥1 Core block after the EVM tx.
///      Do NOT assume optimistic accounting on any view after a mutating call.
///
/// @dev pullUsdc — HyperCore has no on-chain ERC20-style transferFrom. Deposits must
///      arrive via an out-of-band Core spot transfer to this contract's Core account.
///      This function reverts with a diagnostic; the book layer (Task 3) owns the UX.
///      CONCERN: callers expecting ERC20-style pull will fail silently if not handled upstream.
contract CoreCoverVault is ICoverVault {
    // ── Constants ─────────────────────────────────────────────────────────────

    /// @dev Spot order asset id = 10000 + HYPE/USDC pair index 1035 (testnet)
    uint32 public constant HYPE_SPOT_ASSET = 11035;
    /// @dev HYPE/USDC pair index for spotPx/spotInfo reads
    uint32 public constant HYPE_SPOT_INDEX = 1035;
    /// @dev HYPE Core token index, weiDecimals 8
    uint64 public constant HYPE_TOKEN = 1105;
    /// @dev USDC Core token index, weiDecimals 8
    uint64 public constant USDC_TOKEN = 0;

    /// @dev szDecimals=2: 0.01 HYPE minimum tradable increment = 1e16 WAD
    uint256 internal constant HYPE_TICK  = 1e16;
    uint256 internal constant WAD        = 1e18;
    /// @dev 50 bps = 0.5% slippage buffer for marketable IOC orders
    uint256 internal constant SLIPPAGE_BPS = 50;

    // ── State ─────────────────────────────────────────────────────────────────

    address public immutable owner;
    address public keeper;
    uint128 public cloidSeq;

    // ── Constructor ───────────────────────────────────────────────────────────

    constructor(address _keeper) {
        owner = msg.sender;
        keeper = _keeper;
    }

    // ── Modifiers ─────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        require(msg.sender == owner, "only owner");
        _;
    }

    /// @dev Either owner or keeper may call cover ops.
    modifier onlyKeeper() {
        require(msg.sender == owner || msg.sender == keeper, "only keeper");
        _;
    }

    // ── Admin ─────────────────────────────────────────────────────────────────

    /// @notice Transfer keeper role (owner only).
    function setKeeper(address _keeper) external onlyOwner {
        keeper = _keeper;
    }

    // ── ICoverVault: view ─────────────────────────────────────────────────────

    /// @inheritdoc ICoverVault
    /// @dev HYPE weiDecimals=8 → WAD: total × 1e10. Async: reflects settled fills only.
    function coverHype() external view returns (uint256) {
        return uint256(PrecompileLib.spotBalance(address(this), HYPE_TOKEN).total) * 1e10;
    }

    /// @inheritdoc ICoverVault
    /// @dev USDC weiDecimals=8 → 6dp: total / 100. Async: reflects settled fills only.
    function poolUsdc() external view returns (uint256) {
        return uint256(PrecompileLib.spotBalance(address(this), USDC_TOKEN).total) / 100;
    }

    /// @inheritdoc ICoverVault
    /// @dev spotPx(1035) returns price×1e6; multiply by 1e12 to get WAD.
    function spotPxUsdc() public view returns (uint256) {
        return uint256(PrecompileLib.spotPx(HYPE_SPOT_INDEX)) * 1e12;
    }

    /// @inheritdoc ICoverVault
    /// @dev coverEquityUsdc = _toUsdc(coverHype × spotPxWad / WAD).
    function coverEquityUsdc() external view returns (uint256) {
        uint256 hype  = uint256(PrecompileLib.spotBalance(address(this), HYPE_TOKEN).total) * 1e10;
        uint256 pxWad = uint256(PrecompileLib.spotPx(HYPE_SPOT_INDEX)) * 1e12;
        return _toUsdc(hype * pxWad / WAD);
    }

    // ── ICoverVault: mutating ─────────────────────────────────────────────────

    /// @inheritdoc ICoverVault
    /// @dev Places a marketable IOC spot buy on HYPE_SPOT_ASSET.
    ///      Estimated cost at current spot is checked against `maxUsdc` before submitting.
    ///      limitPx = rawSpotPx × 100 × (10000 + SLIPPAGE_BPS) / 10000  (*1e8 order scale).
    ///      sz      = hypeWad / 1e10  (WAD → *1e8 order units).
    ///      ASYNC: coverHype() does NOT increase until the fill settles (≥1 Core block).
    function buyCover(uint256 hypeWad, uint256 maxUsdc) external onlyKeeper {
        require(hypeWad > 0, "qty=0");
        uint64 rawPx  = PrecompileLib.spotPx(HYPE_SPOT_INDEX);
        uint256 pxWad = uint256(rawPx) * 1e12;
        // Guard: estimated cost at current price must not exceed caller's cap.
        uint256 estCost = _toUsdc(hypeWad * pxWad / WAD);
        require(estCost <= maxUsdc, "slippage");
        // sz in *1e8 order units; revert if below minimum tradable tick.
        uint64 sz = uint64(hypeWad / 1e10);
        require(sz > 0, "qty: below min tick");
        // limitPx above current ask for marketable IOC fill.
        uint64 limitPx = uint64(uint256(rawPx) * 100 * (10000 + SLIPPAGE_BPS) / 10000);
        CoreWriterLib.placeLimitOrder(
            HYPE_SPOT_ASSET, true, limitPx, sz, false, HLConstants.LIMIT_ORDER_TIF_IOC, ++cloidSeq
        );
    }

    /// @inheritdoc ICoverVault
    /// @dev Floors hypeWad to the nearest HYPE_TICK (0.01 HYPE = 1e16 WAD).
    ///      Sub-tick dust remains in this contract's Core HYPE balance indefinitely.
    ///      Returns ESTIMATED usdcOut at current spot price (actual proceeds are async).
    ///      limitPx below current bid for marketable IOC fill.
    ///      ASYNC: poolUsdc() does NOT increase until the fill settles.
    function sellCover(uint256 hypeWad) external onlyKeeper returns (uint256 usdcOut) {
        // forge-lint: disable-next-line(divide-before-multiply) -- intentional floor-to-tick
        uint256 floored = (hypeWad / HYPE_TICK) * HYPE_TICK;
        require(floored > 0, "qty: below min tick");
        // Sanity check against settled balance (stale by ≤1 Core block, but catches gross errors).
        uint256 hypeWei    = uint256(PrecompileLib.spotBalance(address(this), HYPE_TOKEN).total);
        uint256 currentWad = hypeWei * 1e10;
        require(currentWad >= floored, "cover: insufficient");
        uint64 rawPx = PrecompileLib.spotPx(HYPE_SPOT_INDEX);
        usdcOut      = _toUsdc(floored * (uint256(rawPx) * 1e12) / WAD);
        uint64 sz    = uint64(floored / 1e10);
        // limitPx below current bid for marketable IOC fill.
        uint64 limitPx = uint64(uint256(rawPx) * 100 * (10000 - SLIPPAGE_BPS) / 10000);
        CoreWriterLib.placeLimitOrder(
            HYPE_SPOT_ASSET, false, limitPx, sz, false, HLConstants.LIMIT_ORDER_TIF_IOC, ++cloidSeq
        );
    }

    /// @inheritdoc ICoverVault
    /// @dev Transfers USDC from this contract's Core account to `to` via CoreWriter spotSend.
    ///      amt (6dp) → Core wei: amt × 100.
    ///      Checks settled pool balance before sending (stale by ≤1 Core block).
    function payoutUsdc(address to, uint256 amt) external onlyKeeper {
        require(amt > 0, "amt=0");
        uint256 pool = uint256(PrecompileLib.spotBalance(address(this), USDC_TOKEN).total) / 100;
        require(pool >= amt, "pool: insufficient");
        CoreWriterLib.spotSend(to, USDC_TOKEN, uint64(amt * 100));
    }

    /// @inheritdoc ICoverVault
    /// @dev HyperCore has no on-chain ERC20-style transferFrom equivalent.
    ///      To deposit USDC, send it to this contract's Core account out-of-band
    ///      (i.e., execute a Core spot send from the depositor to address(this)).
    ///      The book layer (Task 3) owns this flow; this function is intentionally unimplemented.
    ///
    /// CONCERN: any caller expecting ERC20-style pull semantics will receive a revert.
    function pullUsdc(address, uint256) external pure {
        revert("CoreCoverVault: deposit via Core account, no on-chain pull");
    }

    // ── Internal ──────────────────────────────────────────────────────────────

    /// @dev WAD → 6dp USDC. Matches CoveredCallMarket._toUsdc exactly.
    function _toUsdc(uint256 wad) internal pure returns (uint256) {
        return wad / 1e12;
    }

    receive() external payable {}
}
