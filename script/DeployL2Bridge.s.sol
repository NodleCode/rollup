// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {L2Bridge} from "../src/bridge/L2Bridge.sol";
import {NODL} from "../src/NODL.sol";

/// @notice Forge script to deploy L2Bridge (designed for zkSync Era).
/// Env vars required:
/// - L2_BRIDGE_OWNER (address)
/// - NODL        (address)
/// The deployer must have DEFAULT_ADMIN_ROLE on NODL to grant MINTER_ROLE.
contract DeployL2Bridge is Script {
    address internal ownerAddr;
    address internal l1Bridge;
    address internal nodlAddr;

    function setUp() public {
        ownerAddr = vm.envAddress("L2_BRIDGE_OWNER");
        nodlAddr = vm.envAddress("NODL");

        vm.label(ownerAddr, "L2_BRIDGE_OWNER");
        vm.label(nodlAddr, "NODL");
    }

    function run() public {
        vm.startBroadcast();

        L2Bridge bridge = new L2Bridge(ownerAddr, nodlAddr);

        NODL nodl = NODL(nodlAddr);
        bytes32 minterRole = keccak256("MINTER_ROLE");
        nodl.grantRole(minterRole, address(bridge));

        vm.stopBroadcast();

        console.log("Deployed L2Bridge at %s", address(bridge));
        console.log("Granted MINTER_ROLE on NODL(%s) to bridge", nodlAddr);
    }
}
