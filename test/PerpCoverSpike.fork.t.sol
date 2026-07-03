// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test, console} from "forge-std/Test.sol";
import {PerpCoverSpike} from "../src/spike/PerpCoverSpike.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";
import {PrecompileSimulator} from "@hyper-evm-lib/test/utils/PrecompileSimulator.sol";

// Live fork read-check for the 3b spike. No funds required — proves the contract deploys and its
// precompile read path (markPx / oraclePx / position / margin) resolves against live testnet 998.
// Run: forge test --match-contract PerpCoverSpikeForkTest --fork-url $HYPEREVM_TESTNET_RPC -vv
contract PerpCoverSpikeForkTest is Test {
    function test_spike_readsLivePerpState() external {
        PrecompileSimulator.init();

        PerpCoverSpike spike = new PerpCoverSpike();

        // Prices must be live and sane.
        uint64 mark = spike.markPx();
        uint64 oracle = spike.oraclePx();
        console.log("HYPE mark wire:", mark);
        console.log("HYPE oracle wire:", oracle);
        assertGt(mark, 0, "mark px zero");
        assertGt(oracle, 0, "oracle px zero");

        // Fresh contract: no cover yet, nothing withdrawable, account not yet activated on Core.
        PrecompileLib.Position memory p = spike.coverPosition();
        assertEq(p.szi, int64(0), "fresh cover should be flat");
        assertEq(spike.withdrawableUsdc(), 0, "fresh withdrawable should be 0");

        // margin() must be readable (all-zero for an unfunded account).
        PrecompileLib.AccountMarginSummary memory m = spike.margin();
        assertEq(m.accountValue, int64(0), "fresh accountValue should be 0");
    }
}
