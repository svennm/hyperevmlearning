// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";
import {OracleLib} from "../src/OracleLib.sol";
import {EvmUsdcCoverVault} from "../src/EvmUsdcCoverVault.sol";
import {EverlastingBook} from "../src/EverlastingBook.sol";
import {ISpotOracle} from "../src/interfaces/ISpotOracle.sol";
import {ICoverVault} from "../src/interfaces/ICoverVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HLConstants} from "@hyper-evm-lib/src/common/HLConstants.sol";

/// @notice Slice-3b live deploy (EVM-USDC deposit-fix vault): OracleLib + EvmUsdcCoverVault +
///         EverlastingBook, wired so the book is the vault's keeper (can pullUsdc on deposit and
///         sellCover on close). Owner = deployer for both.
/// @dev Uses `EvmUsdcCoverVault` (not `CoreCoverVault`): USDC is a real EVM ERC20 so trader
///      `book.deposit`/`lpDeposit` work live via `transferFrom` — the fix for the D2 (Core-spot
///      USDC) deposit break. HYPE cover stays Core-native (CoreWriter spot). Prod USDC =
///      `HLConstants.usdc()` (chain 998 → testnet USDC 0x2B33..D8Ab) so the keeper bridge path works.
/// @dev Run (BIG BLOCKS required — book ~2.5M gas > small-block limit; enable via HL SDK
///      use_big_blocks(True) for the deployer first):
///          forge script script/DeployBook.s.sol:DeployBook --rpc-url $HYPEREVM_TESTNET_RPC \
///          --private-key $DEPLOYER_PRIVATE_KEY --broadcast --slow
///      --slow may TIMEOUT (~2min); if so, read broadcast artifacts and finish setKeeper manually.
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
        // EVM-USDC custody vault: USDC = canonical HLConstants.usdc() so bridge path works;
        // owner = deployer, keeper = deployer (temp, reassigned to the book below).
        EvmUsdcCoverVault vault = new EvmUsdcCoverVault(IERC20(HLConstants.usdc()), deployer);
        EverlastingBook book = new EverlastingBook(
            ICoverVault(address(vault)),
            ISpotOracle(address(oracle)),
            deployer,                                        // book keeper (posts marks)
            Kput, Wput, Kcall, putCap, callCap
        );
        // Book must be the vault's keeper so its deposit path can call pullUsdc and its close path
        // can call sellCover. onlyKeeper == owner||keeper, so the deployer (owner) can still call
        // cover/bridge ops too.
        vault.setKeeper(address(book));

        vm.stopBroadcast();

        console2.log("OracleLib        ", address(oracle));
        console2.log("EvmUsdcCoverVault", address(vault));
        console2.log("EverlastingBook  ", address(book));
        console2.log("USDC (EVM ERC20) ", HLConstants.usdc());
        console2.log("owner/deployer   ", deployer);
        console2.log("Kput/Wput/Kcall(wad)", Kput, Wput, Kcall);
    }
}
