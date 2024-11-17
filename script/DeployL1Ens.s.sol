// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.18;

import {Script, console} from "lib/forge-std/src/Script.sol";
import {SparseMerkleTree} from "lib/zksync-storage-proofs/packages/zksync-storage-contracts/src/SparseMerkleTree.sol";

/// This contract is used to deploy the all the L1 contracts that Nodle needs to allow clk.eth subdomains to be created and resoved on L2
contract DeployL1Ens is Script {
    address public spvAddress;

    function run() external {
        string memory smtDefault = "";
        string memory smtAddress = vm.envOr("SPARSE_MERKLE_TREE_ADDR", smtDefault);
        string memory deployerPrivateKey = vm.envString("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(vm.parseUint(deployerPrivateKey));

        if (bytes(smtAddress).length == 0) {
            console.log("Deploying SparseMerkleTree...");
            SparseMerkleTree sparseMerkleTree = new SparseMerkleTree();
            spvAddress = address(sparseMerkleTree);
            console.log("Deployed SparseMerkleTree at", smtAddress);
        } else {
            console.log("Using SparseMerkleTree at", smtAddress);
        }

        vm.stopBroadcast();
    }
}
