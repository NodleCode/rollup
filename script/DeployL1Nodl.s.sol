// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {L1Nodl} from "../src/L1Nodl.sol";

/// @notice Forge script to deploy L1Nodl on EVM networks (e.g., Sepolia)
/// Reads constructor args from environment:
/// - NODL_ADMIN  (address)
/// - NODL_MINTER (address)
/// Use with: forge script script/DeployL1Nodl.s.sol:DeployL1Nodl --rpc-url <RPC> --broadcast --private-key <KEY>
contract DeployL1Nodl is Script {
    address internal admin;
    address internal minter;

    function setUp() public {
        admin = vm.envAddress("NODL_ADMIN");
        minter = vm.envAddress("NODL_MINTER");

        vm.label(admin, "NODL_ADMIN");
        vm.label(minter, "NODL_MINTER");
    }

    function run() public {
        vm.startBroadcast();

        L1Nodl token = new L1Nodl(admin, minter);

        vm.stopBroadcast();

        console.log("Deployed L1Nodl at %s", address(token));
    }
}
