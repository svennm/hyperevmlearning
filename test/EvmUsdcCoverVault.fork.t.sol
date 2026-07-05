// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {EvmUsdcCoverVault} from "../src/EvmUsdcCoverVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HLConstants} from "@hyper-evm-lib/src/common/HLConstants.sol";
import {PrecompileSimulator} from "@hyper-evm-lib/test/utils/PrecompileSimulator.sol";

/// @notice Fork-read test for EvmUsdcCoverVault.
///         Connects to testnet, deploys a fresh vault wired to the canonical HyperEVM USDC ERC20,
///         and exercises the view functions + gating. No funds; confirms live spotPx resolves,
///         fresh balances are zero, and the two-layer poolUsdc reads both layers as 0.
///         Run with: forge test --match-path '*EvmUsdcCoverVault.fork*'
///                              --fork-url $HYPEREVM_TESTNET_RPC
contract EvmUsdcCoverVaultForkTest is Test {
    EvmUsdcCoverVault vault;

    function setUp() public {
        vm.createSelectFork(vm.envString("HYPEREVM_TESTNET_RPC"));
        PrecompileSimulator.init();
        // Production wiring: USDC is the canonical HyperEVM USDC ERC20 (required for the bridge path).
        vault = new EvmUsdcCoverVault(IERC20(HLConstants.usdc()), address(this));
    }

    function test_fork_spotPxUsdc_liveSanity() public {
        uint256 px = vault.spotPxUsdc();
        assertGt(px, 1e18,      "spot > $1");
        assertLt(px, 10_000e18, "spot < $10k");
        emit log_named_decimal_uint("HYPE spot (WAD)", px, 18);
    }

    function test_fork_coverHype_zero() public view {
        assertEq(vault.coverHype(), 0, "fresh vault: no cover");
    }

    /// @notice Two-layer poolUsdc: EVM ERC20 balance (0) + Core-USDC float (0) = 0 for a fresh vault.
    function test_fork_poolUsdc_zero() public view {
        assertEq(vault.poolUsdc(), 0, "fresh vault: no USDC either layer");
    }

    function test_fork_coverEquityUsdc_zero() public view {
        assertEq(vault.coverEquityUsdc(), 0, "fresh vault: no equity");
    }

    function test_fork_usdc_isCanonical() public view {
        assertEq(address(vault.usdc()), HLConstants.usdc(), "wired to canonical USDC");
    }

    function test_fork_constants() public view {
        assertEq(vault.HYPE_SPOT_ASSET(), 11035);
        assertEq(vault.HYPE_SPOT_INDEX(), 1035);
        assertEq(vault.HYPE_TOKEN(),      1105);
        assertEq(vault.USDC_TOKEN(),      0);
    }

    // ── Gating ────────────────────────────────────────────────────────────────

    function test_fork_buyCover_accessControl() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert("only keeper");
        vault.buyCover(1e18, 100e6);
    }

    function test_fork_sellCover_accessControl() public {
        // C1 (trustless custody): sellCover is onlyBookOrKeeper — a stranger hits "book/keeper".
        vm.prank(makeAddr("stranger"));
        vm.expectRevert("book/keeper");
        vault.sellCover(1e18);
    }

    function test_fork_payoutUsdc_accessControl() public {
        // C1 (trustless custody): fund exits are onlyBook — neither owner nor keeper can extract.
        vm.prank(makeAddr("stranger"));
        vm.expectRevert("only book");
        vault.payoutUsdc(address(this), 1e6);
    }

    function test_fork_bridgeToCore_accessControl() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert("only keeper");
        vault.bridgeUsdcToCore(1e6);
    }

    function test_fork_bridgeToEvm_accessControl() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert("only keeper");
        vault.bridgeUsdcToEvm(1e6);
    }

    /// @notice pullUsdc is a real ERC20 transferFrom now — reverts without balance/approval.
    function test_fork_pullUsdc_noApprovalReverts() public {
        vm.expectRevert();
        vault.pullUsdc(address(this), 100e6);
    }
}
