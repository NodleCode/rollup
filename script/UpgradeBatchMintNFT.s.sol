// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {BatchMintNFT} from "../src/contentsign/BatchMintNFT.sol";

/// @notice Script to upgrade BatchMintNFT proxy to a new implementation
/// @dev Only admin can execute this upgrade
contract UpgradeBatchMintNFT is Script {
    address internal proxy;
    address internal newImplementation;

    function setUp() public {
        proxy = vm.envAddress("BATCH_MINT_NFT_PROXY");
        newImplementation = vm.envAddress("BATCH_MINT_NFT_NEW_IMPL");
    }

    function run() public {
        vm.startBroadcast();

        console.log("Current proxy address:", proxy);
        console.log("New implementation address:", newImplementation);

        // Attach to proxy
        BatchMintNFT nft = BatchMintNFT(proxy);

        // Verify current state before upgrade
        console.log("Current nextTokenId:", nft.nextTokenId());
        console.log("Current mintingEnabled:", nft.mintingEnabled());

        // Perform upgrade
        console.log("\nPerforming upgrade...");
        nft.upgradeTo(newImplementation);

        vm.stopBroadcast();

        // Verify upgrade
        console.log("\n=== Upgrade Summary ===");
        console.log("Proxy address:", proxy);
        console.log("New implementation:", newImplementation);
        console.log("Upgrade completed successfully!");
        console.log("\nVerify that:");
        console.log("1. Data is preserved (tokens, balances, etc.)");
        console.log("2. New methods are available");
        console.log("3. Existing methods still work");
    }
}
