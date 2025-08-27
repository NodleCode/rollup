// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {NODL} from "../src/NODL.sol";

/// @notice Forge script to deploy L2Nodl on EVM networks (e.g., ZkSync Sepolia)
/// Reads constructor args from environment:
/// - NODL_ADMIN  (address)
/// - NODL_MINTER (address)
/// Use with: forge script script/DeployL2Nodl.s.sol:DeployL2Nodl --rpc-url <RPC> --broadcast --private-key <KEY>
contract DeployL2Nodl is Script {
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

        NODL token = new NODL(admin);
        token.grantRole(token.MINTER_ROLE(), minter);
        token.mint(minter, 1_000_000 ether);

        vm.stopBroadcast();

        console.log("Deployed NODL at %s", address(token));
    }
}
