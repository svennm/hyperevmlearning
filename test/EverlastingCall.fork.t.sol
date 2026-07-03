// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {Test} from "forge-std/Test.sol";
import {EverlastingMarket} from "../src/EverlastingMarket.sol";
import {OracleLib} from "../src/OracleLib.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {PrecompileSimulator} from "@hyper-evm-lib/test/utils/PrecompileSimulator.sol";

// Live fork: requires HYPEREVM_TESTNET_RPC. Run: forge test --match-contract CallForkTest --fork-url $HYPEREVM_TESTNET_RPC -vv
contract CallForkTest is Test {
    function test_call_intrinsic_readsLiveOracle_andClamps() external {
        // (1) Etch HyperEVM precompiles so Foundry's EVM can forward precompile calls via vm.rpc
        PrecompileSimulator.init();

        // (2) Deploy OracleLib and read live price
        OracleLib oracle = new OracleLib();
        uint256 s = oracle.spotWad();
        require(s > 0, "no live px");

        // (3) Deploy MockUSDC
        MockUSDC usdc = new MockUSDC();

        // (4) Deploy CALL market deep ITM
        EverlastingMarket c = new EverlastingMarket(
            usdc,
            oracle,
            EverlastingMarket.Side.CALL,
            s / 2,
            1e18,
            address(this)
        );
        assertEq(c.intrinsicWad(), 1e18, "ITM call intrinsic should be capped at W");

        // (5) Deploy CALL market OTM
        EverlastingMarket c2 = new EverlastingMarket(
            usdc,
            oracle,
            EverlastingMarket.Side.CALL,
            s * 2,
            1e18,
            address(this)
        );
        assertEq(c2.intrinsicWad(), 0, "OTM call intrinsic should be zero");
    }
}
