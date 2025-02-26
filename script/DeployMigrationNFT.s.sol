// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity 0.8.23;

import {Script, console} from "forge-std/Script.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {MigrationNFT} from "../src/bridge/MigrationNFT.sol";
import {NODLMigration} from "../src/bridge/NODLMigration.sol";

contract DeployMigrationNFT is Script {
    using Strings for uint256;

    NODLMigration internal migration;
    uint256 internal maxHolders;
    uint256[] internal levels;
    string[] internal levelToTokenURI;

    function setUp() public {
        migration = NODLMigration(vm.envAddress("N_MIGRATION"));
        maxHolders = vm.envUint("N_MAX_HOLDERS");

        uint256 nbLevels = vm.envUint("N_LEVELS");
        levels = new uint256[](nbLevels);
        for (uint256 i = 0; i < nbLevels; i++) {
            levels[i] = vm.envUint(string.concat("N_LEVELS_", i.toString()));
        }
        for (uint256 i = 0; i < nbLevels; i++) {
            levelToTokenURI.push(vm.envString(string.concat("N_LEVELS_URI_", i.toString())));
        }
    }

    function run() public {
        vm.startBroadcast();

        MigrationNFT nft = new MigrationNFT(migration, maxHolders, levels, levelToTokenURI);

        vm.stopBroadcast();

        console.log("Deployed MigrationNFT at %s", address(nft));
    }
}
