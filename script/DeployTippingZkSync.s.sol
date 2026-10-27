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
 *   - N_TIPPING_ADMIN:       Multisig that will hold DEFAULT_ADMIN_ROLE (fee, fee recipient, signer, pause).
 *   - N_TIPPING_SIGNER:      Address whose EIP-712 signatures authorize post tips (the feed API's
 *                            signing key, or an ERC-1271 contract). Rotatable by the admin.
 */
contract DeployTippingZkSync is Script {
    address public tipping;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address admin = vm.envAddress("N_TIPPING_ADMIN");
        address signer = vm.envAddress("N_TIPPING_SIGNER");

        require(admin != address(0), "N_TIPPING_ADMIN is zero");
        require(signer != address(0), "N_TIPPING_SIGNER is zero");

        console.log("=== Deploying Tipping on ZkSync ===");
        console.log("Admin:", admin);
        console.log("Signer:", signer);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);
        tipping = address(new Tipping(admin, signer));
        vm.stopBroadcast();

        console.log("Tipping:", tipping);
        console.log("");
        console.log("Next: record the address and deploy block in the indexer (chains.ts `tipping`)");
        console.log("and point the feed API's tip authorizer at it (same chain id, same address).");
    }
}
