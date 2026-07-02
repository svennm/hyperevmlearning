// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {ISpotOracle} from "./interfaces/ISpotOracle.sol";
contract MockOracle is ISpotOracle {
    uint256 private _px;
    function set(uint256 pxWad) external { _px = pxWad; }
    function spotWad() external view returns (uint256) { return _px; }
}
