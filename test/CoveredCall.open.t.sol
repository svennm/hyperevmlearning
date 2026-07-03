// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import "forge-std/Test.sol";
import "../src/CoveredCallMarket.sol";
import "../src/MockUSDC.sol";
import "../src/MockOracle.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISpotOracle} from "../src/interfaces/ISpotOracle.sol";

contract CoveredCallOpenHarness is CoveredCallMarket {
    constructor(IERC20 _usdc, ISpotOracle _oracle, uint256 _K, address _keeper)
        CoveredCallMarket(_usdc, _oracle, _K, _keeper) {}

    function coverCoversPublic(uint256 addQty) public view returns (bool) {
        return _coverCovers(addQty);
    }
}

contract CoveredCallOpenTest is Test {
    MockUSDC usdc;
    MockOracle oracle;
    CoveredCallMarket market;
    address alice = address(0xA11CE);
    address keeper = address(0xBEEF);
    uint256 constant K = 48e18;

    function setUp() public {
        usdc = new MockUSDC();
        oracle = new MockOracle();
        market = new CoveredCallMarket(IERC20(address(usdc)), ISpotOracle(address(oracle)), K, keeper);

        // Set spot to 50e18 => intrinsic = 2e18
        oracle.set(50e18);

        // Mint and approve USDC for alice and this (LP)
        usdc.mint(alice, 10000e6);
        usdc.mint(address(this), 10000e6);

        vm.prank(alice);
        usdc.approve(address(market), type(uint256).max);

        usdc.approve(address(market), type(uint256).max);
    }

    function test_openLong_bumpsNetWrittenAndRecordsPosition() public {
        market.increaseCover(2e18);

        vm.warp(1);
        vm.prank(keeper);
        market.postMark(5e18);

        vm.prank(alice);
        market.deposit(5e6);

        vm.prank(alice);
        market.openLong(1e18);

        assertEq(market.netWritten(), 1e18);

        (uint256 qty, uint256 entryMark, uint256 entryCumFunding) = market.positions(alice);
        assertEq(qty, 1e18);
        assertEq(entryMark, 5e18);
        assertEq(entryCumFunding, 0);
    }

    function test_openLong_revertsNoCover() public {
        vm.warp(1);
        vm.prank(keeper);
        market.postMark(5e18);

        vm.prank(alice);
        market.deposit(5e6);

        vm.prank(alice);
        vm.expectRevert("cover");
        market.openLong(1e18);
    }

    function test_openLong_succeedsAfterIncreaseCover() public {
        market.increaseCover(1e18);

        vm.warp(1);
        vm.prank(keeper);
        market.postMark(5e18);

        vm.prank(alice);
        market.deposit(5e6);

        vm.prank(alice);
        market.openLong(1e18);

        assertEq(market.netWritten(), 1e18);
    }

    function test_openLong_revertsIM() public {
        market.increaseCover(2e18);

        vm.warp(1);
        vm.prank(keeper);
        market.postMark(5e18);

        vm.prank(alice);
        market.deposit(1e6); // Not enough: IM = 5e6

        vm.prank(alice);
        vm.expectRevert(bytes("IM"));
        market.openLong(1e18);
    }

    function test_openLong_revertsStaleMark() public {
        market.increaseCover(2e18);

        vm.warp(1);
        vm.prank(keeper);
        market.postMark(5e18);

        vm.warp(7202); // > MAX_MARK_AGE (7200)

        vm.prank(alice);
        market.deposit(5e6);

        vm.prank(alice);
        vm.expectRevert("stale mark");
        market.openLong(1e18);
    }

    function test_fundingAccrues_markMinusIntrinsicOverOnePeriod() public {
        market.increaseCover(2e18);

        vm.warp(1);
        oracle.set(50e18); // intrinsic = 2e18
        vm.prank(keeper);
        market.postMark(5e18); // mark = 5e18, lastIntrinsic = 2e18

        vm.prank(alice);
        market.deposit(5e6);
        vm.prank(alice);
        market.openLong(1e18);

        vm.warp(1 + 3600); // FUNDING_PERIOD = 3600; age = 3600, periods = 1

        vm.prank(keeper);
        market.postMark(5e18); // same mark, within deviation; f = 5e18 - 2e18 = 3e18; cumFunding += 3e18

        // pendingFunding = qty * (cumFunding - entryCumFunding) / 1e18
        //                = 1e18 * (3e18 - 0) / 1e18 = 3e18
        assertEq(market.pendingFunding(alice), 3e18);
    }

    function test_postMark_acceptsMarkAboveK() public {
        // UNCAPPED: marks > K must be accepted
        oracle.set(100e18); // intrinsic = 52e18

        vm.warp(1);
        vm.prank(keeper);
        market.postMark(52e18); // first postMark (mark=0 -> no deviation check), sets mark=52e18

        // Second postMark: 62e18 is within 20% of 52e18 (hi = 62.4e18 >= 62e18)
        // And 62e18 > K = 48e18 — proves no upper bound cap
        vm.prank(keeper);
        market.postMark(62e18);

        assertEq(market.mark(), 62e18);
    }

    // CARRY-IN: test _coverCovers with netWritten > 0 boundary
    function test_coverCovers_netWrittenBoundary() public {
        CoveredCallOpenHarness harness = new CoveredCallOpenHarness(
            IERC20(address(usdc)),
            ISpotOracle(address(oracle)),
            K,
            keeper
        );

        // LP is address(this) (deployer of harness)
        usdc.mint(address(this), 10000e6);
        usdc.approve(address(harness), type(uint256).max);

        harness.increaseCover(3e18);

        vm.warp(1);
        vm.prank(keeper);
        harness.postMark(5e18);

        // alice approves harness and deposits IM
        usdc.mint(alice, 10000e6);
        vm.prank(alice);
        usdc.approve(address(harness), type(uint256).max);
        vm.prank(alice);
        harness.deposit(5e6);

        vm.prank(alice);
        harness.openLong(1e18); // netWritten = 1e18

        // coverQty=3e18, netWritten=1e18
        // addQty=2e18: 3>=1+2 -> true (boundary exact)
        assertTrue(harness.coverCoversPublic(2e18));
        // addQty=3e18: 3>=1+3=4 -> false
        assertFalse(harness.coverCoversPublic(3e18));
    }
}
