// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {BatchMintNFT} from "../src/contentsign/BatchMintNFT.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Deployment script for BatchMintNFT upgradeable contract
/// @dev Deploys implementation and proxy, then initializes the contract
contract DeployBatchMintNFT is Script {
    string internal name;
    string internal symbol;
    address internal admin;

    function setUp() public {
        name = vm.envString("BATCH_MINT_NFT_NAME");
        symbol = vm.envString("BATCH_MINT_NFT_SYMBOL");
        admin = vm.envAddress("BATCH_MINT_NFT_ADMIN");

        vm.label(admin, "ADMIN");
    }

    function run() public {
        vm.startBroadcast();

        // Deploy implementation
        console.log("Deploying BatchMintNFT implementation...");
        BatchMintNFT implementation = new BatchMintNFT();
        console.log("Implementation deployed at:", address(implementation));

        // Encode initialize function call
        bytes memory initData = abi.encodeWithSelector(
            BatchMintNFT.initialize.selector,
            name,
            symbol,
            admin
        );

        // Deploy proxy with initialization
        console.log("Deploying ERC1967Proxy...");
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        console.log("Proxy deployed at:", address(proxy));

        // Attach to proxy to get the initialized contract
        BatchMintNFT nft = BatchMintNFT(address(proxy));

        vm.stopBroadcast();

        // Verify deployment
        console.log("\n=== Deployment Summary ===");
        console.log("Implementation address:", address(implementation));
        console.log("Proxy address:", address(proxy));
        console.log("Contract name:", nft.name());
        console.log("Contract symbol:", nft.symbol());
        console.log("Admin address:", admin);
        console.log("Next token ID:", nft.nextTokenId());
        console.log("Max batch size:", nft.MAX_BATCH_SIZE());
        console.log("\nContract is ready for use!");
        console.log("Users can now call safeMint() and batchSafeMint() publicly.");
        console.log("Only admin can upgrade the contract using upgradeTo().");
    }
}
