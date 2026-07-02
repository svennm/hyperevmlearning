// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;
import {Script, console2} from "forge-std/Script.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {OracleLib} from "../src/OracleLib.sol";
import {EverlastingPut} from "../src/EverlastingPut.sol";

contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address keeper = vm.addr(vm.envUint("KEEPER_PRIVATE_KEY"));
        vm.startBroadcast(pk);
        MockUSDC usdc = new MockUSDC();
        OracleLib oracle = new OracleLib();
        uint256 spot = oracle.spotWad();
        uint256 K = (spot / 1e18) * 1e18;         // ATM-ish, whole-dollar strike
        EverlastingPut put = new EverlastingPut(usdc, oracle, K, keeper);
        vm.stopBroadcast();
        console2.log("MockUSDC", address(usdc));
        console2.log("OracleLib", address(oracle));
        console2.log("EverlastingPut", address(put));
        console2.log("K(wad)", K);
    }
}
