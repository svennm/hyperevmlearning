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
        vol.updateVol();                                   // seed @ 100
        // READY_SAMPLES(3) folds of small moves so vol.ready() and the band activates.
        skip(3600); oracle.set(101e18); vol.updateVol();   // sample 1
        skip(3600); oracle.set(100e18); vol.updateVol();   // sample 2
        skip(3600); oracle.set(101e18); vol.updateVol();   // sample 3 → ready()
        oracle.set(100e18);                                // clean ATM for fair
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

    /// @notice AUDIT-H regression: a capped put SPREAD's fair value dips below its intrinsic in a
    ///         crash (spot ITM through the strikes). Without the intrinsic-floor on the band, the
    ///         newMark≥intrinsic and newMark≤fair·1.1 constraints have no overlap ⇒ PUT postMark
    ///         bricked. The fix floors the band at intrinsic so a valid mark always exists.
    function test_crashBrick_fixed() public {
        // Raise σ with a (capped) 10% move so the spread fair falls below intrinsic in the ITM region.
        skip(3600);
        oracle.set(110e18);
        vol.updateVol();
        assertGt(vol.sigma(), 0.5e18);

        oracle.set(80e18); // spot crashes ITM through Kput=100
        uint256 intr = book.intrinsic(PUT);
        assertEq(intr, 20e18); // clamp(100-80, 0, Wput=20)
        uint256 fair = book.fairMark(PUT);
        assertLt(fair * 11000 / 10000, intr); // the empty-intersection condition the audit found

        // With the fix, the keeper can still post (at intrinsic) — no brick.
        _post(PUT, intr);
        (uint256 m,,,,) = book.sideState(uint8(PUT));
        assertEq(m, intr);
    }

    /// @notice F1: postMark pings updateVol() so σ is sampled at every mark (a spike present at
    ///         mark-time is folded in), reducing the reliance on a separate off-chain observer.
    function test_postMark_pingsUpdateVol() public {
        uint256 s0 = vol.samples();
        skip(3600);
        oracle.set(110e18);              // +10% spike live at mark time
        uint256 sigBefore = vol.sigma();
        _post(PUT, book.fairMark(PUT));  // keeper posts → postMark pings updateVol → folds the spike
        assertEq(vol.samples(), s0 + 1, "postMark folded a vol sample");
        assertGt(vol.sigma(), sigBefore, "sigma rose from the spike captured at mark time");
    }

    /// @notice The ping is AFTER the band check: it never widens/moves THIS post's band, only refreshes
    ///         σ for future marks. Same-block reposts see a stable band (intra-period record, no fold).
    function test_ping_doesNotDisturbThisPostsBand() public {
        uint256 fair = book.fairMark(PUT);
        _post(PUT, fair);
        _post(PUT, fair * 10500 / 10000); // +5% inside band — unaffected by the end-of-call ping
        vm.prank(keeper);
        vm.expectRevert("mark band");
        book.postMark(PUT, fair * 11500 / 10000); // +15% still rejected
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
