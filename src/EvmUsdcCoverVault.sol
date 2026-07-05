// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ICoverVault} from "./interfaces/ICoverVault.sol";
import {CoreWriterLib} from "@hyper-evm-lib/src/CoreWriterLib.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";
import {HLConstants} from "@hyper-evm-lib/src/common/HLConstants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title EvmUsdcCoverVault
/// @notice `ICoverVault` implementation whose USDC collateral lives as a standard EVM ERC20
///         (so trader deposits work via `transferFrom`), while the HYPE cover stays Core-native
///         (CoreWriter spot HYPE, identical to CoreCoverVault).
///
/// @dev THE FIX vs CoreCoverVault:
///      CoreCoverVault holds USDC on HyperCore spot; its `pullUsdc` reverts because HyperCore has
///      no on-chain ERC20 `transferFrom`, so `book.deposit` cannot take trader collateral live.
///      Here USDC is a normal EVM ERC20 held by this contract, so `pullUsdc` is a real
///      `transferFrom` and deposits work end-to-end. The HYPE cover side is byte-for-byte the
///      CoreCoverVault CoreWriter logic (asset 11035, szDecimals=2 floor, IOC encoding).
///
/// @dev TWO-LAYER USDC — the pool's USDC lives across two layers:
///      • EVM ERC20 balance of this contract (6dp)         — deposits/withdrawals custody here
///      • Core-USDC spot float on HyperCore (8dp→6dp)      — cover buys consume it; sale proceeds land here
///      `poolUsdc()` sums BOTH. Cover buys spend the Core float; cover sales credit the Core float;
///      the keeper `bridge`s USDC between the two layers to (a) pre-fund a Core float before buying
///      cover and (b) return sale proceeds to EVM for trader withdrawals.
///
/// @dev ASYNC / OPERATIONAL BOUNDARY (honest note, not a test bug):
///      HyperCore reads reflect **settled Core state** only, and EVM↔Core bridges are async
///      (they land ≥1 Core block later, via the CoreDepositWallet / system-address path). A bridge
///      is near-atomic per-account, but the two-layer `poolUsdc()` can transiently MISCOUNT while a
///      bridge is in flight (USDC has left one layer but not yet arrived on the other). This mirrors
///      CoreCoverVault's existing async gap: do NOT assume optimistic accounting on any view after a
///      mutating cover/bridge call — settle the Core block first (keeper waits) before relying on it.
///
/// @dev USDC ADDRESS: bridging USDC via CoreWriterLib always moves the canonical `HLConstants.usdc()`
///      token (it only uses the passed address to resolve the Core token index). Production MUST pass
///      `HLConstants.usdc()` as `_usdc` for the bridge path to function; tests pass a MockUSDC (6dp)
///      to exercise the ERC20 custody / deposit-fix path.
contract EvmUsdcCoverVault is ICoverVault {
    using SafeERC20 for IERC20;

    // ── Constants (HYPE cover — identical to CoreCoverVault) ──────────────────

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

    /// @notice USDC held as an EVM ERC20 by this contract (the FIX vs CoreCoverVault).
    IERC20 public immutable usdc;

    address public immutable owner;
    address public keeper;
    uint128 public cloidSeq;

    // ── Constructor ───────────────────────────────────────────────────────────

    /// @param _usdc   USDC ERC20 (tests: MockUSDC 6dp; prod: HLConstants.usdc())
    /// @param _keeper Cover/bridge/payout operator (the EverlastingBook is wired as keeper so its
    ///                sellCover/payoutUsdc calls are authorized; the human operator is `owner`).
    constructor(IERC20 _usdc, address _keeper) {
        usdc   = _usdc;
        owner  = msg.sender;
        keeper = _keeper;
    }

    // ── Modifiers ─────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        require(msg.sender == owner, "only owner");
        _;
    }

    /// @dev Either owner or keeper may call cover/bridge/payout ops.
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
    ///      Identical to CoreCoverVault (HYPE cover stays Core-native).
    function coverHype() external view returns (uint256) {
        return uint256(PrecompileLib.spotBalance(address(this), HYPE_TOKEN).total) * 1e10;
    }

    /// @inheritdoc ICoverVault
    /// @dev TWO-LAYER pool USDC:
    ///        EVM ERC20 balance (already 6dp)  +  Core-USDC float (weiDecimals=8 → 6dp: /100).
    ///      Deposits add EVM USDC; cover buys consume the Core float; cover-sale proceeds land on
    ///      the Core float. Both layers are the ONE pool the book accounts against.
    ///      ASYNC: the Core-float term reflects settled fills/bridges only.
    function poolUsdc() external view returns (uint256) {
        return usdc.balanceOf(address(this))
            + uint256(PrecompileLib.spotBalance(address(this), USDC_TOKEN).total) / 100;
    }

    /// @inheritdoc ICoverVault
    /// @dev spotPx(1035) returns price×1e6; multiply by 1e12 to get WAD. Identical to CoreCoverVault.
    function spotPxUsdc() public view returns (uint256) {
        return uint256(PrecompileLib.spotPx(HYPE_SPOT_INDEX)) * 1e12;
    }

    /// @inheritdoc ICoverVault
    /// @dev coverEquityUsdc = _toUsdc(coverHype × spotPxWad / WAD). Identical to CoreCoverVault.
    function coverEquityUsdc() external view returns (uint256) {
        uint256 hype  = uint256(PrecompileLib.spotBalance(address(this), HYPE_TOKEN).total) * 1e10;
        uint256 pxWad = uint256(PrecompileLib.spotPx(HYPE_SPOT_INDEX)) * 1e12;
        return _toUsdc(hype * pxWad / WAD);
    }

    // ── ICoverVault: cover (byte-for-byte from CoreCoverVault) ────────────────

    /// @inheritdoc ICoverVault
    /// @dev Places a marketable IOC spot buy on HYPE_SPOT_ASSET, funded from the EXISTING Core-USDC
    ///      float. If the float is short, the IOC simply won't fill — the keeper must
    ///      `bridgeUsdcToCore` first (bridge is async; do NOT try to bridge-and-buy atomically).
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
    /// @dev Floors hypeWad to the nearest HYPE_TICK (0.01 HYPE = 1e16 WAD). Sub-tick dust remains in
    ///      this contract's Core HYPE balance indefinitely. Returns ESTIMATED usdcOut at current spot
    ///      (actual proceeds are async and accrue to the Core-USDC float). Identical to CoreCoverVault.
    ///      ASYNC: poolUsdc()'s Core-float term does NOT increase until the fill settles.
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

    // ── ICoverVault: USDC custody = EVM ERC20 (THE FIX) ───────────────────────

    /// @inheritdoc ICoverVault
    /// @dev THE FIX: standard ERC20 `transferFrom(from → this)`. This is what CoreCoverVault could
    ///      not do (HyperCore has no on-chain transferFrom), so `book.deposit` now takes trader
    ///      collateral live. `from` must have approved this vault for `amt`.
    /// @dev Keeper-gated (the book is wired as keeper). WITHOUT this gate, anyone could call
    ///      `pullUsdc(victim, amt)` and drain a trader's approved USDC into the pool UNCREDITED
    ///      (the book credits collateral only when IT calls pullUsdc). Gating to the book closes
    ///      that griefing/fund-loss vector; the book pulls on the trader's behalf atomically with
    ///      crediting `traderCollateral`.
    function pullUsdc(address from, uint256 amt) external onlyKeeper {
        usdc.safeTransferFrom(from, address(this), amt);
    }

    /// @inheritdoc ICoverVault
    /// @dev Standard ERC20 `transfer(this → to)` from the EVM USDC balance. Keeper-gated (the book is
    ///      wired as keeper, so book.withdraw/lpWithdraw are authorized). NOTE: pays from the EVM
    ///      layer only — the keeper must `bridgeUsdcToEvm` any Core-float proceeds first if the EVM
    ///      balance is short (the honest two-layer boundary).
    function payoutUsdc(address to, uint256 amt) external onlyKeeper {
        usdc.safeTransfer(to, amt);
    }

    // ── Keeper float management: EVM ↔ Core USDC bridges ──────────────────────

    /// @notice Bridge EVM USDC → Core spot USDC float (pre-fund cover buys). Owner/keeper-gated, async.
    /// @dev Moves the canonical HLConstants.usdc() token; the passed `usdc` address only resolves the
    ///      Core token index. The float lands on the Core spot dex ≥1 block later.
    function bridgeUsdcToCore(uint256 amt) external onlyKeeper {
        CoreWriterLib.bridgeToCore(address(usdc), amt);
    }

    /// @notice Bridge Core spot USDC float → EVM USDC (return cover-sale proceeds for withdrawals).
    ///         Owner/keeper-gated, async.
    function bridgeUsdcToEvm(uint256 amt) external onlyKeeper {
        CoreWriterLib.bridgeToEvm(address(usdc), amt);
    }

    // ── Internal ──────────────────────────────────────────────────────────────

    /// @dev WAD → 6dp USDC. Matches CoreCoverVault / CoveredCallMarket._toUsdc exactly.
    function _toUsdc(uint256 wad) internal pure returns (uint256) {
        return wad / 1e12;
    }

    receive() external payable {}
}
