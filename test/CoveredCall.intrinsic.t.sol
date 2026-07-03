// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from 'forge-std/Test.sol';
import {CoveredCallMarket} from '../src/CoveredCallMarket.sol';
import {MockUSDC} from '../src/MockUSDC.sol';
import {MockOracle} from '../src/MockOracle.sol';
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CallCoveredIntrinsicTest is Test {
    MockUSDC usdc;
    MockOracle oracle;
    CoveredCallMarket market;
    address alice = address(0xa11ce);

    function setUp() public {
        usdc = new MockUSDC();
        oracle = new MockOracle();
        market = new CoveredCallMarket(IERC20(address(usdc)), oracle, 48e18, address(this));

        usdc.mint(address(this), 10000e6);
        usdc.approve(address(market), type(uint256).max);

        usdc.mint(alice, 10000e6);
        vm.prank(alice);
        usdc.approve(address(market), type(uint256).max);
    }

    function test_intrinsic_otm() public {
        oracle.set(45e18);
        assertEq(market.intrinsicWad(), 0);
    }

    function test_intrinsic_atK() public {
        oracle.set(48e18);
        assertEq(market.intrinsicWad(), 0);
    }

    function test_intrinsic_itm() public {
        oracle.set(48e18 + 3e18);
        assertEq(market.intrinsicWad(), 3e18);
    }

    function test_intrinsic_deepItm_uncapped() public {
        oracle.set(10 * 48e18);
        assertEq(market.intrinsicWad(), 9 * 48e18);
    }

    function test_lpDeposit_movesPoolUsdc() public {
        market.lpDeposit(1000e6);
        assertEq(market.poolUsdc(), 1000e6);
    }

    function test_lpWithdraw_movesPoolUsdc() public {
        market.lpDeposit(1000e6);
        market.lpWithdraw(400e6);
        assertEq(market.poolUsdc(), 600e6);
    }

    function test_traderDeposit() public {
        vm.prank(alice);
        market.deposit(500e6);
        assertEq(market.traderCollateral(alice), 500e6);
    }

    function test_traderWithdraw() public {
        vm.prank(alice);
        market.deposit(500e6);
        vm.prank(alice);
        market.withdraw(200e6);
        assertEq(market.traderCollateral(alice), 300e6);
    }

    function test_withdraw_revertsWithOpenPosition() public {
        vm.prank(alice);
        market.deposit(100e6);

        bytes32 slot = keccak256(abi.encode(alice, 10));
        vm.store(address(market), slot, bytes32(uint256(1e18)));

        vm.prank(alice);
        vm.expectRevert("close first");
        market.withdraw(1);
    }
}
