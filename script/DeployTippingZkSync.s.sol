// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {Tipping} from "../src/tipping/Tipping.sol";

/**
 * @title DeployTippingZkSync
 * @notice Deploys the immutable `Tipping` contract (nft-feed-indexer design §6.2, meta#242).
 *         No proxy, no initializer: the constructor sets everything, so a mistaken input
 *         means a new deployment, not an upgrade. Fee starts at 0 with the admin as recipient.
 *
 * Usage: ops/deploy_tipping_zksync.sh <testnet|mainnet> [--broadcast]
 *        (moves the L1-only swarm files aside; plain `forge script --zksync` fails to compile)
 *
 * Environment Variables:
 *   - DEPLOYER_PRIVATE_KEY:  Private key with ETH for gas (gets no role).
 *   - N_TIPPING_ADMIN:       Multisig that will hold DEFAULT_ADMIN_ROLE (fee, fee recipient).
 */
contract DeployTippingZkSync is Script {
    address public tipping;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address admin = vm.envAddress("N_TIPPING_ADMIN");
        require(admin != address(0), "N_TIPPING_ADMIN is zero");

        console.log("=== Deploying Tipping on ZkSync ===");
        console.log("Admin:", admin);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);
        tipping = address(new Tipping(admin));
        vm.stopBroadcast();

        console.log("Tipping:", tipping);
        console.log("");
        console.log("Next: record the address and deploy block in the indexer (chains.ts `tipping`).");
    }
}
