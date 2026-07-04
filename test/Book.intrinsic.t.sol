// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {EverlastingBook} from "../src/EverlastingBook.sol";
import {MockCoverVault} from "../src/mocks/MockCoverVault.sol";
import {MockOracle} from "../src/MockOracle.sol";

/// @title BookIntrinsicTest
/// @notice Tests for EverlastingBook.intrinsic(side):
///   - PUT  : clamp(Kput − S, 0, Wput)  — capped at W
///   - CALL : max(S − Kcall, 0)          — uncapped (deep ITM 10·K → 9·K, no clamp)
///   - Side isolation: PUT and COVERED_CALL states/intrinsics are independent
contract BookIntrinsicTest is Test {
    MockCoverVault vault;
    MockOracle     oracle;
    EverlastingBook book;

    // Strikes and cap for the default book under test
    uint256 constant KPUT  = 100e18;  // put strike $100
    uint256 constant WPUT  = 50e18;   // put payout cap $50 (< K so the clamp is exercisable)
    uint256 constant KCALL = 120e18;  // call strike $120

    function setUp() public {
        vault  = new MockCoverVault();
        oracle = new MockOracle();
        book   = new EverlastingBook(
            vault,
            oracle,
            address(this), // keeper = test contract
            KPUT,
            WPUT,
            KCALL,
            10_000e18,     // putCapNotional
            10_000e18      // callCapNotional
        );
        vault.setMockPx(100e18); // initial mock spot (not used by intrinsic — oracle is separate)
        oracle.set(100e18);      // initial oracle spot
    }

    // ── PUT intrinsic ─────────────────────────────────────────────────────────

    function test_put_intrinsic_otm() public {
        oracle.set(110e18); // S > Kput → OTM
        assertEq(book.intrinsic(EverlastingBook.Side.PUT), 0);
    }

    function test_put_intrinsic_atK() public {
        oracle.set(KPUT); // S == Kput → zero intrinsic
        assertEq(book.intrinsic(EverlastingBook.Side.PUT), 0);
    }

    function test_put_intrinsic_itm_below_cap() public {
        oracle.set(80e18); // K - S = 20e18 < Wput=50e18 → no clamp
        assertEq(book.intrinsic(EverlastingBook.Side.PUT), 20e18);
    }

    /// @dev Clamp branch: K − S > Wput → returns Wput exactly
    function test_put_intrinsic_clamped_at_W() public {
        // S = 40e18 → K - S = 60e18 > Wput=50e18 → clamp to 50e18
        oracle.set(40e18);
        assertEq(book.intrinsic(EverlastingBook.Side.PUT), WPUT);
    }

    function test_put_intrinsic_deeply_clamped() public {
        oracle.set(0); // K - 0 = 100e18 >> Wput=50e18 → clamp
        assertEq(book.intrinsic(EverlastingBook.Side.PUT), WPUT);
    }

    // ── COVERED_CALL intrinsic (uncapped) ────────────────────────────────────

    function test_call_intrinsic_otm() public {
        oracle.set(110e18); // S < Kcall=120 → OTM
        assertEq(book.intrinsic(EverlastingBook.Side.COVERED_CALL), 0);
    }

    function test_call_intrinsic_atK() public {
        oracle.set(KCALL); // S == Kcall → zero
        assertEq(book.intrinsic(EverlastingBook.Side.COVERED_CALL), 0);
    }

    function test_call_intrinsic_itm() public {
        oracle.set(130e18); // S - K = 10e18
        assertEq(book.intrinsic(EverlastingBook.Side.COVERED_CALL), 10e18);
    }

    /// @dev Deep ITM: spot = 10·Kcall → intrinsic = 9·Kcall (NO upper clamp)
    function test_call_intrinsic_deep_itm_uncapped() public {
        oracle.set(10 * KCALL); // 1200e18
        uint256 expected = 9 * KCALL; // 1080e18
        assertEq(book.intrinsic(EverlastingBook.Side.COVERED_CALL), expected);
    }

    // ── Side isolation ────────────────────────────────────────────────────────

    /// @dev PUT deep ITM must not bleed into COVERED_CALL (which is OTM at same spot)
    function test_side_isolation_put_itm_call_otm() public {
        // spot=50: put ITM (100-50=50, capped at Wput=50), call OTM (50<120)
        oracle.set(50e18);
        assertEq(book.intrinsic(EverlastingBook.Side.PUT), WPUT, "put should be at W cap");
        assertEq(book.intrinsic(EverlastingBook.Side.COVERED_CALL), 0, "call should be 0");
    }

    /// @dev COVERED_CALL deep ITM must not bleed into PUT (which is OTM at same spot)
    function test_side_isolation_call_deep_itm_put_otm() public {
        // spot=10·Kcall: call deep ITM, put OTM (spot >> Kput)
        oracle.set(10 * KCALL);
        assertEq(book.intrinsic(EverlastingBook.Side.PUT), 0, "put should be 0 (OTM)");
        assertEq(
            book.intrinsic(EverlastingBook.Side.COVERED_CALL),
            9 * KCALL,
            "call deep ITM uncapped"
        );
    }

    /// @dev Both sides ITM simultaneously — no cross-contamination
    function test_side_isolation_both_itm() public {
        // Deploy a book where both strikes are above the spot so both are ITM:
        // put ITM when S < Kput, call ITM when S > Kcall.
        // Use spot that is between two different strikes to make one side each ITM
        // is impossible simultaneously with the same oracle value; test independent reads instead.
        //
        // Verify: changing oracle only affects intrinsic(S), not any per-side stored state cross-talk.
        oracle.set(90e18);
        uint256 putIntrinsic  = book.intrinsic(EverlastingBook.Side.PUT);          // 10e18 (uncapped)
        uint256 callIntrinsic = book.intrinsic(EverlastingBook.Side.COVERED_CALL); // 0 (OTM)

        // Reading call first, then put — order of reads must not matter
        oracle.set(150e18);
        uint256 callIntrinsic2 = book.intrinsic(EverlastingBook.Side.COVERED_CALL); // 30e18
        uint256 putIntrinsic2  = book.intrinsic(EverlastingBook.Side.PUT);           // 0 (OTM)

        assertEq(putIntrinsic,   10e18,  "put at 90");
        assertEq(callIntrinsic,  0,      "call OTM at 90");
        assertEq(callIntrinsic2, 30e18,  "call at 150");
        assertEq(putIntrinsic2,  0,      "put OTM at 150");
    }

    // ── sideState independence ────────────────────────────────────────────────

    /// @dev Verify per-side state slots are separate zero-initialized structs at construction
    function test_side_state_initialized_to_zero() public view {
        (uint256 markP, uint256 lmtP, uint256 cfP, uint256 liP, uint256 nwP) =
            book.sideState(uint8(EverlastingBook.Side.PUT));
        (uint256 markC, uint256 lmtC, uint256 cfC, uint256 liC, uint256 nwC) =
            book.sideState(uint8(EverlastingBook.Side.COVERED_CALL));

        assertEq(markP, 0);  assertEq(lmtP, 0);  assertEq(cfP, 0);
        assertEq(liP,   0);  assertEq(nwP,  0);
        assertEq(markC, 0);  assertEq(lmtC, 0);  assertEq(cfC, 0);
        assertEq(liC,   0);  assertEq(nwC,  0);
    }

    // ── poolUsdc delegation ───────────────────────────────────────────────────

    function test_poolUsdc_delegates_to_vault() public {
        // seed vault's USDC ledger; book should see it via poolUsdc()
        vault.pullUsdc(address(0), 7500e6);
        assertEq(book.poolUsdc(), 7500e6);
        assertEq(book.poolUsdc(), vault.poolUsdc());
    }

    // ── Constructor getters ───────────────────────────────────────────────────

    function test_constructor_getters() public view {
        assertEq(book.Kput(),            KPUT);
        assertEq(book.Wput(),            WPUT);
        assertEq(book.Kcall(),           KCALL);
        assertEq(book.putCapNotional(),  10_000e18);
        assertEq(book.callCapNotional(), 10_000e18);
        assertEq(address(book.vault()),  address(vault));
        assertEq(address(book.oracle()), address(oracle));
        assertEq(book.keeper(),          address(this));
    }
}
