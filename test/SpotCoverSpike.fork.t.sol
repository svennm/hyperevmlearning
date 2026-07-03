// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test, console} from "forge-std/Test.sol";
import {SpotCoverSpike} from "../src/spike/SpotCoverSpike.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";
import {PrecompileSimulator} from "@hyper-evm-lib/test/utils/PrecompileSimulator.sol";

// Live fork read-check for the spot-cover spike. No funds required.
// Run: forge test --match-contract SpotCoverSpikeForkTest --fork-url $HYPEREVM_TESTNET_RPC -vv
contract SpotCoverSpikeForkTest is Test {
    function test_spotSpike_readsLiveSpotState() external {
        PrecompileSimulator.init();

        SpotCoverSpike spike = new SpotCoverSpike();

        uint64 px = spike.spotPxHype();
        console.log("HYPE/USDC spot px wire:", px);
        assertGt(px, 0, "spot px zero");

        // Fresh contract: no HYPE, no USDC on Core yet.
        PrecompileLib.SpotBalance memory h = spike.hypeBalance();
        PrecompileLib.SpotBalance memory u = spike.usdcBalance();
        assertEq(h.total, 0, "fresh HYPE balance should be 0");
        assertEq(u.total, 0, "fresh USDC balance should be 0");
    }
}
