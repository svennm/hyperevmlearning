// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {Script, console2} from "forge-std/Script.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {OracleLib} from "../src/OracleLib.sol";
import {EverlastingMarket} from "../src/EverlastingMarket.sol";

contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address keeper = vm.addr(vm.envUint("KEEPER_PRIVATE_KEY"));
        uint256 K   = vm.envUint("STRIKE_K");        // wad, computed off-chain (see RUNBOOK)
        uint256 KHI = vm.envUint("STRIKE_K_HI");     // wad, call upper strike; W = KHI - K
        uint256 feeBps = vm.envUint("PROTOCOL_FEE_BPS");
        require(KHI > K, "K_HI<=K");
        vm.startBroadcast(pk);
        MockUSDC usdc = new MockUSDC();
        OracleLib oracle = new OracleLib();
        EverlastingMarket put  = new EverlastingMarket(usdc, oracle, EverlastingMarket.Side.PUT,  K, K,        keeper);
        EverlastingMarket call_= new EverlastingMarket(usdc, oracle, EverlastingMarket.Side.CALL, K, KHI - K,  keeper);
        put.setProtocolFeeBps(feeBps);
        call_.setProtocolFeeBps(feeBps);
        vm.stopBroadcast();
        console2.log("MockUSDC", address(usdc));
        console2.log("OracleLib", address(oracle));
        console2.log("PUT",  address(put));
        console2.log("CALL", address(call_));
        console2.log("K(wad)", K); console2.log("K_HI(wad)", KHI); console2.log("feeBps", feeBps);
    }
}
