// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {L2Bridge} from "../src/bridge/L2Bridge.sol";

/// @notice Forge script to deploy L2Bridge (designed for zkSync Era).
/// Env vars required:
/// - L2_BRIDGE_OWNER (address)
/// - NODL        (address)
///
/// @dev This script only deploys. `MINTER_ROLE` on NODL is held by the L2 admin Safe on
/// mainnet, so the grant is emitted below as calldata for the Safe to execute rather than
/// broadcast from the deployer key. `initialize(l1Bridge)` is likewise an owner call the Safe
/// makes once the L1 address is known. See ops/bridgehub-migration-cutover.md.
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

        vm.stopBroadcast();

        console.log("Deployed L2Bridge at %s", address(bridge));

        console.log("REQUIRED Safe tx 1/2 - grant MINTER_ROLE, to %s", nodlAddr);
        console.logBytes(
            abi.encodeWithSignature("grantRole(bytes32,address)", keccak256("MINTER_ROLE"), address(bridge))
        );
        console.log("REQUIRED Safe tx 2/2 - initialize with the new L1Bridge, to %s", address(bridge));
        console.log("  initialize(address) selector 0xc4d66de8, arg = new L1Bridge address");
        console.log("Bridge cannot mint or accept deposits until the Safe executes both.");
    }
}
