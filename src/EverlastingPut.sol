// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISpotOracle} from "./interfaces/ISpotOracle.sol";

contract EverlastingPut {
    IERC20 public immutable usdc;
    ISpotOracle public immutable oracle;
    uint256 public immutable K;          // strike, WAD
    address public immutable lp;         // sole LP (Slice-1) = deployer
    address public keeper;
    uint256 public lastIntrinsic;        // intrinsic sampled at the last postMark (WAD)

    uint256 public poolFree;    // USDC available
    uint256 public poolLocked;  // USDC escrowed vs open positions

    uint256 public constant FUNDING_PERIOD = 3600;
    uint256 public constant MAX_MARK_AGE = 7200;
    uint256 public constant MAX_MARK_DEV_BPS = 2000;

    struct Position { uint256 qty; uint256 entryMark; uint256 entryCumFunding; }
    mapping(address => uint256) public traderCollateral;
    mapping(address => Position) public positions;
    uint256 public mark;           // WAD
    uint256 public lastMarkTime;
    uint256 public cumFunding;     // WAD, funding per unit qty (Task 7 advances it)

    constructor(IERC20 _usdc, ISpotOracle _oracle, uint256 _K, address _keeper) {
        usdc = _usdc; oracle = _oracle; K = _K; keeper = _keeper; lp = msg.sender;
    }

    function intrinsicWad() public view returns (uint256) {
        uint256 s = oracle.spotWad();
        return s >= K ? 0 : K - s;
    }

    function _toUsdc(uint256 wad) internal pure returns (uint256) { return wad / 1e12; }

    function lpDeposit(uint256 amt) external {
        require(msg.sender == lp, "only LP");
        require(usdc.transferFrom(msg.sender, address(this), amt), "transfer");
        poolFree += amt;
    }

    function lpWithdraw(uint256 amt) external {
        require(msg.sender == lp, "only LP");                 // AUDIT F1: gate pool withdrawals
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
        return _toUsdc(qtyWad * K / 1e18);
    }

    function openLong(uint256 qtyWad) external {
        require(mark > 0, "no mark");
        require(block.timestamp <= lastMarkTime + MAX_MARK_AGE, "stale mark"); // AUDIT F5: pause opens when stale
        require(positions[msg.sender].qty == 0, "one position"); // Slice-1: no add/scale
        uint256 im = _escrowUsdc(qtyWad);                 // IM = qty*K
        require(traderCollateral[msg.sender] >= im, "open: IM");
        require(poolFree >= im, "open: pool escrow");
        poolFree -= im; poolLocked += im;
        positions[msg.sender] = Position(qtyWad, mark, cumFunding);
    }

    event MarkPosted(uint256 mark, uint256 cumFunding);

    function postMark(uint256 newMark) external {
        require(msg.sender == keeper, "only keeper");
        uint256 intrinsic = intrinsicWad();
        require(newMark >= intrinsic, "mark<intrinsic");   // always-on bounds
        require(newMark <= K, "mark>K");
        if (mark != 0) {
            uint256 age = block.timestamp - lastMarkTime;
            if (age <= MAX_MARK_AGE) {
                // FRESH: enforce deviation + accrue funding for elapsed periods.
                uint256 hi = mark + mark * MAX_MARK_DEV_BPS / 10_000;
                uint256 lo = mark - mark * MAX_MARK_DEV_BPS / 10_000;
                require(newMark <= hi && newMark >= lo, "mark deviation");
                uint256 periods = age / FUNDING_PERIOD;
                if (periods > 0) {
                    // AUDIT F3: contemporaneous start-of-period pair (mark & lastIntrinsic both from prior post)
                    uint256 f = mark >= lastIntrinsic ? mark - lastIntrinsic : 0; // time value per unit
                    cumFunding += f * periods;
                }
            }
            // else: STALE gap (> MAX_MARK_AGE) -> recoverable re-seed; skip deviation + funding (AUDIT F5)
        }
        mark = newMark;
        lastMarkTime = block.timestamp;
        lastIntrinsic = intrinsic;                          // sample intrinsic with the mark
        emit MarkPosted(newMark, cumFunding);
    }

    function pendingFunding(address t) public view returns (uint256) {
        Position memory p = positions[t];
        if (p.qty == 0) return 0;
        return p.qty * (cumFunding - p.entryCumFunding) / 1e18; // WAD
    }
}
