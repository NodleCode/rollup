// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {L1Bridge} from "../src/bridge/L1Bridge.sol";
import {L1Nodl} from "../src/L1Nodl.sol";

/// @notice Forge script to deploy L1Bridge on EVM networks (e.g., Sepolia)
/// Env vars required:
/// - L1_BRIDGE_OWNER (address)
/// - L1_MAILBOX     (address)
/// - NODL_L1        (address)
/// - L2_BRIDGE      (address)
/// Deployer key must have DEFAULT_ADMIN_ROLE on L1Nodl to grant MINTER_ROLE.
contract DeployL1Bridge is Script {
    address internal ownerAddr;
    address internal l1Mailbox;
    address internal l1Token;
    address internal l2Bridge;

    function setUp() public {
        ownerAddr = vm.envAddress("L1_BRIDGE_OWNER");
        l1Mailbox = vm.envAddress("L1_MAILBOX");
        l1Token = vm.envAddress("L1_NODL");
        l2Bridge = vm.envAddress("L2_BRIDGE");

        vm.label(ownerAddr, "L1_BRIDGE_OWNER");
        vm.label(l1Mailbox, "L1_MAILBOX");
        vm.label(l1Token, "L1_NODL");
        vm.label(l2Bridge, "L2_BRIDGE");
    }

    function run() public {
        vm.startBroadcast();

        L1Bridge bridge = new L1Bridge(ownerAddr, l1Mailbox, l1Token, l2Bridge);

        L1Nodl nodl = L1Nodl(l1Token);
        bytes32 minterRole = keccak256("MINTER_ROLE");
        nodl.grantRole(minterRole, address(bridge));

        vm.stopBroadcast();

        console.log("Deployed L1Bridge at %s", address(bridge));
        console.log("Granted MINTER_ROLE on NodlL1(%s) to bridge", l1Token);
    }
}
