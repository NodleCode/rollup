// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.18;

import {Script, console} from "lib/forge-std/src/Script.sol";
import {UniversalResolver} from "../src/nameservice/UniversalResolver.sol";

interface IResolverSetter {
    function setResolver(bytes32 node, address resolver) external;
}

/// This contract is used to deploy the all the L1 contracts that Nodle needs to allow clk.eth subdomains to be created and resolved on L2
contract DeployL1Ens is Script {
    function run() external {
        string memory deployerPrivateKey = vm.envString("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(vm.parseUint(deployerPrivateKey));

        address resolverAddress = vm.envOr("NS_RESOLVER_ADDR", address(0));

        if (resolverAddress == address(0)) {
            console.log("Deploying UniversalResolver (signed-gateway model)...");
            UniversalResolver l1Resolver = new UniversalResolver(
                vm.envString("NS_OFFCHAIN_RESOLVER_URL"),
                vm.envAddress("NS_OWNER_ADDR"),
                vm.envAddress("NS_ADDR"),
                vm.envAddress("NS_TRUSTED_SIGNER_ADDR")
            );
            resolverAddress = address(l1Resolver);
            console.log("Deployed UniversalResolver at", resolverAddress);
        }

        // Optional: auto-repoint ENS to the new resolver in the same broadcast.
        // Enable by setting SKIP_SET_RESOLVER to 0 (default is 1 = skip, so mainnet
        // cutover happens as a separate owner-signed tx). Useful on testnets where
        // the deployer already controls the ENS node.
        uint256 skipSetResolver = vm.envOr("SKIP_SET_RESOLVER", uint256(1));
        if (skipSetResolver == 0) {
            string memory label = vm.envString("NS_DOMAIN");
            bytes32 labelHash = keccak256(abi.encodePacked(label));

            bytes32 ETH_NODE = 0x93cdeb708b7545dc668eb9280176169d1c33cfd8ed6f04690a0bcc88a93fc4ae;
            bytes32 node = keccak256(abi.encodePacked(ETH_NODE, labelHash));

            IResolverSetter resolverSetter = IResolverSetter(vm.envAddress("NAME_WRAPPER_ADDR"));
            resolverSetter.setResolver(node, resolverAddress);
            console.log("Repointed ENS node to new resolver");
        } else {
            console.log("Skipping ENS setResolver (SKIP_SET_RESOLVER=1)");
            console.log("Run ENSRegistry.setResolver(...) separately with the node owner.");
        }

        vm.stopBroadcast();
    }
}
