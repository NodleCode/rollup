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
 * Usage (zkSync Sepolia first, then mainnet):
 *   forge script script/DeployTippingZkSync.s.sol --rpc-url $L2_RPC --broadcast --zksync
 *
 * Environment Variables:
 *   - DEPLOYER_PRIVATE_KEY:  Private key with ETH for gas.
 *   - N_TIPPING_NODL:        NODL ERC-20 on the target chain.
 *   - N_TIPPING_ADMIN:       Multisig that will hold DEFAULT_ADMIN_ROLE (fee, fee recipient, minimum, pause).
 *   - N_TIPPING_REGISTRY:    Operator key that will hold REGISTRY_ROLE (allowlist, creator registry);
 *                            the same key that calls `CollectionFactory.createCollection`.
 *   - N_TIPPING_MIN_TIP:     Initial `minTipAmount` in NODL wei (e.g. 1000000000000000000 for 1 NODL).
 */
contract DeployTippingZkSync is Script {
    address public tipping;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address nodl = vm.envAddress("N_TIPPING_NODL");
        address admin = vm.envAddress("N_TIPPING_ADMIN");
        address registry = vm.envAddress("N_TIPPING_REGISTRY");
        uint256 minTip = vm.envUint("N_TIPPING_MIN_TIP");

        require(nodl != address(0), "N_TIPPING_NODL is zero");
        require(nodl.code.length > 0, "N_TIPPING_NODL is not a contract");
        require(admin != address(0), "N_TIPPING_ADMIN is zero");
        require(registry != address(0), "N_TIPPING_REGISTRY is zero");

        console.log("=== Deploying Tipping on ZkSync ===");
        console.log("NODL:", nodl);
        console.log("Admin:", admin);
        console.log("Registry:", registry);
        console.log("Min tip (wei):", minTip);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);
        tipping = address(new Tipping(nodl, admin, registry, minTip));
        vm.stopBroadcast();

        console.log("Tipping:", tipping);
        console.log("");
        console.log("Next: record the address and deploy block in the indexer (chains.ts `tipping`),");
        console.log("then run script/SeedTippingZkSync.s.sol with the REGISTRY key.");
    }
}
