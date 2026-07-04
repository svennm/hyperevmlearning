// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import "forge-std/Test.sol";
import "../src/CoveredCallMarket.sol";
import "../src/MockUSDC.sol";
import "../src/MockOracle.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISpotOracle} from "../src/interfaces/ISpotOracle.sol";

contract CoveredCallCoverHarness is CoveredCallMarket {
    constructor(IERC20 _usdc, ISpotOracle _oracle, uint256 _K, address _keeper)
        CoveredCallMarket(_usdc, _oracle, _K, _keeper) {}

    function coverCoversPublic(uint256 addQty) public view returns (bool) {
        return _coverCovers(addQty);
    }
}

contract CoveredCallCoverTest is Test {
    MockUSDC usdc;
    MockOracle oracle;
    CoveredCallMarket market;
    CoveredCallCoverHarness harness;

    function setUp() public {
        usdc = new MockUSDC();
        oracle = new MockOracle();
        oracle.set(50e18);
        market = new CoveredCallMarket(IERC20(address(usdc)), oracle, 40e18, address(0xBEEF));
        harness = new CoveredCallCoverHarness(IERC20(address(usdc)), oracle, 40e18, address(0xBEEF));
    }

    function test_increaseCover_first() public {
        oracle.set(50e18);
        market.increaseCover(1e18);
        assertEq(market.coverQty(), 1e18);
        assertEq(market.coverEntry(), 50e18);
    }

    function test_increaseCover_weightedAvg() public {
        oracle.set(50e18);
        market.increaseCover(1e18);
        oracle.set(100e18);
        market.increaseCover(1e18);
        assertEq(market.coverQty(), 2e18);
        assertEq(market.coverEntry(), 75e18);
    }

    function test_increaseCover_weightedAvg_unequalQty() public {
        oracle.set(50e18);
        market.increaseCover(3e18);
        oracle.set(100e18);
        market.increaseCover(1e18);
        assertEq(market.coverQty(), 4e18);
        assertEq(market.coverEntry(), 62_500000000000000000);
    }

    function test_coverEquityUsdc() public {
        oracle.set(50e18);
        market.increaseCover(2e18);
        // coverEquity = _toUsdc(2e18 * 50e18 / 1e18) = _toUsdc(100e18) = 100e18/1e12 = 100e6
        assertEq(market.coverEquityUsdc(), 100e6);
    }

    function test_coverCovers_boundary() public {
        oracle.set(50e18);
        harness.increaseCover(2e18);
        // netWritten is 0, coverQty is 2e18
        assertTrue(harness.coverCoversPublic(0));       // 2>=0+0 true
        assertTrue(harness.coverCoversPublic(2e18));    // 2>=0+2 true (boundary)
        assertFalse(harness.coverCoversPublic(3e18));   // 2>=0+3 false
    }

    function test_increaseCover_onlyLpOrKeeper() public {
        oracle.set(50e18);
        // unauthorized reverts
        vm.prank(address(0xDEAD));
        vm.expectRevert(bytes("only lp/keeper"));
        market.increaseCover(1e18);
        // keeper can call (keeper = address(0xBEEF))
        vm.prank(address(0xBEEF));
        market.increaseCover(1e18);
        assertEq(market.coverQty(), 1e18);
    }
}
