// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.18;

import {Script, console} from "lib/forge-std/src/Script.sol";
import {SparseMerkleTree} from "lib/zksync-storage-proofs/packages/zksync-storage-contracts/src/SparseMerkleTree.sol";
import {
    StorageProofVerifier,
    IZkSyncDiamond
} from "lib/zksync-storage-proofs/packages/zksync-storage-contracts/src/StorageProofVerifier.sol";
import {ClickResolver} from "../src/nameservice/ClickResolver.sol";

interface IResolverSetter {
    function setResolver(bytes32 node, address resolver) external;
}

/// This contract is used to deploy the all the L1 contracts that Nodle needs to allow clk.eth subdomains to be created and resolved on L2
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

        address clickResolverAddress = vm.envOr("CLICK_RESOLVER_ADDR", address(0));

        if (clickResolverAddress != address(0)) {
            console.log("Deploying ClickResolver...");
            ClickResolver l1Resolver = new ClickResolver(
                vm.envString("CNS_OFFCHAIN_RESOLVER_URL"),
                vm.envAddress("CLK_OWNER_ADDR"),
                vm.envAddress("CNS_ADDR"),
                StorageProofVerifier(spvAddress)
            );
            clickResolverAddress = address(l1Resolver);
            console.log("Deployed ClickResolver at", clickResolverAddress);
        }

        string memory label = vm.envString("CNS_DOMAIN");
        bytes32 labelHash = keccak256(abi.encodePacked(label));

        bytes32 ETH_NODE = 0x93cdeb708b7545dc668eb9280176169d1c33cfd8ed6f04690a0bcc88a93fc4ae;
        bytes32 node = keccak256(abi.encodePacked(ETH_NODE, labelHash));

        IResolverSetter resolverSetter = IResolverSetter(vm.envAddress("NAME_WRAPPER_ADDR"));
        resolverSetter.setResolver(node, clickResolverAddress);

        vm.stopBroadcast();
    }
}
