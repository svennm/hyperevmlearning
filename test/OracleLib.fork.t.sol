// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {Test} from "forge-std/Test.sol";
import {OracleLib} from "../src/OracleLib.sol";
import {PrecompileSimulator} from "@hyper-evm-lib/test/utils/PrecompileSimulator.sol";

contract OracleLibForkTest is Test {
    function test_readsLiveHypePrice() public {
        vm.createSelectFork(vm.envString("HYPEREVM_TESTNET_RPC"));
        PrecompileSimulator.init(); // etch HyperEVM precompiles (0x800-0x813) so Foundry's EVM can forward calls via vm.rpc
        OracleLib o = new OracleLib();
        uint256 s = o.spotWad();
        // sanity band: $1 .. $10,000 in WAD
        assertGt(s, 1e18);
        assertLt(s, 10_000e18);
        emit log_named_decimal_uint("HYPE spot", s, 18);
    }
}
