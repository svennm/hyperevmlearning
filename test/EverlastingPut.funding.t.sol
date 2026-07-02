// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {Test} from "forge-std/Test.sol";
import {EverlastingMarket} from "../src/EverlastingMarket.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockOracle} from "../src/MockOracle.sol";

contract PutFundingTest is Test {
    EverlastingMarket put; MockUSDC usdc; MockOracle oracle;
    function setUp() public {
        usdc = new MockUSDC(); oracle = new MockOracle();
        put = new EverlastingMarket(usdc, oracle, EverlastingMarket.Side.PUT, 48e18, 48e18, address(this));
        oracle.set(48e18);
    }
    function test_guard_markBelowIntrinsicReverts() public {
        oracle.set(40e18); // intrinsic = 8
        vm.expectRevert(bytes("mark<intrinsic"));
        put.postMark(5e18);
    }
    function test_guard_markAboveKReverts() public {
        vm.expectRevert(bytes("mark>W"));
        put.postMark(49e18);
    }
    function test_guard_deviationReverts() public {
        put.postMark(6e18);
        vm.warp(block.timestamp + 3600);
        vm.expectRevert(bytes("mark deviation"));
        put.postMark(9e18); // +50% > 20%
    }
    function test_guard_onlyKeeper() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(bytes("only keeper"));
        put.postMark(6e18);
    }
    function test_cumFundingAdvances() public {
        put.postMark(6e18);                 // establishes mark, no elapsed period yet
        uint256 c0 = put.cumFunding();
        vm.warp(block.timestamp + 3600);
        put.postMark(6e18);                 // one period: funding += (6 - 0) = 6e18
        assertEq(put.cumFunding(), c0 + 6e18);
    }

    // AUDIT F5: a >MAX_MARK_AGE keeper gap must be recoverable and must NOT back-charge funding
    function test_stale_recoversWithoutFunding() public {
        put.postMark(6e18);
        vm.warp(block.timestamp + put.MAX_MARK_AGE() + 1);
        uint256 c = put.cumFunding();
        put.postMark(6e18);                 // re-seeds; no funding accrued over the un-observed gap
        assertEq(put.cumFunding(), c);
        assertEq(put.mark(), 6e18);
    }
}
