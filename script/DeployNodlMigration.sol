// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {NODL} from "../src/NODL.sol";
import {NODLMigration} from "../src/bridge/NODLMigration.sol";

contract DeployNodlMigration is Script {
    address[] internal voters;
    address internal nodlTokenAdmin;

    function setUp() public {
        nodlTokenAdmin = vm.envAddress("N_NODL_TOKEN_ADMIN");
        voters = new address[](3);

        voters[0] = vm.envAddress("N_VOTER1_ADDR");
        voters[1] = vm.envAddress("N_VOTER2_ADDR");
        voters[2] = vm.envAddress("N_VOTER3_ADDR");
    }

    function run() public {
        vm.startBroadcast();

        NODL nodl = new NODL(nodlTokenAdmin);
        address nodlAddress = address(nodl);

        NODLMigration nodlMigration = new NODLMigration(voters, nodl, 2, 3);
        address nodlMigrationAddress = address(nodlMigration);

        nodl.grantRole(nodl.MINTER_ROLE(), nodlMigrationAddress);

        vm.stopBroadcast();

        console.log("Deployed NODL at %s", nodlAddress);
        console.log("Deployed NODLMigration at %s", nodlMigrationAddress);
    }
}
