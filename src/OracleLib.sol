// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {ISpotOracle} from "./interfaces/ISpotOracle.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";

/// Reads the HYPE perp oracle (index 135, szDecimals 2) and returns WAD USD.
contract OracleLib is ISpotOracle {
    uint32 public constant HYPE_INDEX = 135;
    uint256 public constant SCALE = 1e14; // 10^(12 + szDecimals=2)

    function spotWad() external view returns (uint256) {
        uint256 raw = uint256(PrecompileLib.oraclePx(HYPE_INDEX));
        require(raw > 0, "oracle zero");
        return raw * SCALE;
    }
}
