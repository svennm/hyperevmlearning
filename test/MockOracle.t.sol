// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {Test} from "forge-std/Test.sol";
import {MockOracle} from "../src/MockOracle.sol";
contract MockOracleTest is Test {
    function test_setGet() public {
        MockOracle o = new MockOracle();
        o.set(48e18);
        assertEq(o.spotWad(), 48e18);
    }
}
