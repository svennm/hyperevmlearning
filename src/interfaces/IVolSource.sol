// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

interface IVolSource {
    function sigma() external view returns (uint256);
    function ready() external view returns (bool);
    function updateVol() external;
}
