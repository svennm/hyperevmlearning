// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {CoreCoverVault} from "../src/CoreCoverVault.sol";
import {PrecompileSimulator} from "@hyper-evm-lib/test/utils/PrecompileSimulator.sol";

/// @notice Fork-read test for CoreCoverVault.
///         Connects to testnet, deploys a fresh vault, and exercises all view functions.
///         No actual funds; confirms live spotPx resolves and fresh balances are zero.
///         Run with: forge test --match-path '*CoreCoverVault.fork*'
///                              --fork-url $HYPEREVM_TESTNET_RPC  (or -vvvv for diagnostics)
contract CoreCoverVaultForkTest is Test {
    CoreCoverVault vault;

    function setUp() public {
        vm.createSelectFork(vm.envString("HYPEREVM_TESTNET_RPC"));
        // Etch precompiles so Foundry's EVM can proxy read-only calls via vm.rpc
        PrecompileSimulator.init();
        vault = new CoreCoverVault(address(this));
    }

    /// @notice spotPxUsdc() reads the live HYPE price on testnet and returns a WAD value.
    function test_fork_spotPxUsdc_liveSanity() public {
        uint256 px = vault.spotPxUsdc();
        // Sanity band: HYPE price between $1 and $10,000
        assertGt(px, 1e18,       "spot price should be > $1");
        assertLt(px, 10_000e18,  "spot price should be < $10k");
        emit log_named_decimal_uint("HYPE spot (WAD)", px, 18);
    }

    /// @notice Fresh vault has no HYPE cover (freshly deployed, no funding).
    function test_fork_coverHype_zero() public view {
        assertEq(vault.coverHype(), 0, "fresh vault: no HYPE cover");
    }

    /// @notice Fresh vault has no USDC pool balance.
    function test_fork_poolUsdc_zero() public view {
        assertEq(vault.poolUsdc(), 0, "fresh vault: no USDC pool");
    }

    /// @notice coverEquityUsdc() = 0 when there is no cover.
    function test_fork_coverEquityUsdc_zero() public view {
        assertEq(vault.coverEquityUsdc(), 0, "fresh vault: no equity");
    }

    /// @notice Confirms constants match the testnet-verified spike values.
    function test_fork_constants() public view {
        assertEq(vault.HYPE_SPOT_ASSET(), 11035, "HYPE_SPOT_ASSET = 10000 + pair 1035");
        assertEq(vault.HYPE_SPOT_INDEX(), 1035,  "HYPE_SPOT_INDEX = pair 1035");
        assertEq(vault.HYPE_TOKEN(),      1105,  "HYPE Core token = 1105");
        assertEq(vault.USDC_TOKEN(),      0,     "USDC Core token = 0");
    }

    /// @notice pullUsdc reverts with the diagnostic message.
    function test_fork_pullUsdc_reverts() public {
        vm.expectRevert("CoreCoverVault: deposit via Core account, no on-chain pull");
        vault.pullUsdc(address(this), 100e6);
    }

    /// @notice Only owner or keeper can call buyCover; stranger is rejected.
    function test_fork_buyCover_accessControl() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert("only keeper");
        vault.buyCover(1e18, 100e6);
    }

    /// @notice Only owner or keeper can call sellCover; stranger is rejected.
    function test_fork_sellCover_accessControl() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert("only keeper");
        vault.sellCover(1e18);
    }

    /// @notice Only owner or keeper can call payoutUsdc; stranger is rejected.
    function test_fork_payoutUsdc_accessControl() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert("only keeper");
        vault.payoutUsdc(address(this), 1e6);
    }
}
