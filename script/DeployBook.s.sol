// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";
import {OracleLib} from "../src/OracleLib.sol";
import {CoreCoverVault} from "../src/CoreCoverVault.sol";
import {EverlastingBook} from "../src/EverlastingBook.sol";
import {ISpotOracle} from "../src/interfaces/ISpotOracle.sol";
import {ICoverVault} from "../src/interfaces/ICoverVault.sol";

/// @notice Slice-3b live deploy: OracleLib + CoreCoverVault + EverlastingBook, wired so the book
///         is the vault's keeper (can sell cover on close). Owner = deployer for both.
/// @dev Run: forge script script/DeployBook.s.sol:DeployBook --rpc-url $HYPEREVM_TESTNET_RPC \
///          --private-key $DEPLOYER_PRIVATE_KEY --broadcast --slow
///      Smoke params are small/at-the-money for testnet HYPE (~$50-56). See docs/RUNBOOK-3b.md.
contract DeployBook is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        // Smoke params (WAD). HYPE ~ $50-56 on testnet; at-the-money strikes, small caps.
        uint256 Kput  = 50e18;
        uint256 Wput  = 50e18;   // put max payout per unit = K (full put)
        uint256 Kcall = 50e18;
        uint256 putCap  = 100e18;
        uint256 callCap = 100e18;

        vm.startBroadcast(pk);

        OracleLib oracle = new OracleLib();                 // reads HYPE perp oracle (idx 135) -> WAD
        CoreCoverVault vault = new CoreCoverVault(deployer); // owner=deployer, keeper=deployer (temp)
        EverlastingBook book = new EverlastingBook(
            ICoverVault(address(vault)),
            ISpotOracle(address(oracle)),
            deployer,                                        // book keeper (posts marks)
            Kput, Wput, Kcall, putCap, callCap
        );
        // Book must be the vault's keeper so its close path can call sellCover.
        // onlyKeeper == owner||keeper, so the deployer (owner) can still call cover ops too.
        vault.setKeeper(address(book));

        vm.stopBroadcast();

        console2.log("OracleLib     ", address(oracle));
        console2.log("CoreCoverVault", address(vault));
        console2.log("EverlastingBook", address(book));
        console2.log("owner/deployer", deployer);
        console2.log("Kput/Wput/Kcall(wad)", Kput, Wput, Kcall);
    }
}
