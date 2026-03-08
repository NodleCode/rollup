// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

import {ServiceProviderUpgradeable} from "../src/swarms/ServiceProviderUpgradeable.sol";
import {FleetIdentityUpgradeable} from "../src/swarms/FleetIdentityUpgradeable.sol";
import {SwarmRegistryUniversalUpgradeable} from "../src/swarms/SwarmRegistryUniversalUpgradeable.sol";
import {SwarmRegistryL1Upgradeable} from "../src/swarms/SwarmRegistryL1Upgradeable.sol";

/**
 * @title UpgradeSwarm
 * @notice Script for upgrading deployed swarm contracts to new implementations.
 *
 * @dev **Storage Migration Rules:**
 *      1. Never remove or reorder existing storage variables
 *      2. Only append new variables at the end (reduce __gap accordingly)
 *      3. Never change variable types
 *      4. Use `reinitializer(n)` for version-specific initialization
 *
 * **Pre-Upgrade Checklist:**
 *      1. Run `forge inspect NewContract storageLayout` and compare to V1
 *      2. Ensure all tests pass with new implementation
 *      3. Test upgrade on fork: `forge script ... --fork-url $RPC_URL`
 *      4. Verify new implementation on block explorer
 *
 * Usage:
 *   # Upgrade ServiceProvider
 *   CONTRACT_TYPE=ServiceProvider PROXY_ADDRESS=0x... \
 *     forge script script/UpgradeSwarm.s.sol --rpc-url $RPC_URL --broadcast
 *
 *   # Upgrade FleetIdentity
 *   CONTRACT_TYPE=FleetIdentity PROXY_ADDRESS=0x... \
 *     forge script script/UpgradeSwarm.s.sol --rpc-url $RPC_URL --broadcast
 *
 *   # Upgrade SwarmRegistryUniversal
 *   CONTRACT_TYPE=SwarmRegistryUniversal PROXY_ADDRESS=0x... \
 *     forge script script/UpgradeSwarm.s.sol --rpc-url $RPC_URL --broadcast
 *
 *   # Upgrade SwarmRegistryL1
 *   CONTRACT_TYPE=SwarmRegistryL1 PROXY_ADDRESS=0x... \
 *     forge script script/UpgradeSwarm.s.sol --rpc-url $RPC_URL --broadcast
 *
 * Environment Variables:
 *   - DEPLOYER_PRIVATE_KEY: Private key of contract owner
 *   - PROXY_ADDRESS: Address of the proxy to upgrade
 *   - CONTRACT_TYPE: One of "ServiceProvider", "FleetIdentity", "SwarmRegistryUniversal", "SwarmRegistryL1"
 *   - REINIT_DATA: Optional ABI-encoded data for reinitializer call (e.g., for V2 migration)
 */
