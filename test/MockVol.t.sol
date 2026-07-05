// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {Test} from "forge-std/Test.sol";
import {MockVol} from "../src/mocks/MockVol.sol";
import {IVolSource} from "../src/interfaces/IVolSource.sol";
import {RealizedVol} from "../src/RealizedVol.sol";
import {ISpotOracle} from "../src/interfaces/ISpotOracle.sol";
import {MockOracle} from "../src/MockOracle.sol";

contract MockVolTest is Test {
    MockOracle oracle;

    function setUp() public {
        oracle = new MockOracle();
        oracle.set(50e18);
    }

    function test_mockVol_reportsSetSigmaAndReady() public {
        MockVol v = new MockVol();
        v.setSigma(1.2e18);
        v.setReady(false);
        assertEq(v.sigma(), 1.2e18);
        assertEq(v.ready(), false);
        IVolSource(address(v)).updateVol(); // no-op, no revert
    }

    function test_realizedVol_isIVolSource() public {
        // compile-time proof RealizedVol satisfies the interface
        IVolSource v = IVolSource(address(new RealizedVol(ISpotOracle(address(oracle)))));
        v.ready();
    }
}
