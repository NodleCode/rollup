// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

import {WhitelistPaymaster} from "../src/paymasters/WhitelistPaymaster.sol";
import {ClickContentSign} from "../src/contentsign/ClickContentSign.sol";

contract DeployContentSign is Script {
    address internal whitelistAdmin;
    address internal withdrawer;

    function setUp() public {
        whitelistAdmin = vm.envAddress("N_WHITELIST_ADMIN");
        withdrawer = vm.envAddress("N_WITHDRAWER");

        vm.label(whitelistAdmin, "WHITELIST_ADMIN");
        vm.label(withdrawer, "WITHDRAWER");
    }

    function run() public {
        vm.startBroadcast();

        WhitelistPaymaster paymaster = new WhitelistPaymaster(withdrawer);
        ClickContentSign nft = new ClickContentSign("ContentSign", "SIGNED", paymaster);

        address[] memory whitelist = new address[](1);
        whitelist[0] = address(nft);

        // make sure paymaster allows calls to NFT contract
        paymaster.addWhitelistedContracts(whitelist);

        // make sure whitelist admin is configured
        paymaster.grantRole(paymaster.WHITELIST_ADMIN_ROLE(), whitelistAdmin);

        vm.stopBroadcast();

        console.log("Deployed ClickContentSign at %s", address(nft));
        console.log("Deployed WhitelistPaymaster at %s", address(paymaster));
        console.log("Please ensure you fund the paymaster contract with enough ETH!");
    }
}
