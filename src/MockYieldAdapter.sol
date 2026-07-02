// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IYieldAdapter} from "./interfaces/IYieldAdapter.sol";

// Testnet-only: simulates yield by letting anyone `accrue()` extra MockUSDC that was pre-funded.
contract MockYieldAdapter is IYieldAdapter {
    IERC20 public immutable usdc; address public immutable market;
    uint256 public principal;    // owed back to `market`
    constructor(IERC20 _usdc, address _market){ usdc=_usdc; market=_market; }
    function deposit(uint256 amt) external {
        require(msg.sender == market, "only market");
        require(usdc.transferFrom(msg.sender, address(this), amt), "transfer");
        principal += amt;
    }
    function withdraw(uint256 amt) external {
        require(msg.sender == market, "only market");
        require(amt <= usdc.balanceOf(address(this)), "insufficient");
        if (amt > principal) principal = 0; else principal -= amt;   // withdrawing yield first is fine
        require(usdc.transfer(market, amt), "transfer");
    }
    function balance() external view returns (uint256){ return usdc.balanceOf(address(this)); }
    // test helper: simulate interest, funded by whoever calls (mint + transfer in the test)
    function accrue(uint256 amt) external { require(usdc.transferFrom(msg.sender, address(this), amt), "transfer"); }
}
