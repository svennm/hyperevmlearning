// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {Test} from "forge-std/Test.sol";
import {EverlastingMarket} from "../src/EverlastingMarket.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockOracle} from "../src/MockOracle.sol";
import {MockYieldAdapter} from "../src/MockYieldAdapter.sol";

contract FeeFloatHandler is Test {
    EverlastingMarket public put; MockUSDC public usdc; MockOracle public oracle; MockYieldAdapter public adapter;
    address[] public actors;
    uint256 public marksPosted;
    constructor(EverlastingMarket _p, MockUSDC _u, MockOracle _o, MockYieldAdapter _a, address[] memory _actors){
        put = _p; usdc = _u; oracle = _o; adapter = _a; actors = _actors;
    }
    function _actor(uint256 seed) internal view returns (address) { return actors[seed % actors.length]; }

    function postMark(uint256 m) external {
        uint256 lo = put.intrinsicWad();
        if (put.mark() != 0) {
            uint256 dhi = put.mark() + put.mark()*2000/10000;
            uint256 dlo = put.mark() - put.mark()*2000/10000;
            lo = dlo > lo ? dlo : lo;
            m = bound(m, lo, dhi < put.W() ? dhi : put.W());
        } else { m = bound(m, lo, put.W()); }
        vm.warp(block.timestamp + 3600);
        try put.postMark(m) { marksPosted++; } catch {}
    }
    function moveSpot(uint256 s) external { oracle.set(bound(s, 1e18, 96e18)); }
    function deposit(uint256 seed, uint256 amt) external {
        address a = _actor(seed); amt = bound(amt, 0, 1_000e6);
        usdc.mint(a, amt); vm.startPrank(a); usdc.approve(address(put), amt);
        try put.deposit(amt) {} catch {} vm.stopPrank();
    }
    function openLong(uint256 seed, uint256 qty) external {
        address a = _actor(seed); qty = bound(qty, 0, 5e18);
        vm.prank(a); try put.openLong(qty) {} catch {}
    }
    function closePos(uint256 seed) external { address a=_actor(seed); vm.prank(a); try put.close() {} catch {} }
    function settlePos(uint256 seed) external { address a=_actor(seed); try put.settle(a) {} catch {} }

    function sweepToYield() external {
        try put.sweepToYield() {} catch {}
    }

    function harvest() external {
        try put.harvest() {} catch {}
    }
}

contract FeeFloatInvariantTest is Test {
    EverlastingMarket put; MockUSDC usdc; MockOracle oracle; MockYieldAdapter adapter; FeeFloatHandler h;
    address[] actors;

    function setUp() public {
        usdc = new MockUSDC(); oracle = new MockOracle(); oracle.set(48e18);
        actors.push(address(0xA11CE)); actors.push(address(0xB0B)); actors.push(address(0xCA11));

        // Nonce accounting: MockUSDC (0) + MockOracle (1) consumed; current nonce = 2.
        // Deploy order: market (nonce 2), adapter (nonce 3), handler (nonce 4).
        // Handler predicted at currentNonce + 2.
        uint256 currentNonce = vm.getNonce(address(this));
        address predicted = vm.computeCreateAddress(address(this), currentNonce + 2);

        put = new EverlastingMarket(usdc, oracle, EverlastingMarket.Side.PUT, 48e18, 48e18, predicted);
        adapter = new MockYieldAdapter(usdc, address(put));

        h = new FeeFloatHandler(put, usdc, oracle, adapter, actors);

        require(address(h) == predicted, "keeper wiring");

        usdc.mint(address(this), 1_000_000e6); usdc.approve(address(put), type(uint256).max);
        put.lpDeposit(500_000e6);

        put.setProtocolFeeBps(1000);
        put.setYieldAdapter(address(adapter));
        put.setReserveBps(2000);

        targetContract(address(h));
    }

    function invariant_conservation() public view {
        uint256 sumTraderCollateral = put.traderCollateral(address(this));
        for (uint256 i = 0; i < actors.length; i++) {
            sumTraderCollateral += put.traderCollateral(actors[i]);
        }
        assertEq(usdc.balanceOf(address(put)), put.poolFree() + put.poolLocked() + sumTraderCollateral + put.feeAccrued());
        assertGe(adapter.balance(), put.deployedToYield());
    }

    function afterInvariant() public view {
        assertGt(h.marksPosted(), 0, "no marks posted -> vacuous");
    }
}
