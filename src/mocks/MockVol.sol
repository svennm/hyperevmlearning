// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IVolSource} from "../interfaces/IVolSource.sol";

contract MockVol is IVolSource {
    uint256 private _sigma = 0.8e18;
    bool private _ready = true;

    function setSigma(uint256 s) external {
        _sigma = s;
    }

    function setReady(bool r) external {
        _ready = r;
    }

    function sigma() external view returns (uint256) {
        return _sigma;
    }

    function ready() external view returns (bool) {
        return _ready;
    }

    function updateVol() external {}
}
