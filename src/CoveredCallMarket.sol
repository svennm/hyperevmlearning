// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISpotOracle} from "./interfaces/ISpotOracle.sol";

contract CoveredCallMarket {
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

    struct Position { uint256 qty; uint256 entryMark; uint256 entryCumFunding; }
    mapping(address => uint256) public traderCollateral;
    mapping(address => Position) public positions;

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
        require(usdc.transferFrom(msg.sender, address(this), amt), "transfer");
        poolUsdc += amt;
    }

    function lpWithdraw(uint256 amt) external {
        require(msg.sender == lp, "only LP");
        require(amt <= poolUsdc, "pool: insufficient");
        poolUsdc -= amt;
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
}
