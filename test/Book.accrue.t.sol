// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {EverlastingBook} from "../src/EverlastingBook.sol";
import {RealizedVol} from "../src/RealizedVol.sol";
import {MockCoverVault} from "../src/mocks/MockCoverVault.sol";
import {MockOracle} from "../src/MockOracle.sol";
import {MockVol} from "../src/mocks/MockVol.sol";
import {ICoverVault} from "../src/interfaces/ICoverVault.sol";
import {ISpotOracle} from "../src/interfaces/ISpotOracle.sol";

/// @notice Task 4 — permissionless accrue(): fold funding using the stored period-start mark,
///         then refresh the stored mark to the on-chain computed fair value (_computedMark).
///         No keeper required; anyone may call.
contract BookAccrueTest is Test {
    EverlastingBook book;
    MockCoverVault vault;
    MockOracle oracle;
    MockVol mockVol;

    EverlastingBook.Side constant PUT  = EverlastingBook.Side.PUT;
    EverlastingBook.Side constant CALL = EverlastingBook.Side.COVERED_CALL;

    function setUp() public {
        vault   = new MockCoverVault();
        oracle  = new MockOracle();
        oracle.set(100e18); // baseline spot; overridden per-test

        // keeper = owner = address(this) for simplicity (no onlyKeeper calls here)
        book = new EverlastingBook(
            ICoverVault(address(vault)),
            ISpotOracle(address(oracle)),
            address(this),  // keeper
            100e18,         // Kput
            20e18,          // Wput
            120e18,         // Kcall — with S=33 both sides are OTM (call) / deep ITM (put)
            100e18,         // putCapNotional
            100e18          // callCapNotional
        );

        // Wire MockVol via cast — setVol accepts RealizedVol but any contract with the
        // same ABI (sigma/ready/updateVol) works at runtime. MockVol defaults: sigma=0.8e18, ready=true.
        mockVol = new MockVol();
        book.setVol(RealizedVol(address(mockVol)));
    }

    // ── Step 1 tests (written before implementation — will FAIL until accrue is added) ──

    /// @notice accrue() stores the on-chain computed fair value as the new mark.
    function test_accrue_setsMarkToComputedFairValue() public {
        mockVol.setSigma(0.8e18);
        oracle.set(33e18);              // S=$33 → OTM call (33 < 120)
        book.accrue(CALL);              // permissionless — no prank
        (uint256 mark,,,,) = book.sideState(uint8(CALL));
        assertEq(mark, book.fairMark(CALL), "mark == on-chain fair value");
    }

    /// @notice accrue() folds funding using the STORED period-start mark (not the new one).
    function test_accrue_foldsFundingOverElapsedPeriods() public {
        mockVol.setSigma(0.8e18);
        oracle.set(33e18);              // OTM call → intrinsic = 0
        book.accrue(CALL);
        (uint256 m0,,,,) = book.sideState(uint8(CALL));
        vm.warp(block.timestamp + 2 * book.FUNDING_PERIOD());
        book.accrue(CALL);
        (,, uint256 cum,,) = book.sideState(uint8(CALL));
        // f = m0 - lastIntrinsic(=0 for OTM call) + P(U)(=0 at U=0); cum = f * 2 periods
        assertEq(cum, m0 * 2, "funding = mark * periods for OTM call at U=0");
    }

    /// @notice accrue() may be called by any address — it is fully permissionless.
    function test_accrue_isPermissionless() public {
        oracle.set(33e18);
        vm.prank(address(0xBEEF));      // random caller
        book.accrue(PUT);               // must not revert
    }
}
