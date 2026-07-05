// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {EvmUsdcCoverVault} from "../src/EvmUsdcCoverVault.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";
import {CoreSimulatorLib} from "@hyper-evm-lib/test/simulation/CoreSimulatorLib.sol";
import {HyperCore} from "@hyper-evm-lib/test/simulation/HyperCore.sol";

/// @notice CoreSimulatorLib sim tests for EvmUsdcCoverVault — the Core-native side + two-layer pool.
///
/// Modelled on test/CoreCoverVault.sim.t.sol. The HYPE cover logic (buyCover/sellCover/coverHype/
/// spotPx/coverEquity) is byte-for-byte CoreCoverVault, so these tests mirror it. What is NEW here:
///   • poolUsdc() is TWO-LAYER: EVM ERC20 balance + Core-USDC float. Tested with both non-zero.
///   • buyCover consumes the Core float (EVM balance untouched); sellCover credits the Core float.
///   • bridge ops (bridgeUsdcToCore/bridgeUsdcToEvm) — access-control tested here; the happy path
///     moves the canonical HLConstants.usdc() via the async CoreDepositWallet path and is a
///     fork/live concern (CoreSimulatorLib does not simulate the deposit-wallet bridge).
///
/// The spot maker fee is zeroed so Core-float arithmetic is exact.
contract EvmUsdcCoverVaultSimTest is Test {
    uint32 constant HYPE_SPOT_INDEX = 1035;
    uint64 constant HYPE_TOKEN      = 1105;
    uint64 constant USDC_TOKEN      = 0;
    uint256 constant WAD            = 1e18;

    uint64 constant SPOT_PX_RAW = 25_000_000; // $25 → spotPxUsdc = 25e18

    MockUSDC          usdc;
    EvmUsdcCoverVault vault;
    HyperCore         hyperCore;

    address constant STRANGE = address(0x57A);

    function setUp() public {
        hyperCore = CoreSimulatorLib.init();
        hyperCore.setUseRealL1Read(false);

        uint64[] memory hypeSpots = new uint64[](1);
        hypeSpots[0] = uint64(HYPE_SPOT_INDEX);
        hyperCore.registerTokenInfo(HYPE_TOKEN, PrecompileLib.TokenInfo({
            name: "HYPE", spots: hypeSpots, deployerTradingFeeShare: 0, deployer: address(0),
            evmContract: address(0), szDecimals: 2, weiDecimals: 8, evmExtraWeiDecimals: 0
        }));
        uint64[2] memory tokens; tokens[0] = HYPE_TOKEN; tokens[1] = USDC_TOKEN;
        hyperCore.registerSpotInfo(HYPE_SPOT_INDEX, PrecompileLib.SpotInfo({name: "HYPE/USDC", tokens: tokens}));
        CoreSimulatorLib.setSpotPx(HYPE_SPOT_INDEX, SPOT_PX_RAW);
        CoreSimulatorLib.setSpotMakerFee(0); // exact Core-float arithmetic

        usdc  = new MockUSDC();
        vault = new EvmUsdcCoverVault(IERC20(address(usdc)), address(this)); // owner+keeper = this

        // Activate Core account and seed a 1000-USDC Core float (pre-bridged, pre-cover).
        CoreSimulatorLib.forceAccountActivation(address(vault));
        CoreSimulatorLib.forceSpotBalance(address(vault), USDC_TOKEN, 1000e8); // 1000 USDC (8dp wei)
        CoreSimulatorLib.setRevertOnFailure(true);
    }

    // ── Two-layer poolUsdc ────────────────────────────────────────────────────

    /// @notice poolUsdc = EVM ERC20 balance + Core-USDC float.
    function test_sim_poolUsdc_twoLayer() public {
        // Core float alone = 1000 USDC
        assertEq(vault.poolUsdc(), 1000e6, "core float only");
        // Add 500 USDC on the EVM layer
        usdc.mint(address(vault), 500e6);
        assertEq(vault.poolUsdc(), 1500e6, "EVM(500) + Core(1000) = 1500");
    }

    // ── buyCover consumes the Core float; EVM untouched ───────────────────────

    function test_sim_buyCover_consumesCoreFloat() public {
        usdc.mint(address(vault), 500e6); // EVM buffer that must NOT move on a cover buy
        uint256 poolBefore = vault.poolUsdc(); // 1500e6

        vault.buyCover(1e18, 30e6); // 1 HYPE, est $25
        CoreSimulatorLib.nextBlock();

        assertEq(vault.coverHype(), 1e18, "cover = 1 HYPE after fill");
        assertEq(usdc.balanceOf(address(vault)), 500e6, "EVM balance untouched by cover buy");
        // Core float dropped ~$25; poolUsdc drops by the same.
        assertEq(vault.poolUsdc(), poolBefore - 25e6, "poolUsdc -= cover cost from Core float");
    }

    function test_sim_buyCover_zeroReverts() public {
        vm.expectRevert("qty=0");
        vault.buyCover(0, 100e6);
    }

    function test_sim_buyCover_slippageReverts() public {
        vm.expectRevert("slippage");
        vault.buyCover(1e18, 24e6); // est $25 > cap $24
    }

    function test_sim_buyCover_onlyKeeper() public {
        vm.prank(STRANGE);
        vm.expectRevert("only keeper");
        vault.buyCover(1e18, 30e6);
    }

    // ── sellCover credits the Core float; szDecimals=2 floor leaves dust ──────

    function test_sim_sellCover_creditsCoreFloat_flooredDust() public {
        // Seed 0.9993 HYPE cover
        CoreSimulatorLib.forceSpotBalance(address(vault), HYPE_TOKEN, 99930000); // 0.9993 HYPE wei
        uint256 poolBefore = vault.poolUsdc(); // 1000e6 (Core float)

        uint256 usdcOut = vault.sellCover(0.9993e18);
        CoreSimulatorLib.nextBlock();

        // Estimated proceeds: 0.99 HYPE × $25 = $24.75
        assertEq(usdcOut, 24_750_000, "estimated usdcOut for floored 0.99 HYPE");
        // Dust remains: 0.0093 HYPE = 930000 wei
        assertEq(uint256(PrecompileLib.spotBalance(address(vault), HYPE_TOKEN).total), 930000, "dust remains");
        // Core float (hence poolUsdc) rose by the proceeds
        assertEq(vault.poolUsdc(), poolBefore + 24_750_000, "poolUsdc += sale proceeds (Core float)");
    }

    function test_sim_sellCover_belowMinTickReverts() public {
        CoreSimulatorLib.forceSpotBalance(address(vault), HYPE_TOKEN, 1e8);
        vm.expectRevert("qty: below min tick");
        vault.sellCover(9e15); // < 1 tick
    }

    function test_sim_sellCover_insufficientReverts() public {
        vm.expectRevert("cover: insufficient");
        vault.sellCover(1e18); // no HYPE seeded
    }

    function test_sim_sellCover_onlyKeeper() public {
        CoreSimulatorLib.forceSpotBalance(address(vault), HYPE_TOKEN, 1e8);
        vm.prank(STRANGE);
        vm.expectRevert("only keeper");
        vault.sellCover(1e18);
    }

    // ── coverEquity + cloidSeq ────────────────────────────────────────────────

    function test_sim_coverEquity_afterBuy() public {
        vault.buyCover(2e18, 60e6);
        CoreSimulatorLib.nextBlock();
        // 2 HYPE × $25 = $50
        assertEq(vault.coverEquityUsdc(), 50e6, "coverEquity = 2 HYPE @ $25");
    }

    function test_sim_cloidSeq_increments() public {
        uint128 s0 = vault.cloidSeq();
        vault.buyCover(1e18, 30e6);
        assertEq(vault.cloidSeq(), s0 + 1, "cloid +1 on buy");
        CoreSimulatorLib.forceSpotBalance(address(vault), HYPE_TOKEN, 1e8);
        vault.sellCover(1e18);
        assertEq(vault.cloidSeq(), s0 + 2, "cloid +2 on sell");
    }

    // ── Bridge ops: access control (happy path is fork/live) ─────────────────

    function test_sim_bridgeToCore_onlyKeeper() public {
        vm.prank(STRANGE);
        vm.expectRevert("only keeper");
        vault.bridgeUsdcToCore(100e6);
    }

    function test_sim_bridgeToEvm_onlyKeeper() public {
        vm.prank(STRANGE);
        vm.expectRevert("only keeper");
        vault.bridgeUsdcToEvm(100e6);
    }

    // ── payoutUsdc pays from the EVM layer (not the Core float) ───────────────

    /// @notice A payout draws EVM USDC even when a Core float exists — the honest two-layer boundary:
    ///         the keeper must bridge Core proceeds → EVM before they can be paid out.
    function test_sim_payoutUsdc_drawsEvmLayer() public {
        usdc.mint(address(vault), 200e6); // EVM layer
        // Core float is 1000e6 but payout can only touch the EVM 200e6.
        vault.payoutUsdc(STRANGE, 150e6);
        assertEq(usdc.balanceOf(STRANGE), 150e6, "paid from EVM layer");
        assertEq(usdc.balanceOf(address(vault)), 50e6, "EVM layer reduced");
        // Core float untouched; poolUsdc = EVM(50) + Core(1000)
        assertEq(vault.poolUsdc(), 1050e6, "poolUsdc = remaining EVM + Core float");
    }

    /// @notice payoutUsdc reverts if the EVM layer is short, even though the Core float would cover it
    ///         (proves payout does NOT silently source the Core float — bridge first).
    function test_sim_payoutUsdc_shortEvmReverts_despiteCoreFloat() public {
        // No EVM balance; 1000-USDC Core float present.
        vm.expectRevert(); // ERC20InsufficientBalance
        vault.payoutUsdc(STRANGE, 10e6);
    }
}
