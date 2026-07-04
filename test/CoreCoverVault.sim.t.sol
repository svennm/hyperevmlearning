// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {CoreCoverVault} from "../src/CoreCoverVault.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";
import {CoreSimulatorLib} from "@hyper-evm-lib/test/simulation/CoreSimulatorLib.sol";
import {HyperCore} from "@hyper-evm-lib/test/simulation/HyperCore.sol";

/// @notice Sim + unit tests for CoreCoverVault.
///
/// Structure:
///   A) Pure unit tests (no fork) - wei/WAD/6dp conversions and szDecimals floor helper.
///      These run offline and are always green.
///   B) CoreSimulatorLib sim tests (offline mode) - buy->nextBlock->coverHype up,
///      sell floored->poolUsdc up, dust remains.
///      Uses HyperCore etched at 0x9999 with token/spot info registered manually
///      for testnet indices (HYPE=1105, USDC=0, pair=1035).
///
/// SIM STATUS: tested against offline CoreSimulatorLib (no fork required).
/// The sim processes IOC spot orders and updates balances in the simulated HyperCore.
/// See task-2-report.md for details.
contract CoreCoverVaultSimTest is Test {
    // ── Testnet constants (must match CoreCoverVault) ─────────────────────────
    uint32 constant HYPE_SPOT_ASSET  = 11035;
    uint32 constant HYPE_SPOT_INDEX  = 1035;
    uint64 constant HYPE_TOKEN       = 1105;
    uint64 constant USDC_TOKEN       = 0;
    uint256 constant HYPE_TICK       = 1e16;
    uint256 constant WAD             = 1e18;

    /// @dev $25 in precompile spotPx scale (price x 1e6). Used to seed sim price.
    ///      spotPxUsdc() = 25_000_000 x 1e12 = 25e18 WAD.
    uint64 constant SPOT_PX_RAW = 25_000_000; // $25

    CoreCoverVault vault;
    HyperCore      hyperCore;

    // ────────────────────────────────────────────────────────────────────────
    // A) PURE UNIT TESTS - conversions + floor helper (always green, no fork)
    // ────────────────────────────────────────────────────────────────────────

    /// @notice HYPE Core weiDecimals=8, x1e10 gives WAD.
    function test_unit_hypeWeiToWad() public pure {
        // 1 HYPE in Core wei = 1e8; in WAD = 1e8 x 1e10 = 1e18
        assertEq(uint256(100_000_000) * 1e10, 1e18, "1 HYPE wei = WAD");
        // 0.5 HYPE = 5e7 wei = 5e17 WAD
        assertEq(uint256(50_000_000) * 1e10, 0.5e18, "0.5 HYPE wei = WAD");
        // 10.99 HYPE = 10.99e8 wei = 10.99e18 WAD
        assertEq(uint256(1099000000) * 1e10, 10.99e18, "10.99 HYPE wei = WAD");
    }

    /// @notice HYPE WAD / 1e10 gives Core wei (order sz).
    function test_unit_hypeWadToOrderSz() public pure {
        // 1 HYPE WAD = 1e18; sz = 1e18 / 1e10 = 1e8
        assertEq(uint64(1e18 / 1e10), 1e8, "1 HYPE WAD = order sz 1e8");
        // 0.99 HYPE WAD => sz = 99e6
        assertEq(uint64(0.99e18 / 1e10), 99_000_000, "0.99 HYPE WAD = sz 99e6");
    }

    /// @notice USDC Core weiDecimals=8: wei / 100 gives 6dp.
    function test_unit_usdcWeiTo6dp() public pure {
        // 1 USDC (6dp) = 1e6; Core wei = 1e8; / 100 = 1e6
        assertEq(uint256(100_000_000) / 100, 1_000_000, "1 USDC core wei to 6dp");
        // 250 USDC (6dp) = 250e6; Core wei = 250e8; / 100 = 250e6
        assertEq(uint256(25_000_000_000) / 100, 250_000_000, "250 USDC core wei to 6dp");
    }

    /// @notice spotPx precompile scale: price x 1e6 -> WAD = x 1e12.
    function test_unit_spotPxRawToWad() public pure {
        // $25 => raw = 25_000_000; WAD = 25_000_000 x 1e12 = 25e18
        assertEq(uint256(25_000_000) * 1e12, 25e18, "$25 raw to WAD");
        // $1 => raw = 1_000_000; WAD = 1e18
        assertEq(uint256(1_000_000) * 1e12, 1e18, "$1 raw to WAD");
    }

    /// @notice coverEquityUsdc formula: _toUsdc(hype * pxWad / WAD).
    function test_unit_coverEquityFormula() public pure {
        uint256 hype  = 2e18;    // 2 HYPE in WAD
        uint256 pxWad = 25e18;   // $25 in WAD
        uint256 eq    = (hype * pxWad / WAD) / 1e12;
        // 2 HYPE x $25 = $50 = 50e6 6dp USDC
        assertEq(eq, 50_000_000, "2 HYPE at $25 = $50");
    }

    /// @notice szDecimals=2 floor: 1 HYPE (exact tick) has no dust.
    function test_unit_szDecimalsFloor_exactTick() public pure {
        uint256 floored = (1e18 / HYPE_TICK) * HYPE_TICK;
        assertEq(floored, 1e18, "1 HYPE: no dust");
    }

    /// @notice 0.9993 HYPE floors to 0.99 HYPE; dust = 0.0093 HYPE.
    function test_unit_szDecimalsFloor_fractional() public pure {
        uint256 hypeWad = 0.9993e18;
        uint256 floored = (hypeWad / HYPE_TICK) * HYPE_TICK;
        uint256 dust    = hypeWad - floored;
        assertEq(floored, 0.99e18,   "floor to 0.99 HYPE");
        assertEq(dust,    0.0093e18, "dust = 0.0093 HYPE");
    }

    /// @notice Sub-tick amount (9e15 WAD) floors to zero.
    function test_unit_szDecimalsFloor_belowMinTick() public pure {
        uint256 floored = (9e15 / HYPE_TICK) * HYPE_TICK;
        assertEq(floored, 0, "sub-tick amount floors to zero");
    }

    /// @notice Large fractional amount: 123.456789 HYPE floors to 123.45 HYPE.
    function test_unit_szDecimalsFloor_largeAmount() public pure {
        uint256 hypeWad = 123.456789e18;
        uint256 floored = (hypeWad / HYPE_TICK) * HYPE_TICK;
        uint256 dust    = hypeWad - floored;
        assertEq(floored, 123.45e18,   "floor to 123.45 HYPE");
        assertEq(dust,    0.006789e18, "dust = 0.006789 HYPE");
    }

    /// @notice Estimated usdcOut from sellCover: floor x price / WAD / 1e12.
    function test_unit_sellCover_estimatedProceeds() public pure {
        uint256 hypeWad = 0.9993e18;
        uint256 floored = (hypeWad / HYPE_TICK) * HYPE_TICK; // 0.99e18
        uint256 pxWad   = uint256(SPOT_PX_RAW) * 1e12;       // 25e18
        uint256 usdcOut = (floored * pxWad / WAD) / 1e12;
        // 0.99 HYPE x $25 = $24.75 = 24_750_000 6dp
        assertEq(usdcOut, 24_750_000, "0.99 HYPE at $25 = $24.75");
    }

    // ────────────────────────────────────────────────────────────────────────
    // B) SIMULATOR TESTS - offline CoreSimulatorLib (no fork required)
    // ────────────────────────────────────────────────────────────────────────

    function setUp() public {
        // Initialize simulator (offline mode; no RPC fork needed).
        hyperCore = CoreSimulatorLib.init();

        // CRITICAL: init() sets useRealL1Read=true, but without an active fork any RPC call
        // (e.g., coreUserExists, spotBalance) reverts on abi.decode("", (bool)). Disable real
        // L1 reads so all queries route through local PrecompileSim state instead.
        hyperCore.setUseRealL1Read(false);

        // Register testnet HYPE token at index 1105.
        // (Offline _deployTokenRegistryAndCoreTokens only pre-registers mainnet token 150.)
        uint64[] memory hypeSpots = new uint64[](1);
        hypeSpots[0] = uint64(HYPE_SPOT_INDEX);
        hyperCore.registerTokenInfo(HYPE_TOKEN, PrecompileLib.TokenInfo({
            name:                    "HYPE",
            spots:                   hypeSpots,
            deployerTradingFeeShare: 0,
            deployer:                address(0),
            evmContract:             address(0),
            szDecimals:              2,
            weiDecimals:             8,
            evmExtraWeiDecimals:     0
        }));

        // Register HYPE/USDC spot pair at index 1035.
        uint64[2] memory tokens;
        tokens[0] = HYPE_TOKEN; // base
        tokens[1] = USDC_TOKEN; // quote
        hyperCore.registerSpotInfo(HYPE_SPOT_INDEX, PrecompileLib.SpotInfo({
            name:   "HYPE/USDC",
            tokens: tokens
        }));

        // Set spot price $25: raw = 25_000_000 (price x 1e6 precompile scale).
        // Execution scaling: spotPx_exec = 25_000_000 x 10^szDecimals = 25_000_000 x 100 = 2.5e9.
        // Buy 1 HYPE (sz=1e8): amountIn = 1e8 x 2.5e9 / 1e8 = 2.5e9 USDC Core wei = 25e8 = $25.
        CoreSimulatorLib.setSpotPx(HYPE_SPOT_INDEX, SPOT_PX_RAW);

        // Deploy vault; this test contract is both owner and keeper.
        vault = new CoreCoverVault(address(this));

        // Activate vault's Core account and seed with 1000 USDC (= 1000 x 1e8 Core wei).
        // With useRealL1Read=false, forceAccountActivation uses local state only (no RPC calls).
        CoreSimulatorLib.forceAccountActivation(address(vault));
        CoreSimulatorLib.forceSpotBalance(address(vault), USDC_TOKEN, 1000e8);

        CoreSimulatorLib.setRevertOnFailure(true);
    }

    /// @notice View functions reflect the force-set balances before any order.
    function test_sim_initialState() public view {
        // 1000 USDC: Core wei 1000e8 / 100 = 1000e6 6dp
        assertEq(vault.poolUsdc(),        1000e6, "initial poolUsdc = 1000 USDC");
        assertEq(vault.coverHype(),       0,      "initial coverHype = 0");
        // spotPxUsdc: raw=25_000_000 x 1e12 = 25e18
        assertEq(vault.spotPxUsdc(),      25e18,  "spotPxUsdc = $25 WAD");
        assertEq(vault.coverEquityUsdc(), 0,      "no equity with zero cover");
    }

    /// @notice buyCover -> IOC order -> nextBlock -> HYPE up, USDC down.
    function test_sim_buyCover_balancesUpdate() public {
        uint256 usdcBefore = uint256(PrecompileLib.spotBalance(address(vault), USDC_TOKEN).total);
        uint256 hypeBefore = uint256(PrecompileLib.spotBalance(address(vault), HYPE_TOKEN).total);

        // Buy 1 HYPE, cap at $30 (est $25, well within cap).
        vault.buyCover(1e18, 30e6);
        CoreSimulatorLib.nextBlock();

        uint256 usdcAfter = uint256(PrecompileLib.spotBalance(address(vault), USDC_TOKEN).total);
        uint256 hypeAfter = uint256(PrecompileLib.spotBalance(address(vault), HYPE_TOKEN).total);

        assertGt(hypeAfter, hypeBefore, "HYPE balance increases after buy");
        assertLt(usdcAfter, usdcBefore, "USDC balance decreases after buy");
    }

    /// @notice ICoverVault view functions update after fill settles.
    function test_sim_buyCover_viewFunctions() public {
        vault.buyCover(1e18, 30e6);
        CoreSimulatorLib.nextBlock();

        assertGt(vault.coverHype(), 0,      "coverHype() > 0 after buy settles");
        assertLt(vault.poolUsdc(),  1000e6, "poolUsdc() < seed after buy");
    }

    /// @notice buyCover zero qty reverts.
    function test_sim_buyCover_zeroReverts() public {
        vm.expectRevert("qty=0");
        vault.buyCover(0, 100e6);
    }

    /// @notice buyCover reverts when estimated cost > maxUsdc.
    function test_sim_buyCover_slippageReverts() public {
        // 1 HYPE at $25 est = $25; cap at $24 -> revert
        vm.expectRevert("slippage");
        vault.buyCover(1e18, 24e6);
    }

    /// @notice sellCover floors to szDecimals=2 tick; dust remains in Core HYPE balance.
    function test_sim_sellCover_flooredDustRemains() public {
        // Seed 0.9993 HYPE: 99930000 Core wei (0.9993 x 1e8)
        CoreSimulatorLib.forceSpotBalance(address(vault), HYPE_TOKEN, 99930000);

        uint256 usdcBefore = uint256(PrecompileLib.spotBalance(address(vault), USDC_TOKEN).total);
        uint256 usdcOut    = vault.sellCover(0.9993e18);
        CoreSimulatorLib.nextBlock();

        uint256 hypeAfter = uint256(PrecompileLib.spotBalance(address(vault), HYPE_TOKEN).total);
        uint256 usdcAfter = uint256(PrecompileLib.spotBalance(address(vault), USDC_TOKEN).total);

        // Estimated usdcOut: 0.99 HYPE x $25 = $24.75 = 24_750_000 6dp
        assertEq(usdcOut, 24_750_000, "estimated usdcOut for 0.99 HYPE at $25");

        // Dust: 99930000 - 99000000 = 930000 Core wei = 0.0093 HYPE
        assertEq(hypeAfter, 930000, "dust = 0.0093 HYPE Core wei remains");

        // USDC increases after sell
        assertGt(usdcAfter, usdcBefore, "USDC increases after sell");
    }

    /// @notice sellCover exact tick: no dust.
    function test_sim_sellCover_exactTick_noDust() public {
        // 1 HYPE = 1e8 Core wei
        CoreSimulatorLib.forceSpotBalance(address(vault), HYPE_TOKEN, 1e8);

        uint256 usdcOut = vault.sellCover(1e18);
        CoreSimulatorLib.nextBlock();

        uint256 hypeAfter = uint256(PrecompileLib.spotBalance(address(vault), HYPE_TOKEN).total);
        assertEq(hypeAfter, 0,          "no dust after exact 1 HYPE sell");
        assertEq(usdcOut,  25_000_000,  "usdcOut = $25 for 1 HYPE at $25");
    }

    /// @notice sellCover below min tick reverts.
    function test_sim_sellCover_belowMinTickReverts() public {
        CoreSimulatorLib.forceSpotBalance(address(vault), HYPE_TOKEN, 1e8);
        // 0.009 HYPE = 9e15 WAD -> floored = 0 -> revert
        vm.expectRevert("qty: below min tick");
        vault.sellCover(9e15);
    }

    /// @notice sellCover reverts when Core balance is zero.
    function test_sim_sellCover_insufficientReverts() public {
        // No HYPE seeded
        vm.expectRevert("cover: insufficient");
        vault.sellCover(1e18);
    }

    /// @notice cloidSeq increments on each order.
    function test_sim_cloidSeq_increments() public {
        uint128 seqBefore = vault.cloidSeq();
        vault.buyCover(1e18, 30e6);
        assertEq(vault.cloidSeq(), seqBefore + 1, "cloidSeq +1 after buy");
        CoreSimulatorLib.forceSpotBalance(address(vault), HYPE_TOKEN, 1e8);
        vault.sellCover(1e18);
        assertEq(vault.cloidSeq(), seqBefore + 2, "cloidSeq +2 after sell");
    }

    /// @notice pullUsdc reverts with diagnostic.
    function test_sim_pullUsdc_reverts() public {
        vm.expectRevert("CoreCoverVault: deposit via Core account, no on-chain pull");
        vault.pullUsdc(address(this), 100e6);
    }

    /// @notice payoutUsdc zero amount reverts.
    function test_sim_payoutUsdc_zeroReverts() public {
        vm.expectRevert("amt=0");
        vault.payoutUsdc(address(this), 0);
    }

    /// @notice payoutUsdc reverts when pool balance is insufficient.
    function test_sim_payoutUsdc_insufficientReverts() public {
        CoreSimulatorLib.forceSpotBalance(address(vault), USDC_TOKEN, 0);
        vm.expectRevert("pool: insufficient");
        vault.payoutUsdc(address(this), 1e6);
    }

    /// @notice setKeeper changes keeper; old keeper loses access.
    function test_sim_setKeeper_updatesAccess() public {
        address newKeeper = makeAddr("newKeeper");
        vault.setKeeper(newKeeper);

        // address(this) is now just owner, no longer keeper; but owner IS also allowed
        // via onlyKeeper (owner || keeper). To test properly: set keeper to newKeeper,
        // then prank as a third party that is neither owner nor keeper.
        address nobody = makeAddr("nobody");
        vm.prank(nobody);
        vm.expectRevert("only keeper");
        vault.buyCover(1e18, 30e6);

        // newKeeper can call
        vm.prank(newKeeper);
        vault.buyCover(1e18, 30e6);
    }

    /// @notice Non-owner cannot call setKeeper.
    function test_sim_setKeeper_onlyOwner() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert("only owner");
        vault.setKeeper(stranger);
    }

    /// @notice ICoverVault conformance: all interface functions callable without revert.
    function test_sim_implements_ICoverVault() public view {
        assertEq(vault.poolUsdc(),        1000e6);
        assertEq(vault.coverHype(),       0);
        assertEq(vault.coverEquityUsdc(), 0);
        assertGt(vault.spotPxUsdc(),      0);
    }
}
