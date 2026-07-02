// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {Test} from "forge-std/Test.sol";
import {EverlastingPut} from "../src/EverlastingPut.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockOracle} from "../src/MockOracle.sol";

contract PutHandler is Test {
    EverlastingPut public put; MockUSDC public usdc; MockOracle public oracle;
    address[] public actors;
    uint256 public marksPosted;
    constructor(EverlastingPut _p, MockUSDC _u, MockOracle _o, address[] memory _a){ put=_p; usdc=_u; oracle=_o; actors=_a; }
    function _actor(uint256 seed) internal view returns (address) { return actors[seed % actors.length]; }

    function postMark(uint256 m) external {
        uint256 lo = put.intrinsicWad();
        if (put.mark() != 0) {
            uint256 dhi = put.mark() + put.mark()*2000/10000;
            uint256 dlo = put.mark() - put.mark()*2000/10000;
            lo = dlo > lo ? dlo : lo;
            m = bound(m, lo, dhi < put.K() ? dhi : put.K());
        } else { m = bound(m, lo, put.K()); }
        vm.warp(block.timestamp + 3600);
        try put.postMark(m) { marksPosted++; } catch {}     // keeper == this handler now
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
}

contract PutInvariantTest is Test {
    EverlastingPut put; MockUSDC usdc; MockOracle oracle; PutHandler h;
    address[] actors;
    function setUp() public {
        usdc = new MockUSDC(); oracle = new MockOracle(); oracle.set(48e18);
        actors.push(address(0xA11CE)); actors.push(address(0xB0B)); actors.push(address(0xCA11));
        // AUDIT F4: deploy ONCE and make the FUZZED handler the keeper (predict its address by nonce)
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        put = new EverlastingPut(usdc, oracle, 48e18, predicted); // nonce N; lp = this
        h = new PutHandler(put, usdc, oracle, actors);            // nonce N+1 == predicted
        require(address(h) == predicted, "keeper wiring");
        usdc.mint(address(this), 1_000_000e6); usdc.approve(address(put), type(uint256).max);
        put.lpDeposit(500_000e6);
        targetContract(address(h));
    }
    function invariant_solvency() public view {
        uint256 sum = put.traderCollateral(address(this));
        for (uint256 i = 0; i < actors.length; i++) sum += put.traderCollateral(actors[i]);
        assertEq(usdc.balanceOf(address(put)), put.poolFree() + put.poolLocked() + sum);
    }
    // AUDIT F4: fail if postMark never actually landed (would make invariant_solvency vacuous)
    function afterInvariant() public view { assertGt(h.marksPosted(), 0, "no marks posted -> vacuous"); }
}
