// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {EverlastingBook} from "../src/EverlastingBook.sol";
import {EvmUsdcCoverVault} from "../src/EvmUsdcCoverVault.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockOracle} from "../src/MockOracle.sol";
import {MockVol} from "../src/mocks/MockVol.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";
import {CoreSimulatorLib} from "@hyper-evm-lib/test/simulation/CoreSimulatorLib.sol";
import {HyperCore} from "@hyper-evm-lib/test/simulation/HyperCore.sol";

/// @title Book × EvmUsdcCoverVault — deposit-fix integration proof
/// @notice The proof that the USDC-custody fix UNBLOCKS the live lifecycle that CoreCoverVault broke.
///
///   With CoreCoverVault, `book.deposit` reverted at `vault.pullUsdc` (HyperCore has no on-chain
///   transferFrom), so no trader collateral could ever enter the book live. This test wires a FRESH
///   EverlastingBook to an EvmUsdcCoverVault (+ MockUSDC) and drives the FULL lifecycle end-to-end:
///
///     trader usdc.approve(vault) → book.deposit(COVERED_CALL)   ← transferFrom SUCCEEDS (THE FIX)
///        → keeper seeds cover (buyCover on Core)                ← Core-native, unchanged
///        → book.openLong (cover gate passes)
///        → keeper postMark up (winning)
///        → book.close (winning: sells cover, pays g)
///        → book.withdraw                                        ← physical USDC transfer out (EVM)
///
///   Conservation `poolUsdc == poolFree + putEscrow + totalCollateral` is asserted throughout.
///
/// @dev Wiring: the BOOK is the vault's KEEPER (so its sellCover/payoutUsdc calls are authorized);
///      the test contract is the vault OWNER (seeds cover) and the book's mark keeper.
/// @dev Two-layer boundary (honest): trader winnings' backing lands on the Core float (async, after
///      sellCover settles); the withdrawal is served from the vault's EVM withdrawal buffer. In
///      production the keeper `bridgeUsdcToEvm`s Core proceeds to top the buffer up. Maker fee zeroed
///      so the arithmetic is exact.
contract BookEvmVaultIntegrationTest is Test {
    uint32 constant HYPE_SPOT_INDEX = 1035;
    uint64 constant HYPE_TOKEN      = 1105;
    uint64 constant USDC_TOKEN      = 0;

    uint64  constant SPOT_PX_RAW = 100_000_000; // $100/HYPE → spotPxUsdc = 100e18
    uint256 constant KPUT   = 100e18;
    uint256 constant WPUT   =  50e18;
    uint256 constant KCALL  = 120e18;            // spot $100 < strike → call intrinsic 0

    EverlastingBook.Side constant CALL = EverlastingBook.Side.COVERED_CALL;
    uint8 constant CALL_U = 1;

    MockUSDC          usdc;
    MockOracle        oracle;
    MockVol           mockVol;
    EvmUsdcCoverVault vault;
    EverlastingBook   book;
    HyperCore         hyperCore;

    address ALICE = makeAddr("alice");
    address constant BBO_ADDR = 0x000000000000000000000000000000000000080e;

    function _mockBbo(uint64 bid, uint64 ask) internal {
        vm.mockCall(BBO_ADDR, abi.encode(uint64(11035)),
            abi.encode(PrecompileLib.Bbo({bid: bid, ask: ask})));
    }

    function setUp() public {
        // ── HyperCore sim (offline) ──────────────────────────────────────────
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
        CoreSimulatorLib.setSpotMakerFee(0);

        // ── Deploy + wire ────────────────────────────────────────────────────
        usdc   = new MockUSDC();
        oracle = new MockOracle();
        oracle.set(100e18); // spot $100

        mockVol = new MockVol();
        vault = new EvmUsdcCoverVault(IERC20(address(usdc)), address(this)); // owner+keeper = this
        book  = new EverlastingBook(
            vault, oracle, address(this), // book mark-keeper = this
            KPUT, WPUT, KCALL,
            10_000e18, 10_000e18,
            mockVol
        );
        // Book is the vault's sole fund-exit authority (pullUsdc/payoutUsdc onlyBook, sellCover
        // book-or-keeper). Keeper stays = this (owner) for cover-buy / bridge ops.
        vault.initBook(address(book));

        // ── Seed Core-USDC float (LP capital pre-bridged) + keeper buys cover ─
        CoreSimulatorLib.forceAccountActivation(address(vault));
        CoreSimulatorLib.forceSpotBalance(address(vault), USDC_TOKEN, 20_000e8); // 20,000 USDC on Core
        CoreSimulatorLib.setRevertOnFailure(true);

        // Owner (this) buys 100 HYPE cover from the Core float; settle the fill.
        _mockBbo(SPOT_PX_RAW, SPOT_PX_RAW); // bid=ask=$100 — matches spotPx used by simulator
        vault.buyCover(100e18, 15_000e6);  // worstCost at limit ~$100.50×100=$10050 < $15000
        CoreSimulatorLib.nextBlock();
        assertEq(vault.coverHype(), 100e18, "cover seeded: 100 HYPE");

        // ── LP EVM withdrawal buffer (the pool's own USDC on the EVM layer) ───
        usdc.mint(address(this), 5_000e6);
        usdc.approve(address(vault), 5_000e6);
        book.lpDeposit(5_000e6); // vault.pullUsdc(this, 5000) via transferFrom
        assertEq(usdc.balanceOf(address(vault)), 5_000e6, "EVM buffer funded");
    }

    function _assertConservation(string memory tag) internal view {
        assertEq(
            vault.poolUsdc(),
            book.poolFree() + book.putEscrow() + book.totalCollateral(),
            tag
        );
    }

    function _mark() internal view returns (uint256 m) {
        (m,,,,) = book.sideState(CALL_U);
    }

    /// @dev Exact ceil-to-tick cover sale for a gain `g` (6dp), at the vault's live spot px.
    function _sellFor(uint256 g) internal view returns (uint256 sellHype) {
        uint256 px = vault.spotPxUsdc();
        uint256 hypeForG = (g * 1e12) * 1e18 / px;
        sellHype = ((hypeForG + 1e16 - 1) / 1e16) * 1e16;
    }

    // ── THE FIX in isolation: deposit via transferFrom ────────────────────────

    /// @notice book.deposit now pulls trader USDC via ERC20 transferFrom (CoreCoverVault reverted here).
    function test_deposit_transferFrom_succeeds() public {
        usdc.mint(ALICE, 1_000e6);
        vm.prank(ALICE);
        usdc.approve(address(vault), 1_000e6);

        uint256 vaultEvmBefore = usdc.balanceOf(address(vault));

        vm.prank(ALICE);
        book.deposit(CALL, 1_000e6); // <-- was impossible with CoreCoverVault

        assertEq(usdc.balanceOf(ALICE), 0,                              "trader USDC pulled");
        assertEq(usdc.balanceOf(address(vault)), vaultEvmBefore + 1_000e6, "vault EVM USDC += deposit");
        assertEq(book.traderCollateral(CALL_U, ALICE), 1_000e6,         "collateral credited");
        _assertConservation("conservation after deposit");
    }

    /// @notice The old blocker is gone, but a real ERC20 approval is still required.
    function test_deposit_withoutApproval_reverts() public {
        usdc.mint(ALICE, 1_000e6);
        vm.prank(ALICE);
        vm.expectRevert(); // ERC20InsufficientAllowance
        book.deposit(CALL, 1_000e6);
    }

    // ── FULL lifecycle: deposit → open → winning close → withdraw ─────────────

    /// @notice Headline proof: the deposit fix unblocks the complete winning lifecycle, with a
    ///         physical payout and conservation holding at every step.
    function test_full_lifecycle_deposit_open_close_payout() public {
        // 1) Deposit (THE FIX)
        usdc.mint(ALICE, 1_000e6);
        vm.prank(ALICE);
        usdc.approve(address(vault), 1_000e6);
        vm.prank(ALICE);
        book.deposit(CALL, 1_000e6);
        _assertConservation("after deposit");

        // 2) Open at the S=100 autonomous mark (cover gate: coverHype 100 >= qty 1)
        vm.warp(100);
        book.accrue(CALL);
        uint256 entry = _mark();
        vm.prank(ALICE);
        book.openLong(CALL, 1e18);
        (uint256 qty,,) = book.positions(CALL_U, ALICE);
        assertEq(qty, 1e18, "position opened");

        // 3) Winning move: drive the oracle up (fairMark(CALL) rises); same block ⇒ no funding.
        oracle.set(110e18);
        book.accrue(CALL);
        uint256 exit = _mark();
        assertGt(exit, entry, "mark rose with spot (winning)");
        uint256 g = 1e18 * (exit - entry) / 1e18 / 1e12;
        uint256 sellHype = _sellFor(g);

        // 4) Close (winning): book (keeper) sells cover on Core; settle the async fill.
        uint256 coverBefore = vault.coverHype();
        vm.prank(ALICE);
        book.close(CALL);           // sellCover placed (async) + g credited from existing poolFree
        CoreSimulatorLib.nextBlock(); // cover-sale proceeds land on the Core float

        assertEq(book.traderCollateral(CALL_U, ALICE), 1_000e6 + g, "trader credited g");
        assertEq(vault.coverHype(), coverBefore - sellHype, "cover sold = ceil-to-tick(hypeForG)");
        (uint256 qtyAfter,,) = book.positions(CALL_U, ALICE);
        assertEq(qtyAfter, 0, "position closed");
        _assertConservation("after winning close (settled)");

        // 5) Withdraw — physical USDC payout via ERC20 transfer from the EVM buffer.
        uint256 payout = book.traderCollateral(CALL_U, ALICE); // 1000 + g
        uint256 vaultEvmBefore = usdc.balanceOf(address(vault));
        vm.prank(ALICE);
        book.withdraw(CALL, payout);

        assertEq(usdc.balanceOf(ALICE), payout,                 "trader physically paid (transfer out)");
        assertEq(usdc.balanceOf(address(vault)), vaultEvmBefore - payout, "vault EVM buffer debited");
        assertEq(book.traderCollateral(CALL_U, ALICE), 0,       "collateral fully withdrawn");
        _assertConservation("after withdraw");

        // Trader net: deposited 1000, withdrew 1000+g → realized +g winning end-to-end.
        assertEq(usdc.balanceOf(ALICE), 1_000e6 + g, "trader realized +g winning");
    }

    /// @notice Losing close also flows through the EVM-custody vault: loss accrues to the pool,
    ///         trader withdraws the remainder, conservation holds.
    function test_full_lifecycle_losing_close() public {
        usdc.mint(ALICE, 1_000e6);
        vm.prank(ALICE);
        usdc.approve(address(vault), 1_000e6);
        vm.prank(ALICE);
        book.deposit(CALL, 1_000e6);

        vm.warp(100);
        // Entry regime: spot below Kcall ($120) so the call is OTM (mark is pure extrinsic).
        oracle.set(110e18);
        book.accrue(CALL);
        uint256 entryMark = book.fairMark(CALL); // == the mark openLong records
        vm.prank(ALICE);
        book.openLong(CALL, 1e18);

        // Autonomous mark falls: drop spot so fairMark(CALL) declines → losing close.
        // No time warp between open and this accrue ⇒ zero funding, pure markLoss.
        oracle.set(90e18);
        book.accrue(CALL);
        uint256 exitMark = book.fairMark(CALL);
        uint256 expLoss = (entryMark - exitMark) / 1e12; // qty=1e18 → _toUsdc(Δmark)
        assertGt(expLoss, 0, "mark fell -> loss");

        uint256 coverBefore = vault.coverHype();
        vm.prank(ALICE);
        book.close(CALL);

        assertEq(book.traderCollateral(CALL_U, ALICE), 1_000e6 - expLoss, "collateral -= loss");
        assertEq(vault.coverHype(), coverBefore, "no cover sold on a loss");
        _assertConservation("after losing close");

        // Trader withdraws the surviving collateral from the EVM buffer.
        uint256 survivor = 1_000e6 - expLoss;
        vm.prank(ALICE);
        book.withdraw(CALL, survivor);
        assertEq(usdc.balanceOf(ALICE), survivor, "trader withdrew survivor collateral");
        _assertConservation("after loss withdraw");
    }
}
