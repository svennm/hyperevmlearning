// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {DeltaHedgeManager, IEverlastingBook} from "../src/DeltaHedgeManager.sol";
import {MockCoverVault} from "../src/mocks/MockCoverVault.sol";
import {MockOracle} from "../src/MockOracle.sol";

contract MockBook is IEverlastingBook {
    uint256 public Kput;
    uint256 public Wput;
    uint256 public Kcall;
    address public oracle;

    uint256 public poolFreeVal;
    bool public poolFreeReverts;

    mapping(uint8 => uint256) public nw;

    constructor(uint256 _kput, uint256 _wput, uint256 _kcall, address _oracle) {
        Kput = _kput;
        Wput = _wput;
        Kcall = _kcall;
        oracle = _oracle;
    }

    function setNetWritten(uint8 side, uint256 v) external {
        nw[side] = v;
    }

    function setPoolFree(uint256 v) external {
        poolFreeVal = v;
    }

    function setPoolFreeReverts(bool b) external {
        poolFreeReverts = b;
    }

    function sideState(uint8 s) external view returns (uint256,uint256,uint256,uint256,uint256) {
        return (0,0,0,0,nw[s]);
    }

    function poolFree() external view returns (uint256) {
        require(!poolFreeReverts, "poolFree underflow");
        return poolFreeVal;
    }
}

contract DeltaHedgeTest is Test {
    uint256 constant KPUT = 100e18;
    uint256 constant WPUT = 50e18;
    uint256 constant KCALL = 120e18;

    MockBook book;
    MockCoverVault vault;
    MockOracle oracle;
    DeltaHedgeManager mgr;

    uint8 PUT_U = 0;
    uint8 CALL_U = 1;

    function setUp() public {
        oracle = new MockOracle();
        vault = new MockCoverVault();
        book = new MockBook(KPUT, WPUT, KCALL, address(oracle));
        mgr  = new DeltaHedgeManager(book, vault, address(this));
    }

    function _seedCover(uint256 hypeWad, uint256 pxWad) internal {
        vault.setMockPx(pxWad);
        vault.pullUsdc(address(this), 1_000_000_000e6);
        vault.buyCover(hypeWad, type(uint256).max);
    }

    function _setSpot(uint256 s) internal {
        oracle.set(s);
    }

    function test_poolNetDelta_callOTM_putOTM() public {
        _seedCover(10e18, 100e18);
        book.setNetWritten(CALL_U, 4e18);
        book.setNetWritten(PUT_U, 3e18);
        _setSpot(100e18);
        assertEq(mgr.poolNetDelta(), int256(10e18));
    }

    function test_poolNetDelta_callITM() public {
        _seedCover(10e18, 100e18);
        book.setNetWritten(CALL_U, 4e18);
        book.setNetWritten(PUT_U, 3e18);
        _setSpot(130e18);
        assertEq(mgr.poolNetDelta(), int256(6e18));
    }

    function test_poolNetDelta_putITM_linear() public {
        _seedCover(10e18, 100e18);
        book.setNetWritten(CALL_U, 4e18);
        book.setNetWritten(PUT_U, 3e18);
        _setSpot(70e18);
        assertEq(mgr.poolNetDelta(), int256(13e18));
    }

    function test_poolNetDelta_putCappedFlat() public {
        _seedCover(10e18, 100e18);
        book.setNetWritten(CALL_U, 4e18);
        book.setNetWritten(PUT_U, 3e18);
        _setSpot(40e18);
        assertEq(mgr.poolNetDelta(), int256(10e18));
    }

    function test_deltaBounds_nonNegative() public {
        _seedCover(10e18, 100e18);
        book.setNetWritten(CALL_U, 8e18);
        book.setNetWritten(PUT_U, 3e18);
        (int256 lo, int256 hi) = mgr.deltaBounds();
        assertEq(lo, int256(2e18));
        assertEq(hi, int256(13e18));
        assertTrue(lo >= 0);
        assertTrue(hi >= 0);
    }

    function test_trimCoverForDelta_atFloor_ok() public {
        _seedCover(10e18, 100e18);
        book.setNetWritten(CALL_U, 8e18);
        mgr.trimCoverForDelta(2e18);
        assertEq(vault.coverHype(), 8e18);
    }

    function test_trimCoverForDelta_breachesFloor_reverts() public {
        _seedCover(10e18, 100e18);
        book.setNetWritten(CALL_U, 8e18);
        vm.expectRevert(bytes("coverGate floor"));
        mgr.trimCoverForDelta(2e18 + 1e16);
    }

    function test_addCoverBuffer_poolFreeOnly_reverts() public {
        _seedCover(1e18, 100e18);
        book.setPoolFree(100e6);
        vm.expectRevert(bytes("poolFree"));
        mgr.addCoverBuffer(1e16, 200e6);
    }

    function test_addCoverBuffer_withinPoolFree_ok() public {
        _seedCover(1e18, 100e18);
        book.setPoolFree(1_000e6);
        mgr.addCoverBuffer(1e16, 100e6);
        assertEq(vault.coverHype(), 1e18 + 1e16);
    }

    function test_assertHedgeInvariants_ok() public {
        _seedCover(10e18, 100e18);
        book.setNetWritten(CALL_U, 8e18);
        book.setPoolFree(1e6);
        mgr.assertHedgeInvariants();
    }

    function test_assertHedgeInvariants_coverGateBreach_reverts() public {
        _seedCover(5e18, 100e18);
        book.setNetWritten(CALL_U, 8e18);
        vm.expectRevert(bytes("coverGate"));
        mgr.assertHedgeInvariants();
    }

    function test_assertHedgeInvariants_poolFreeUnderflow_reverts() public {
        _seedCover(10e18, 100e18);
        book.setNetWritten(CALL_U, 8e18);
        book.setPoolFreeReverts(true);
        vm.expectRevert(bytes("poolFree underflow"));
        mgr.assertHedgeInvariants();
    }

    function test_onlyKeeper_trim_reverts() public {
        _seedCover(10e18, 100e18);
        book.setNetWritten(CALL_U, 1e18);
        vm.prank(address(0xBEEF));
        vm.expectRevert(bytes("not keeper"));
        mgr.trimCoverForDelta(1e16);
    }
}
