// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {Test} from "forge-std/Test.sol";
import {EverlastingMarket} from "../src/EverlastingMarket.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockOracle} from "../src/MockOracle.sol";

contract CallHandler is Test {
    EverlastingMarket public c; MockUSDC public usdc; MockOracle public oracle;
    address[] public actors; uint256 public marksPosted;
    constructor(EverlastingMarket _c, MockUSDC _u, MockOracle _o, address[] memory _a){ c=_c; usdc=_u; oracle=_o; actors=_a; }
    function _actor(uint256 seed) internal view returns (address){ return actors[seed % actors.length]; }
    function postMark(uint256 m) external {
        uint256 lo = c.intrinsicWad();
        if (c.mark() != 0) {
            uint256 dhi = c.mark() + c.mark()*2000/10000;
            uint256 dlo = c.mark() - c.mark()*2000/10000;
            lo = dlo > lo ? dlo : lo;
            m = bound(m, lo, dhi < c.W() ? dhi : c.W());
        } else { m = bound(m, lo, c.W()); }
        vm.warp(block.timestamp + 3600);
        try c.postMark(m) { marksPosted++; } catch {}
    }
    function moveSpot(uint256 s) external { oracle.set(bound(s, 1e18, 120e18)); } // spans above K_hi=54
    function deposit(uint256 seed, uint256 amt) external {
        address a=_actor(seed); amt=bound(amt,0,1_000e6);
        usdc.mint(a, amt); vm.startPrank(a); usdc.approve(address(c), amt);
        try c.deposit(amt) {} catch {} vm.stopPrank();
    }
    function openLong(uint256 seed, uint256 qty) external { address a=_actor(seed); qty=bound(qty,0,5e18); vm.prank(a); try c.openLong(qty) {} catch {} }
    function closePos(uint256 seed) external { address a=_actor(seed); vm.prank(a); try c.close() {} catch {} }
    function settlePos(uint256 seed) external { address a=_actor(seed); try c.settle(a) {} catch {} }
}

contract CallInvariantTest is Test {
    EverlastingMarket c; MockUSDC usdc; MockOracle oracle; CallHandler h;
    address[] actors;
    function setUp() public {
        usdc = new MockUSDC(); oracle = new MockOracle(); oracle.set(48e18);
        actors.push(address(0xA11CE)); actors.push(address(0xB0B)); actors.push(address(0xCA11));
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        c = new EverlastingMarket(usdc, oracle, EverlastingMarket.Side.CALL, 48e18, 6e18, predicted);
        h = new CallHandler(c, usdc, oracle, actors);
        require(address(h) == predicted, "keeper wiring");
        usdc.mint(address(this), 1_000_000e6); usdc.approve(address(c), type(uint256).max);
        c.lpDeposit(500_000e6);
        targetContract(address(h));
    }
    function invariant_solvency() public view {
        uint256 sum = c.traderCollateral(address(this));
        for (uint256 i=0;i<actors.length;i++) sum += c.traderCollateral(actors[i]);
        assertEq(usdc.balanceOf(address(c)), c.poolFree() + c.poolLocked() + sum);
    }
    function afterInvariant() public view { assertGt(h.marksPosted(), 0, "no marks -> vacuous"); }
}
