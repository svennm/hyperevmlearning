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

    uint256 public constant FUNDING_PERIOD = 3600;
    uint256 public constant MAX_MARK_AGE = 7200;
    uint256 public constant MAX_MARK_DEV_BPS = 2000;

    constructor(IERC20 _usdc, ISpotOracle _oracle, uint256 _K, address _keeper) {
        usdc = _usdc; oracle = _oracle; K = _K; keeper = _keeper; lp = msg.sender;
    }

    function intrinsicWad() public view returns (uint256) {
        uint256 s = oracle.spotWad();
        return s >= K ? 0 : K - s;
    }

    function _toUsdc(uint256 wad) internal pure returns (uint256) { return wad / 1e12; }
}
