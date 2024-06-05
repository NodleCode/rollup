// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity 0.8.23;

import {Script, console} from "forge-std/Script.sol";
import {MigrationNFT} from "../src/bridge/MigrationNFT.sol";
import {NODLMigration} from "../src/bridge/NODLMigration.sol";

contract DeployMigrationNFT is Script {
    NODLMigration internal migration;
    uint256 internal maxNFTs;
    uint256 internal minAmount;
    string internal tokensURI;

    function setUp() public {
        migration = NODLMigration(vm.envAddress("N_MIGRATION"));
        maxNFTs = vm.envUint("N_MAX_NFTS");
        minAmount = vm.envUint("N_MIN_AMOUNT");
        tokensURI = vm.envString("N_TOKENS_URI");
    }

    function run() public {
        vm.startBroadcast();

        MigrationNFT nft = new MigrationNFT(migration, maxNFTs, minAmount, tokensURI);

        vm.stopBroadcast();

        console.log("Deployed MigrationNFT at %s", address(nft));
    }
}
