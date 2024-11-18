// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.18;

import {Script, console} from "lib/forge-std/src/Script.sol";
import {SparseMerkleTree} from "lib/zksync-storage-proofs/packages/zksync-storage-contracts/src/SparseMerkleTree.sol";
import {
    StorageProofVerifier,
    IZkSyncDiamond
} from "lib/zksync-storage-proofs/packages/zksync-storage-contracts/src/StorageProofVerifier.sol";

/// This contract is used to deploy the all the L1 contracts that Nodle needs to allow clk.eth subdomains to be created and resoved on L2
contract DeployL1Ens is Script {
    function run() external {
        string memory deployerPrivateKey = vm.envString("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(vm.parseUint(deployerPrivateKey));

        address spvAddress = vm.envOr("STORAGE_PROOF_VERIFIER_ADDR", address(0));

        if (spvAddress == address(0)) {
            address smtAddress = vm.envOr("SPARSE_MERKLE_TREE_ADDR", address(0));
            if (smtAddress == address(0)) {
                console.log("Deploying SparseMerkleTree...");
                SparseMerkleTree sparseMerkleTree = new SparseMerkleTree();
                smtAddress = address(sparseMerkleTree);
                console.log("Deployed SparseMerkleTree at", smtAddress);
            } else {
                console.log("Using SparseMerkleTree at", smtAddress);
            }

            console.log("Deploying StorageProofVerifier...");
            StorageProofVerifier storageProofVerifier = new StorageProofVerifier(
                IZkSyncDiamond(vm.envAddress("DIAMOND_PROXY_ADDR")), SparseMerkleTree(smtAddress)
            );
            spvAddress = address(storageProofVerifier);
        } else {
            console.log("Using StorageProofVerifier at", spvAddress);
        }

        vm.stopBroadcast();
    }
}
