// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
interface IYieldAdapter {
    function deposit(uint256 amt) external;               // pulls USDC from caller
    function withdraw(uint256 amt) external;              // returns USDC to caller
    function balance() external view returns (uint256);   // principal + accrued, for the caller
}
