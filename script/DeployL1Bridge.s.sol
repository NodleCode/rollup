// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {L1Bridge} from "../src/bridge/L1Bridge.sol";

/// @notice Forge script to deploy L1Bridge on EVM networks (e.g., Sepolia)
/// Env vars required:
/// - L1_BRIDGE_OWNER (address)
/// - L1_MAILBOX     (address) — Diamond proxy, used for L2->L1 proofs
/// - BRIDGEHUB      (address) — Bridgehub, used for deposits and base-cost quotes
/// - L2_CHAIN_ID    (uint)    — chain id of the target L2 as registered on the Bridgehub
/// - NODL_L1        (address)
/// - L2_BRIDGE      (address)
/// - LEGACY_BRIDGE  (address, optional) — previous L1Bridge deployment whose finalized
///   withdrawals must not be replayed here. REQUIRED when redeploying over a live bridge,
///   omit only for a first-ever deployment on the chain.
///
/// @dev This script only deploys. `MINTER_ROLE` on L1Nodl is held by the NODL admin Safe on
/// mainnet, so the grant is emitted below as calldata for the Safe to execute rather than
/// broadcast from the deployer key. See ops/bridgehub-migration-cutover.md.
contract DeployL1Bridge is Script {
    address internal ownerAddr;
    address internal l1Mailbox;
    address internal bridgehub;
    uint256 internal l2ChainId;
    address internal l1Token;
    address internal l2Bridge;
    address internal legacyBridge;

    function setUp() public {
        ownerAddr = vm.envAddress("L1_BRIDGE_OWNER");
        l1Mailbox = vm.envAddress("L1_MAILBOX");
        bridgehub = vm.envAddress("BRIDGEHUB");
        l2ChainId = vm.envUint("L2_CHAIN_ID");
        l1Token = vm.envAddress("L1_NODL");
        l2Bridge = vm.envAddress("L2_BRIDGE");
        legacyBridge = vm.envOr("LEGACY_BRIDGE", address(0));

        vm.label(ownerAddr, "L1_BRIDGE_OWNER");
        vm.label(l1Mailbox, "L1_MAILBOX");
        vm.label(bridgehub, "BRIDGEHUB");
        vm.label(l1Token, "L1_NODL");
        vm.label(l2Bridge, "L2_BRIDGE");
        if (legacyBridge != address(0)) {
            vm.label(legacyBridge, "LEGACY_BRIDGE");
        }
    }

    function run() public {
        vm.startBroadcast();

        L1Bridge bridge =
            new L1Bridge(ownerAddr, l1Mailbox, bridgehub, l2ChainId, l1Token, l2Bridge, legacyBridge);

        vm.stopBroadcast();

        console.log("Deployed L1Bridge at %s", address(bridge));
        if (legacyBridge == address(0)) {
            console.log("WARNING: no LEGACY_BRIDGE set - only correct for a first-ever deployment");
        } else {
            console.log("Legacy bridge (withdrawal replays rejected): %s", legacyBridge);
        }

        console.log("REQUIRED Safe tx - grant MINTER_ROLE, to %s", l1Token);
        console.logBytes(
            abi.encodeWithSignature("grantRole(bytes32,address)", keccak256("MINTER_ROLE"), address(bridge))
        );
        console.log("Bridge cannot mint until the Safe executes the call above.");
    }
}
