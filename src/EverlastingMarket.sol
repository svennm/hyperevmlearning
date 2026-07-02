// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISpotOracle} from "./interfaces/ISpotOracle.sol";

contract EverlastingMarket {
    enum Side { PUT, CALL }

    IERC20 public immutable usdc;
    ISpotOracle public immutable oracle;
    Side public immutable side;
    uint256 public immutable K;          // strike, WAD
    uint256 public immutable W;          // max payout per unit, WAD (PUT: K; CALL: K_hi-K)
    address public immutable lp;         // sole LP (Slice-1/2) = deployer
    address public keeper;
    uint256 public lastIntrinsic;        // intrinsic sampled at the last postMark (WAD)

    uint256 public poolFree;    // USDC available (in-contract)
    uint256 public poolLocked;  // USDC escrowed vs open positions

    uint256 public constant FUNDING_PERIOD = 3600;
    uint256 public constant MAX_MARK_AGE = 7200;
    uint256 public constant MAX_MARK_DEV_BPS = 2000;

    struct Position { uint256 qty; uint256 entryMark; uint256 entryCumFunding; }
    mapping(address => uint256) public traderCollateral;
    mapping(address => Position) public positions;
    uint256 public mark;           // WAD
    uint256 public lastMarkTime;
    uint256 public cumFunding;     // WAD, funding per unit qty

    constructor(IERC20 _usdc, ISpotOracle _oracle, Side _side, uint256 _K, uint256 _W, address _keeper) {
        require(_W > 0, "W=0");
        usdc = _usdc; oracle = _oracle; side = _side; K = _K; W = _W; keeper = _keeper; lp = msg.sender;
    }

    function intrinsicWad() public view returns (uint256) {
        uint256 s = oracle.spotWad();
        if (side == Side.PUT) {
            uint256 v = s >= K ? 0 : K - s;
            return v > W ? W : v;                 // clamp to max payout (no-op when W==K)
        }
        revert("call: todo");                     // CALL branch implemented in Task 2
    }

    function _toUsdc(uint256 wad) internal pure returns (uint256) { return wad / 1e12; }

    function lpDeposit(uint256 amt) external {
        require(msg.sender == lp, "only LP");
        require(usdc.transferFrom(msg.sender, address(this), amt), "transfer");
        poolFree += amt;
    }
    function lpWithdraw(uint256 amt) external {
        require(msg.sender == lp, "only LP");                 // AUDIT F1
        require(amt <= poolFree, "pool: insufficient free");
        poolFree -= amt;
        require(usdc.transfer(msg.sender, amt), "transfer");
    }
    function deposit(uint256 amt) external {
        require(usdc.transferFrom(msg.sender, address(this), amt), "transfer");
        traderCollateral[msg.sender] += amt;
    }
    function withdraw(uint256 amt) external {
        require(positions[msg.sender].qty == 0, "close first");
        require(amt <= traderCollateral[msg.sender], "insufficient");
        traderCollateral[msg.sender] -= amt;
        require(usdc.transfer(msg.sender, amt), "transfer");
    }

    function _escrowUsdc(uint256 qtyWad) internal view returns (uint256) {
        return _toUsdc(qtyWad * W / 1e18);        // was K; now max payout per unit
    }

    function openLong(uint256 qtyWad) external {
        require(mark > 0, "no mark");
        require(block.timestamp <= lastMarkTime + MAX_MARK_AGE, "stale mark"); // AUDIT F5
        require(positions[msg.sender].qty == 0, "one position");
        uint256 im = _escrowUsdc(qtyWad);                 // IM = qty*W
        require(traderCollateral[msg.sender] >= im, "open: IM");
        require(poolFree >= im, "open: pool escrow");
        poolFree -= im; poolLocked += im;
        positions[msg.sender] = Position(qtyWad, mark, cumFunding);
    }

    event MarkPosted(uint256 mark, uint256 cumFunding);

    function postMark(uint256 newMark) external {
        require(msg.sender == keeper, "only keeper");
        uint256 intrinsic = intrinsicWad();
        require(newMark >= intrinsic, "mark<intrinsic");
        require(newMark <= W, "mark>W");                  // was <= K
        if (mark != 0) {
            uint256 age = block.timestamp - lastMarkTime;
            if (age <= MAX_MARK_AGE) {
                uint256 hi = mark + mark * MAX_MARK_DEV_BPS / 10_000;
                uint256 lo = mark - mark * MAX_MARK_DEV_BPS / 10_000;
                require(newMark <= hi && newMark >= lo, "mark deviation");
                uint256 periods = age / FUNDING_PERIOD;
                if (periods > 0) {
                    uint256 f = mark >= lastIntrinsic ? mark - lastIntrinsic : 0; // AUDIT F3
                    cumFunding += f * periods;
                }
            }
            // else: STALE gap -> recoverable re-seed; skip deviation + funding (AUDIT F5)
        }
        mark = newMark;
        lastMarkTime = block.timestamp;
        lastIntrinsic = intrinsic;
        emit MarkPosted(newMark, cumFunding);
    }

    function pendingFunding(address t) public view returns (uint256) {
        Position memory p = positions[t];
        if (p.qty == 0) return 0;
        return p.qty * (cumFunding - p.entryCumFunding) / 1e18; // WAD
    }

    event Closed(address indexed trader, int256 pnlUsdc);

    function settle(address t) external {
        Position memory p = positions[t];
        require(p.qty > 0, "no position");
        uint256 fundingU = _toUsdc(pendingFunding(t));
        require(fundingU > traderCollateral[t], "solvent");
        _closeFor(t);
    }

    function close() external { _closeFor(msg.sender); }

    function _closeFor(address t) internal {
        Position memory p = positions[t];
        require(p.qty > 0, "no position");
        uint256 fundingWad = p.qty * (cumFunding - p.entryCumFunding) / 1e18; // owed to pool
        int256 markPnlWad = int256(p.qty) * (int256(mark) - int256(p.entryMark)) / 1e18;

        uint256 fundingU = _toUsdc(fundingWad);
        int256 markPnlU = markPnlWad >= 0 ? int256(_toUsdc(uint256(markPnlWad)))
                                          : -int256(_toUsdc(uint256(-markPnlWad)));
        int256 netU = markPnlU - int256(fundingU); // trader delta

        // AUDIT F2: release THIS position's escrow FIRST so poolFree >= escrow >= max gain
        // (g <= qty*(mark-entryMark) <= qty*W = escrow), so the payout require can never false-revert.
        uint256 escrow = _escrowUsdc(p.qty);
        poolLocked -= escrow; poolFree += escrow;

        uint256 col = traderCollateral[t];
        if (netU >= 0) {
            uint256 g = uint256(netU);
            require(poolFree >= g, "pool insolvent"); // holds by construction
            poolFree -= g; col += g;
        } else {
            uint256 l = uint256(-netU);
            if (l > col) l = col;                     // auto-settle floor: never below 0
            col -= l; poolFree += l;
        }

        traderCollateral[t] = col;
        delete positions[t];
        emit Closed(t, netU);
    }
}
