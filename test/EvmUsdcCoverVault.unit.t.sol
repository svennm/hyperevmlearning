// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {EvmUsdcCoverVault} from "../src/EvmUsdcCoverVault.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {ICoverVault} from "../src/interfaces/ICoverVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";
import {CoreSimulatorLib} from "@hyper-evm-lib/test/simulation/CoreSimulatorLib.sol";
import {HyperCore} from "@hyper-evm-lib/test/simulation/HyperCore.sol";

/// @notice Unit tests for EvmUsdcCoverVault — the USDC-custody FIX side.
///         USDC lives as a standard EVM ERC20 (MockUSDC, 6dp), so:
///           • pullUsdc = transferFrom (THE FIX — deposits work, unlike CoreCoverVault's revert)
///           • payoutUsdc = transfer (keeper-gated)
///           • the EVM term of the two-layer poolUsdc()
///         The CoreSimulator is initialised purely so the HyperCore precompiles are etched (the
///         Core-USDC float term of poolUsdc reads spotBalance); the Core float is left at 0 here so
///         poolUsdc() reflects ONLY the EVM ERC20 balance. Core-float behaviour is in the .sim file.
contract EvmUsdcCoverVaultUnitTest is Test {
    uint32 constant HYPE_SPOT_INDEX = 1035;
    uint64 constant HYPE_TOKEN      = 1105;
    uint64 constant USDC_TOKEN      = 0;
    uint64 constant SPOT_PX_RAW     = 25_000_000; // $25

    MockUSDC          usdc;
    EvmUsdcCoverVault vault;
    HyperCore         hyperCore;

    address constant KEEPER  = address(0xBEEF);
    address constant TRADER  = address(0x7AD3);
    address constant STRANGE = address(0x57A);

    function setUp() public {
        // Etch HyperCore precompiles (offline) so the vault's precompile reads resolve.
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

        usdc  = new MockUSDC();
        vault = new EvmUsdcCoverVault(IERC20(address(usdc)), KEEPER); // owner = this
        vault.initBook(address(this)); // this test contract is the book (the sole fund-exit authority)

        // Activate the vault Core account; leave the Core-USDC float at 0.
        CoreSimulatorLib.forceAccountActivation(address(vault));
        CoreSimulatorLib.setRevertOnFailure(true);
    }

    // ── pullUsdc = transferFrom — THE FIX ─────────────────────────────────────

    /// @notice THE FIX: pullUsdc pulls USDC via ERC20 transferFrom (CoreCoverVault reverts here).
    function test_pullUsdc_transferFromWorks() public {
        usdc.mint(TRADER, 1_000e6);
        vm.prank(TRADER);
        usdc.approve(address(vault), 1_000e6);

        vault.pullUsdc(TRADER, 1_000e6);

        assertEq(usdc.balanceOf(TRADER), 0,               "trader USDC pulled");
        assertEq(usdc.balanceOf(address(vault)), 1_000e6, "vault holds pulled USDC");
    }

    /// @notice pullUsdc reverts without an approval (unlike the mock, this is a real ERC20 move).
    function test_pullUsdc_noApprovalReverts() public {
        usdc.mint(TRADER, 1_000e6);
        vm.expectRevert(); // ERC20InsufficientAllowance
        vault.pullUsdc(TRADER, 1_000e6);
    }

    /// @notice pullUsdc reverts when the source lacks balance.
    function test_pullUsdc_noBalanceReverts() public {
        vm.prank(TRADER);
        usdc.approve(address(vault), 1_000e6);
        vm.expectRevert(); // ERC20InsufficientBalance
        vault.pullUsdc(TRADER, 1_000e6);
    }

    // ── payoutUsdc = transfer (keeper-gated) ──────────────────────────────────

    function test_payoutUsdc_transfersOut() public {
        usdc.mint(address(vault), 500e6);
        vault.payoutUsdc(TRADER, 300e6); // book (this) may call
        assertEq(usdc.balanceOf(TRADER), 300e6,          "recipient paid");
        assertEq(usdc.balanceOf(address(vault)), 200e6,  "vault balance reduced");
    }

    function test_payoutUsdc_nonBookReverts() public {
        usdc.mint(address(vault), 500e6);
        vm.prank(STRANGE);
        vm.expectRevert("only book");
        vault.payoutUsdc(TRADER, 100e6);
    }

    /// @notice C1 RUG REGRESSION: the KEEPER (the old fund authority) can NO LONGER extract USDC.
    ///         Only the wired book can move funds out — no EOA can send pooled USDC to an arbitrary
    ///         recipient. This is the whole point of the trustless-custody change.
    function test_payoutUsdc_keeperCannotExtract() public {
        usdc.mint(address(vault), 500e6);
        vm.prank(KEEPER);
        vm.expectRevert("only book");
        vault.payoutUsdc(KEEPER, 100e6);
    }

    function test_payoutUsdc_insufficientReverts() public {
        usdc.mint(address(vault), 50e6);
        vm.expectRevert(); // ERC20InsufficientBalance
        vault.payoutUsdc(TRADER, 100e6);
    }

    // ── poolUsdc: EVM term (Core float = 0 here) ──────────────────────────────

    function test_poolUsdc_reflectsEvmBalance() public {
        assertEq(vault.poolUsdc(), 0, "empty vault: poolUsdc = 0");
        usdc.mint(address(vault), 750e6);
        assertEq(vault.poolUsdc(), 750e6, "poolUsdc = EVM balance (Core float 0)");
    }

    function test_poolUsdc_increasesAfterPull() public {
        usdc.mint(TRADER, 400e6);
        vm.prank(TRADER);
        usdc.approve(address(vault), 400e6);
        vault.pullUsdc(TRADER, 400e6);
        assertEq(vault.poolUsdc(), 400e6, "poolUsdc rose by pulled amount");
    }

    // ── Fresh-vault reads (HYPE cover side, Core-native) ──────────────────────

    function test_coverHype_zeroFresh() public view {
        assertEq(vault.coverHype(), 0, "fresh vault: no cover");
    }

    function test_spotPxUsdc_reads() public view {
        // raw 25_000_000 × 1e12 = 25e18 WAD
        assertEq(vault.spotPxUsdc(), 25e18, "spotPxUsdc = $25 WAD");
    }

    function test_coverEquityUsdc_zeroFresh() public view {
        assertEq(vault.coverEquityUsdc(), 0, "no equity without cover");
    }

    // ── Admin / gating ────────────────────────────────────────────────────────

    function test_setKeeper_onlyOwner() public {
        vm.prank(STRANGE);
        vm.expectRevert("only owner");
        vault.setKeeper(STRANGE);
    }

    function test_setKeeper_updatesKeeper() public {
        vault.setKeeper(STRANGE);
        assertEq(vault.keeper(), STRANGE, "keeper updated");
    }

    // Griefing guard: a non-book caller must NOT be able to pull an approved trader's USDC into the
    // pool uncredited. ONLY the book pulls, atomic with crediting traderCollateral — not even the keeper.
    function test_pullUsdc_onlyBook_blocksGriefing() public {
        usdc.mint(TRADER, 1_000e6);
        vm.prank(TRADER);
        usdc.approve(address(vault), 1_000e6);

        vm.prank(STRANGE);
        vm.expectRevert(bytes("only book"));
        vault.pullUsdc(TRADER, 1_000e6);
        vm.prank(KEEPER);
        vm.expectRevert(bytes("only book"));
        vault.pullUsdc(TRADER, 1_000e6);

        // Only the book (this test contract, wired via initBook) can pull.
        vault.pullUsdc(TRADER, 1_000e6);
        assertEq(usdc.balanceOf(address(vault)), 1_000e6, "book pull works");
    }

    // ── initBook: one-time, owner-only, non-zero ──────────────────────────────
    function test_initBook_onceOnly() public {
        vm.expectRevert("book set"); // already set to this in setUp
        vault.initBook(address(0xB00C));
    }

    function test_initBook_onlyOwner() public {
        MockUSDC u2 = new MockUSDC();
        EvmUsdcCoverVault v2 = new EvmUsdcCoverVault(IERC20(address(u2)), KEEPER);
        vm.prank(STRANGE);
        vm.expectRevert("only owner");
        v2.initBook(address(0xB00C));
    }

    function test_book_wired() public view {
        assertEq(vault.book(), address(this), "book = wired fund authority");
    }

    function test_ownerAndKeeper_wired() public view {
        assertEq(vault.owner(),  address(this), "owner = deployer");
        assertEq(vault.keeper(), KEEPER,         "keeper = ctor arg");
        assertEq(address(vault.usdc()), address(usdc), "usdc wired");
    }

    // ── ICoverVault conformance ───────────────────────────────────────────────

    function test_implements_ICoverVault() public {
        ICoverVault v = ICoverVault(address(vault));
        usdc.mint(address(vault), 123e6);
        assertEq(v.poolUsdc(),        123e6);
        assertEq(v.coverHype(),       0);
        assertEq(v.coverEquityUsdc(), 0);
        assertEq(v.spotPxUsdc(),      25e18);
    }

    // ── buyCover: live BBO-driven pricing (Task 1 — trust-min) ───────────────

    address constant BBO_ADDR = 0x000000000000000000000000000000000000080e;

    function _mockBbo(uint64 bid, uint64 ask) internal {
        vm.mockCall(BBO_ADDR, abi.encode(uint64(11035)),
            abi.encode(PrecompileLib.Bbo({bid: bid, ask: ask})));
    }

    function test_buyCover_crossesLiveAsk_dislocatedBook() public {
        // bid $33, ask $62.989 (the real testnet dislocation)
        _mockBbo(33_000_000, 62_989_000);
        CoreSimulatorLib.forceSpotBalance(address(vault), USDC_TOKEN, 1000e8); // fund Core float
        vm.prank(KEEPER);
        vault.buyCover(0.2e18, 14e6); // 0.2 HYPE, cap $14 (0.2 * ~$63.3 limit ≈ $12.7)
        CoreSimulatorLib.nextBlock();
        assertGt(vault.coverHype(), 0, "cover acquired crossing the ask");
    }

    function test_buyCover_costGuardPricedAtLimit_notStaleBid() public {
        // H4: stale-bid estimate ($33*0.2=$6.6) would pass a $7 cap, but the ask-priced
        // worst case ($63*0.2≈$12.7) must exceed it and revert.
        _mockBbo(33_000_000, 62_989_000);
        CoreSimulatorLib.forceSpotBalance(address(vault), USDC_TOKEN, 1000e8);
        vm.prank(KEEPER);
        vm.expectRevert(bytes("cost>max"));
        vault.buyCover(0.2e18, 7e6);
    }

    function test_buyCover_revertsOnZeroAsk() public {
        _mockBbo(33_000_000, 0);
        vm.prank(KEEPER);
        vm.expectRevert(bytes("no ask"));
        vault.buyCover(0.2e18, 100e6);
    }
}
