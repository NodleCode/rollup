// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {CollectionFactory} from "../src/collections/CollectionFactory.sol";
import {UserCollection721} from "../src/collections/UserCollection721.sol";
import {UserCollection1155} from "../src/collections/UserCollection1155.sol";

/**
 * @title DeployCollectionFactoryZkSync
 * @notice Deployment script for the user collections system on ZkSync Era.
 * @dev See `src/collections/doc/spec/user-collections-specification.md` (§9.1).
 *
 *      Deploys, in order:
 *        1. UserCollection721 implementation (CREATE only — never CREATE2;
 *           see §7.2 row 15).
 *        2. UserCollection1155 implementation (CREATE only).
 *        3. CollectionFactory logic.
 *        4. ERC1967Proxy pointing at the factory logic, initialized with
 *           (admin, operator, impl721, impl1155).
 *
 * Usage:
 *   forge script script/DeployCollectionFactoryZkSync.s.sol \
 *       --rpc-url $L2_RPC --broadcast --zksync
 *
 * Environment Variables:
 *   - DEPLOYER_PRIVATE_KEY: Private key with ETH for gas.
 *   - N_FACTORY_ADMIN:      Multisig that will hold DEFAULT_ADMIN_ROLE on the factory.
 *   - N_FACTORY_OPERATOR:   Backend service address that will hold OPERATOR_ROLE.
 */
contract DeployCollectionFactoryZkSync is Script {
    address public collection721Impl;
    address public collection1155Impl;
    address public factoryImpl;
    address public factoryProxy;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address admin = vm.envAddress("N_FACTORY_ADMIN");
        address operator = vm.envAddress("N_FACTORY_OPERATOR");

        require(admin != address(0), "N_FACTORY_ADMIN is zero");
        require(operator != address(0), "N_FACTORY_OPERATOR is zero");

        console.log("=== Deploying User Collections on ZkSync ===");
        console.log("Admin:", admin);
        console.log("Operator:", operator);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // 1. UserCollection721 implementation.
        console.log("1. Deploying UserCollection721 implementation...");
        collection721Impl = address(new UserCollection721());
        console.log("   UserCollection721 Implementation:", collection721Impl);

        // 2. UserCollection1155 implementation.
        console.log("2. Deploying UserCollection1155 implementation...");
        collection1155Impl = address(new UserCollection1155());
        console.log("   UserCollection1155 Implementation:", collection1155Impl);

        // 3. CollectionFactory logic.
        console.log("3. Deploying CollectionFactory logic...");
        factoryImpl = address(new CollectionFactory());
        console.log("   CollectionFactory Implementation:", factoryImpl);

        // 4. ERC1967 proxy + atomic initialize.
        console.log("4. Deploying ERC1967Proxy(CollectionFactory)...");
        bytes memory initData = abi.encodeCall(
            CollectionFactory.initialize, (admin, operator, collection721Impl, collection1155Impl)
        );
        factoryProxy = address(new ERC1967Proxy(factoryImpl, initData));
        console.log("   CollectionFactory Proxy:", factoryProxy);
        console.log("");

        vm.stopBroadcast();

        // Summary — the orchestration shell script greps for these labels.
        console.log("=== Deployment Complete ===");
        console.log("CollectionFactory Proxy:", factoryProxy);
        console.log("CollectionFactory Implementation:", factoryImpl);
        console.log("UserCollection721 Implementation:", collection721Impl);
        console.log("UserCollection1155 Implementation:", collection1155Impl);
        console.log("");
        console.log("Save the proxy address for future upgrades and operator calls.");
    }
}
