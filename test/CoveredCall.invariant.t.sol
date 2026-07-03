// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CoveredCallMarket} from "../src/CoveredCallMarket.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockOracle} from "../src/MockOracle.sol";

contract CoveredCallInvariantHandler is Test {
    CoveredCallMarket public mkt;
    MockUSDC public usdc;
    MockOracle public oracle;
    address[] public actors;
    uint256 public marksPosted;
    uint256 public longsOpened;

    constructor(CoveredCallMarket _mkt, MockUSDC _usdc, MockOracle _oracle, address[] memory _actors) {
        mkt = _mkt;
        usdc = _usdc;
        oracle = _oracle;
        actors = _actors;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function increaseCover(uint256 qty) external {
        qty = bound(qty, 1e18, 500e18);
        try mkt.increaseCover(qty) {} catch {}
    }

    function postMark(uint256 m) external {
        uint256 intrinsic = mkt.intrinsicWad();
        if (mkt.mark() == 0 || block.timestamp > mkt.lastMarkTime() + mkt.MAX_MARK_AGE()) {
            m = bound(m, intrinsic > 0 ? intrinsic : 1e15, intrinsic + 500e18);
        } else {
            uint256 dhi = mkt.mark() + mkt.mark() * 2000 / 10000;
            uint256 raw_lo = mkt.mark() >= mkt.mark() * 2000 / 10000 ? mkt.mark() - mkt.mark() * 2000 / 10000 : 0;
            uint256 lo = raw_lo > intrinsic ? raw_lo : intrinsic;
            m = bound(m, lo, dhi);
        }
        vm.warp(block.timestamp + mkt.FUNDING_PERIOD());
        try mkt.postMark(m) {
            marksPosted++;
        } catch {}
    }

    function moveSpot(uint256 s) external {
        oracle.set(bound(s, 1e18, 1000 * mkt.K()));
    }

    function openLong(uint256 seed, uint256 qty) external {
        address a = _actor(seed);
        qty = bound(qty, 1e17, 3e18);

        if (mkt.mark() == 0 || block.timestamp > mkt.lastMarkTime() + mkt.MAX_MARK_AGE()) return;

        // Generous cover top-up before open attempt so cover gate is satisfied
        try mkt.increaseCover(qty * 3) {} catch {}

        uint256 imUsdc = qty * mkt.mark() / 1e30 + 1;
        usdc.mint(a, imUsdc);
        vm.startPrank(a);
        usdc.approve(address(mkt), imUsdc);
        try mkt.deposit(imUsdc) {} catch {}
        try mkt.openLong(qty) {
            longsOpened++;
        } catch {}
        vm.stopPrank();
    }

    function closePos(uint256 seed) external {
        address a = _actor(seed);
        vm.prank(a);
        try mkt.close() {} catch {}
    }

    function settlePos(uint256 seed) external {
        address a = _actor(seed);
        try mkt.settle(a) {} catch {}
    }
}

contract CoveredCallInvariantTest is Test {
    MockUSDC usdc;
    MockOracle oracle;
    CoveredCallMarket market;
    CoveredCallInvariantHandler h;
    address[] actors = [address(0xA11CE), address(0xB0B), address(0xCA11)];
    uint256 constant K = 40e18;

    function setUp() public {
        usdc = new MockUSDC();
        oracle = new MockOracle();
        oracle.set(50e18);

        // Nonce-predict the handler so it becomes the keeper.
        // After MockUSDC (nonce 1) + MockOracle (nonce 2), getNonce==3.
        // market deploys at nonce 3; handler deploys at nonce 4 == predicted.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        market = new CoveredCallMarket(IERC20(address(usdc)), oracle, K, predicted);
        h = new CoveredCallInvariantHandler(market, usdc, oracle, actors);
        require(address(h) == predicted, "keeper wiring");

        usdc.mint(address(this), 1_000_000e6);
        usdc.approve(address(market), type(uint256).max);
        market.lpDeposit(500_000e6);

        targetContract(address(h));
    }

    // Value conservation: the contract's real USDC balance equals its internal accounting
    // (pool + every trader's collateral). This is the load-bearing 3a solvency invariant — it
    // fails on ANY arithmetic leak in close()/settle()/deposit/withdraw's fund movements, and
    // unlike the old intrinsic-vs-cover check it actually exercises poolUsdc. No fees/float in 3a,
    // so those terms are absent.
    function invariant_conservation() public view {
        uint256 acct = market.poolUsdc();
        for (uint256 i = 0; i < actors.length; i++) {
            acct += market.traderCollateral(actors[i]);
        }
        assertEq(usdc.balanceOf(address(market)), acct, "conservation: balance != pool + collateral");
    }

    // Cover-gate: the contract must always keep enough HYPE cover to back every open short call.
    // (This is the relationship the old "solvencyGivenCover" assertion actually proved — stated
    // honestly here. It does NOT establish that poolUsdc can fund close() payouts; realizing the
    // cover into USDC on close is 3b.)
    function invariant_coverGate() public view {
        assertGe(market.coverQty(), market.netWritten(), "coverGate: coverQty < netWritten");
    }

    // Non-vacuity: real marks and real opens must have landed
    function afterInvariant() public view {
        assertGt(h.marksPosted(), 0, "vacuous: no marks posted");
        assertGt(h.longsOpened(), 0, "vacuous: no longs opened");
    }
}