contract UpgradeSwarm is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address proxyAddress = vm.envAddress("PROXY_ADDRESS");
        string memory contractType = vm.envString("CONTRACT_TYPE");
        bytes memory reinitData = vm.envOr("REINIT_DATA", bytes(""));

        console.log("=== Upgrading Swarm Contract ===");
        console.log("Contract Type:", contractType);
        console.log("Proxy Address:", proxyAddress);
        console.log("Has Reinit Data:", reinitData.length > 0);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        address newImpl;

        if (keccak256(bytes(contractType)) == keccak256("ServiceProvider")) {
            newImpl = _upgradeServiceProvider(proxyAddress, reinitData);
        } else if (keccak256(bytes(contractType)) == keccak256("FleetIdentity")) {
            newImpl = _upgradeFleetIdentity(proxyAddress, reinitData);
        } else if (keccak256(bytes(contractType)) == keccak256("SwarmRegistryUniversal")) {
            newImpl = _upgradeSwarmRegistryUniversal(proxyAddress, reinitData);
        } else if (keccak256(bytes(contractType)) == keccak256("SwarmRegistryL1")) {
            newImpl = _upgradeSwarmRegistryL1(proxyAddress, reinitData);
        } else {
            revert("Invalid CONTRACT_TYPE. Use: ServiceProvider, FleetIdentity, SwarmRegistryUniversal, SwarmRegistryL1");
        }

        vm.stopBroadcast();

        console.log("");
        console.log("=== Upgrade Complete ===");
        console.log("New Implementation:", newImpl);
        console.log("Proxy (unchanged):", proxyAddress);
    }

    function _upgradeServiceProvider(address proxy, bytes memory reinitData) internal returns (address impl) {
        console.log("Deploying new ServiceProviderUpgradeable implementation...");
        impl = address(new ServiceProviderUpgradeable());
        console.log("New implementation:", impl);

        ServiceProviderUpgradeable proxyContract = ServiceProviderUpgradeable(proxy);

        if (reinitData.length > 0) {
            console.log("Calling upgradeToAndCall with reinitializer...");
            proxyContract.upgradeToAndCall(impl, reinitData);
        } else {
            console.log("Calling upgradeToAndCall...");
            proxyContract.upgradeToAndCall(impl, "");
        }
    }

    function _upgradeFleetIdentity(address proxy, bytes memory reinitData) internal returns (address impl) {
        console.log("Deploying new FleetIdentityUpgradeable implementation...");
        impl = address(new FleetIdentityUpgradeable());
        console.log("New implementation:", impl);

        FleetIdentityUpgradeable proxyContract = FleetIdentityUpgradeable(proxy);

        if (reinitData.length > 0) {
            console.log("Calling upgradeToAndCall with reinitializer...");
            proxyContract.upgradeToAndCall(impl, reinitData);
        } else {
            console.log("Calling upgradeToAndCall...");
            proxyContract.upgradeToAndCall(impl, "");
        }
    }

    function _upgradeSwarmRegistryUniversal(address proxy, bytes memory reinitData) internal returns (address impl) {
        console.log("Deploying new SwarmRegistryUniversalUpgradeable implementation...");
        impl = address(new SwarmRegistryUniversalUpgradeable());
        console.log("New implementation:", impl);

        SwarmRegistryUniversalUpgradeable proxyContract = SwarmRegistryUniversalUpgradeable(proxy);

        if (reinitData.length > 0) {
            console.log("Calling upgradeToAndCall with reinitializer...");
            proxyContract.upgradeToAndCall(impl, reinitData);
        } else {
            console.log("Calling upgradeToAndCall...");
            proxyContract.upgradeToAndCall(impl, "");
        }
    }

    function _upgradeSwarmRegistryL1(address proxy, bytes memory reinitData) internal returns (address impl) {
        console.log("Deploying new SwarmRegistryL1Upgradeable implementation...");
        impl = address(new SwarmRegistryL1Upgradeable());
        console.log("New implementation:", impl);

        SwarmRegistryL1Upgradeable proxyContract = SwarmRegistryL1Upgradeable(proxy);

        if (reinitData.length > 0) {
            console.log("Calling upgradeToAndCall with reinitializer...");
            proxyContract.upgradeToAndCall(impl, reinitData);
        } else {
            console.log("Calling upgradeToAndCall...");
            proxyContract.upgradeToAndCall(impl, "");
        }
    }
}

/**
 * @title ExampleV2Migration
 * @notice Example of how to add a V2 reinitializer function and migrate storage.
 *
 * @dev When you need to add new storage to an existing contract:
 *
 *      1. Add new storage variables ABOVE the __gap (reduce gap size accordingly)
 *      2. Add a reinitializer function:
 *
 *         ```solidity
 *         function initializeV2(uint256 newParam) external reinitializer(2) {
 *             _newParamIntroducedInV2 = newParam;
 *         }
 *         ```
 *
 *      3. Generate reinit calldata:
 *         ```bash
 *         cast calldata "initializeV2(uint256)" 12345
 *         ```
 *
 *      4. Pass to upgrade script:
 *         ```bash
 *         REINIT_DATA=0x... forge script ...
 *         ```
 *
 * Example V2 contract structure (do not deploy this, it's documentation):
 *
 * contract ServiceProviderUpgradeableV2 is ServiceProviderUpgradeable {
 *     // New V2 storage - add ABOVE __gap
 *     mapping(uint256 => uint256) public providerScores;
 *
 *     // Reduce __gap from 49 to 48 (added 1 slot)
 *     uint256[48] private __gap;
 *
 *     // V2 reinitializer
 *     function initializeV2() external reinitializer(2) {
 *         // Initialize any V2-specific state here
 *     }
 *
 *     // New V2 functions
 *     function setProviderScore(uint256 tokenId, uint256 score) external {
 *         if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
 *         providerScores[tokenId] = score;
 *     }
 * }
 */
contract ExampleV2Migration {
    // This contract is documentation only
}
