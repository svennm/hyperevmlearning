// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISpotOracle} from "./interfaces/ISpotOracle.sol";

/// @title CoveredCallMarket — DEPRECATED (and unsafe: see below)
/// @custom:deprecated Slice-3a covered-call accounting scaffold. SUPERSEDED by src/EverlastingBook.sol.
///   DO NOT DEPLOY. Its "cover" (coverQty/coverEntry) is abstract accounting that is NEVER converted
///   to USDC, so a deep-ITM winner whose gain exceeds poolUsdc CANNOT close (require(poolUsdc>=g))
///   until the LP manually tops up — it is NOT cash-covered. EverlastingBook's real sellCover→USDC
///   vault (I3) is the fix. Retained for slice-3a test history ONLY.
contract CoveredCallMarket {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    ISpotOracle public immutable oracle;
    uint256 public immutable K;   // strike, WAD
    address public immutable lp;  // set to msg.sender in constructor

    address public keeper;
    uint256 public poolUsdc;      // USDC in contract (6dp)
    uint256 public coverQty;      // abstract cover qty, WAD
    uint256 public coverEntry;    // avg entry price of cover, WAD
    uint256 public netWritten;    // total qty open call positions, WAD
    uint256 public mark;          // WAD
    uint256 public lastMarkTime;
    uint256 public cumFunding;    // WAD funding per unit qty
    uint256 public lastIntrinsic; // WAD sampled at last postMark

    uint256 public constant FUNDING_PERIOD  = 3600;   // seconds (1 hour)
    uint256 public constant MAX_MARK_AGE    = 7200;   // seconds (2 hours)
    uint256 public constant MAX_MARK_DEV_BPS = 2000;  // 20% max deviation per update

    struct Position { uint256 qty; uint256 entryMark; uint256 entryCumFunding; }
    mapping(address => uint256) public traderCollateral;
    mapping(address => Position) public positions;

    event MarkPosted(uint256 mark, uint256 cumFunding);
    event Closed(address indexed trader, int256 net);

    constructor(IERC20 _usdc, ISpotOracle _oracle, uint256 _K, address _keeper) {
        require(_K > 0, "K=0");
        usdc = _usdc;
        oracle = _oracle;
        K = _K;
        keeper = _keeper;
        lp = msg.sender;
    }

    function intrinsicWad() public view returns (uint256) {
        uint256 s = oracle.spotWad();
        return s > K ? s - K : 0;
    }

    function _toUsdc(uint256 wad) internal pure returns (uint256) {
        return wad / 1e12;
    }

    function lpDeposit(uint256 amt) external {
        require(msg.sender == lp, "only LP");
        usdc.safeTransferFrom(msg.sender, address(this), amt);
        poolUsdc += amt;
    }

    function lpWithdraw(uint256 amt) external {
        require(msg.sender == lp, "only LP");
        require(amt <= poolUsdc, "pool: insufficient");
        poolUsdc -= amt;
        usdc.safeTransfer(msg.sender, amt);
    }

    function deposit(uint256 amt) external {
        usdc.safeTransferFrom(msg.sender, address(this), amt);
        traderCollateral[msg.sender] += amt;
    }

    function withdraw(uint256 amt) external {
        require(positions[msg.sender].qty == 0, "close first");
        require(amt <= traderCollateral[msg.sender], "insufficient");
        traderCollateral[msg.sender] -= amt;
        usdc.safeTransfer(msg.sender, amt);
    }

    function increaseCover(uint256 qtyWad) external {
        require(qtyWad > 0, "qty=0");
        require(msg.sender == lp || msg.sender == keeper, "only lp/keeper");
        uint256 s = oracle.spotWad();
        if (coverQty == 0) {
            coverEntry = s;
        } else {
            coverEntry = (coverQty * coverEntry + qtyWad * s) / (coverQty + qtyWad);
        }
        coverQty += qtyWad;
    }

    function coverEquityUsdc() public view returns (uint256) {
        uint256 s = oracle.spotWad();
        return _toUsdc(coverQty * s / 1e18);
    }

    function _coverCovers(uint256 addQty) internal view returns (bool) {
        return coverQty >= netWritten + addQty;
    }

    function openLong(uint256 qtyWad) external {
        require(qtyWad > 0, "qty=0");
        require(mark > 0, "no mark");
        require(block.timestamp <= lastMarkTime + MAX_MARK_AGE, "stale mark");
        require(positions[msg.sender].qty == 0, "one position");
        require(traderCollateral[msg.sender] >= _toUsdc(qtyWad * mark / 1e18), "IM");
        require(_coverCovers(qtyWad), "cover");
        netWritten += qtyWad;
        positions[msg.sender] = Position(qtyWad, mark, cumFunding);
    }

    function pendingFunding(address t) public view returns (uint256) {
        Position memory p = positions[t];
        if (p.qty == 0) return 0;
        return p.qty * (cumFunding - p.entryCumFunding) / 1e18;
    }

    // Trader's net loss in USDC (0 if net gain) — mirrors _closeFor's loss branch exactly:
    // netLoss = markLoss + funding − markGain. This is the pool's claim on the trader; when it
    // exceeds collateral the position is insolvent and the auto-settle floor forces the pool to
    // absorb the shortfall. Since IM here is premium-only (qty·mark, not qty·W), markLoss alone
    // can consume collateral — a funding-only predicate would miss that and lock out the keeper.
    function netLossUsdc(address t) public view returns (uint256) {
        Position memory p = positions[t];
        if (p.qty == 0) return 0;
        uint256 fundingU = _toUsdc(p.qty * (cumFunding - p.entryCumFunding) / 1e18);
        uint256 markGainU;
        uint256 markLossU;
        if (mark >= p.entryMark) {
            markGainU = _toUsdc(p.qty * (mark - p.entryMark) / 1e18);
        } else {
            markLossU = _toUsdc(p.qty * (p.entryMark - mark) / 1e18);
        }
        uint256 debit = markLossU + fundingU;
        return debit > markGainU ? debit - markGainU : 0;
    }

    function postMark(uint256 newMark) external {
        require(msg.sender == keeper, "only keeper");
        uint256 intrinsic = intrinsicWad();
        require(newMark >= intrinsic, "mark<intrinsic");

        bool isFresh = (mark != 0) && (block.timestamp <= lastMarkTime + MAX_MARK_AGE);

        if (isFresh) {
            uint256 hi = mark + mark * MAX_MARK_DEV_BPS / 10_000;
            uint256 lo = mark - mark * MAX_MARK_DEV_BPS / 10_000;
            require(newMark <= hi && newMark >= lo, "mark deviation");

            uint256 age = block.timestamp - lastMarkTime;
            uint256 periods = age / FUNDING_PERIOD;
            if (periods > 0) {
                uint256 f = mark >= lastIntrinsic ? mark - lastIntrinsic : 0;
                cumFunding += f * periods;
            }
        }

        mark = newMark;
        lastMarkTime = block.timestamp;
        lastIntrinsic = intrinsic;
        emit MarkPosted(newMark, cumFunding);
    }

    // ── Task 4: close / cash-settle / reduceCover ────────────────────────────

    function _closeFor(address t) internal {
        Position memory p = positions[t];
        require(p.qty > 0, "no position");

        uint256 fundingWad = p.qty * (cumFunding - p.entryCumFunding) / 1e18;
        uint256 fundingU   = _toUsdc(fundingWad);

        // Mark PnL split into gain / loss to avoid int256 intermediate arithmetic
        // (keeps all arithmetic in uint256, only casts at emit boundary)
        uint256 markGainU;
        uint256 markLossU;
        if (mark >= p.entryMark) {
            markGainU = _toUsdc(p.qty * (mark - p.entryMark) / 1e18);
        } else {
            markLossU = _toUsdc(p.qty * (p.entryMark - mark) / 1e18);
        }

        // netU = markGain − markLoss − funding (trader perspective, USDC)
        if (markGainU >= markLossU + fundingU) {
            uint256 g = markGainU - markLossU - fundingU;
            require(poolUsdc >= g, "pool");
            poolUsdc -= g;
            traderCollateral[t] += g;
            netWritten -= p.qty;
            delete positions[t];
            // forge-lint: disable-next-line(unsafe-typecast)
            emit Closed(t, int256(g));
        } else {
            uint256 l = markLossU + fundingU - markGainU;
            if (l > traderCollateral[t]) l = traderCollateral[t]; // auto-settle floor
            traderCollateral[t] -= l;
            poolUsdc += l;
            netWritten -= p.qty;
            delete positions[t];
            // forge-lint: disable-next-line(unsafe-typecast)
            emit Closed(t, -int256(l));
        }
    }

    function close() external {
        _closeFor(msg.sender);
    }

    function settle(address t) external {
        require(positions[t].qty > 0, "no position");
        require(netLossUsdc(t) > traderCollateral[t], "solvent");
        _closeFor(t);
    }

    function reduceCover(uint256 qtyWad) external {
        require(msg.sender == lp || msg.sender == keeper, "only lp/keeper");
        require(qtyWad > 0, "qty=0");
        require(coverQty - qtyWad >= netWritten, "cover<net");
        coverQty -= qtyWad;
    }
}
