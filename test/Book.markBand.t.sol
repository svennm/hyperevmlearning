// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {EverlastingBook} from "../src/EverlastingBook.sol";
import {RealizedVol} from "../src/RealizedVol.sol";
import {MockCoverVault} from "../src/mocks/MockCoverVault.sol";
import {MockOracle} from "../src/MockOracle.sol";
import {ICoverVault} from "../src/interfaces/ICoverVault.sol";
import {ISpotOracle} from "../src/interfaces/ISpotOracle.sol";

/// @notice Unit 3 — the on-chain fair-value band (H2 fix). Once RealizedVol is wired + ready, the
///         keeper mark is bound to ±MARK_BAND_BPS of fairMark(), an ABSOLUTE anchor (no compounding).
contract BookMarkBandTest is Test {
    EverlastingBook book;
    RealizedVol vol;
    MockCoverVault vault;
    MockOracle oracle;
    address keeper = address(0xBEEF);

    EverlastingBook.Side constant PUT  = EverlastingBook.Side.PUT;
    EverlastingBook.Side constant CALL = EverlastingBook.Side.COVERED_CALL;

    function setUp() public {
        vault = new MockCoverVault();
        oracle = new MockOracle();
        oracle.set(100e18);
        book = new EverlastingBook(
            ICoverVault(address(vault)), ISpotOracle(address(oracle)),
            keeper, 100e18, 20e18, 120e18, 100e18, 100e18
        );
        vol = new RealizedVol(oracle);
        book.setVol(vol);
        vol.updateVol();      // seed @ 100
        skip(3600);
        oracle.set(101e18);   // ~1% move
        vol.updateVol();      // ready()
        oracle.set(100e18);   // clean ATM for fair
    }

    function _post(EverlastingBook.Side s, uint256 m) internal {
        vm.prank(keeper);
        book.postMark(s, m);
    }

    function test_fairMark_sane() public view {
        assertTrue(vol.ready());
        uint256 fairP = book.fairMark(PUT);
        uint256 fairC = book.fairMark(CALL);
        assertGt(fairP, 0);
        assertLt(fairP, 20e18);   // capped put spread ≤ Wput
        assertGt(fairC, 0);
    }

    function test_fairMark_acrossMoneyness_noRevert() public {
        // Exercises the skew path (OTM put) + basket at ITM/ATM/OTM without reverting.
        oracle.set(70e18);  book.fairMark(PUT); book.fairMark(CALL);
        oracle.set(100e18); book.fairMark(PUT); book.fairMark(CALL);
        oracle.set(160e18); book.fairMark(PUT); book.fairMark(CALL);
    }

    function test_band_acceptInside_rejectOutside() public {
        uint256 fair = book.fairMark(PUT);
        _post(PUT, fair);                       // exact
        _post(PUT, fair * 10500 / 10000);       // +5% inside band
        _post(PUT, fair * 9500 / 10000);        // −5% inside band

        vm.prank(keeper);
        vm.expectRevert("mark band");
        book.postMark(PUT, fair * 11500 / 10000); // +15% > band

        vm.prank(keeper);
        vm.expectRevert("mark band");
        book.postMark(PUT, fair * 8000 / 10000);  // −20% < band
    }

    /// @notice H2: the keeper can no longer ramp the mark. Even after posting at the +10% band edge,
    ///         a further move the OLD per-update cap (±20% of the PREVIOUS mark) would have allowed is
    ///         rejected — the band is anchored to fair value, not to the last mark.
    function test_H2_rampBounded() public {
        uint256 fair = book.fairMark(CALL);
        _post(CALL, fair * 11000 / 10000);      // at the +10% edge (allowed)
        // Old deviation cap would allow previous·1.2 = fair·1.32. The band rejects it.
        vm.prank(keeper);
        vm.expectRevert("mark band");
        book.postMark(CALL, fair * 11000 / 10000 * 12000 / 10000);
    }

    /// @notice Bootstrap: with no vol wired, postMark falls back to the relative deviation cap.
    function test_bootstrap_deviationCapWhenNoVol() public {
        EverlastingBook b2 = new EverlastingBook(
            ICoverVault(address(vault)), ISpotOracle(address(oracle)),
            keeper, 100e18, 20e18, 120e18, 100e18, 100e18
        ); // vol not set ⇒ band inactive
        oracle.set(100e18);
        vm.prank(keeper); b2.postMark(CALL, 10e18);
        skip(3600);
        vm.prank(keeper);
        vm.expectRevert("mark deviation");
        b2.postMark(CALL, 13e18); // +30% > 20% deviation cap
    }
}
