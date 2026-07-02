// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IYieldAdapter} from "./interfaces/IYieldAdapter.sol";
contract NullYieldAdapter is IYieldAdapter {
    IERC20 public immutable usdc; address public immutable market;
    constructor(IERC20 _usdc, address _market){ usdc=_usdc; market=_market; }
    function deposit(uint256 amt) external { require(msg.sender==market,"only market"); require(usdc.transferFrom(msg.sender,address(this),amt),"transfer"); }
    function withdraw(uint256 amt) external { require(msg.sender==market,"only market"); require(usdc.transfer(market,amt),"transfer"); }
    function balance() external view returns (uint256){ return usdc.balanceOf(address(this)); }
}
