// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

import {WhitelistPaymaster} from "../src/paymasters/WhitelistPaymaster.sol";
import {EnterpriseContentSign} from "../src/contentsign/EnterpriseContentSign.sol";

contract DeployContentSignEnterprise is Script {
    string internal name;
    string internal symbol;

    function setUp() public {
        name = vm.envString("N_NAME");
        symbol = vm.envString("N_SYMBOL");
    }

    function run() public {
        vm.startBroadcast();

        EnterpriseContentSign nft = new EnterpriseContentSign(name, symbol);

        vm.stopBroadcast();

        console.log("Deployed EnterpriseContentSign at %s", address(nft));
        console.log("Name: %s", name);
        console.log("Symbol: %s", symbol);
        console.log("Reminder to whitelist users with the WHITELISTED_ROLE role using the AccessControl contract.");
    }
}
