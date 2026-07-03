// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {EnterpriseContentSign} from "../src/contentsign/EnterpriseContentSign.sol";

contract ContentSignWhitelist is Script {
    EnterpriseContentSign internal contentsign;
    address internal toWhitelist;

    function setUp() public {
        contentsign = EnterpriseContentSign(vm.envAddress("N_CONTENTSIGN"));
        toWhitelist = vm.envAddress("N_WHITELIST");
    }

    function run() public {
        bytes32 role = contentsign.WHITELISTED_ROLE();

        if (contentsign.hasRole(role, toWhitelist)) {
            console.log("User %s is already whitelisted", toWhitelist);
        } else {
            console.log("User %s is not whitelisted, whitelisting them...", toWhitelist);

            vm.startBroadcast();
            contentsign.grantRole(role, toWhitelist);
            vm.stopBroadcast();
        }
    }
}
