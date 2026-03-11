// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ServiceProviderUpgradeable} from "../src/swarms/ServiceProviderUpgradeable.sol";
import {FleetIdentityUpgradeable} from "../src/swarms/FleetIdentityUpgradeable.sol";
import {SwarmRegistryUniversalUpgradeable} from "../src/swarms/SwarmRegistryUniversalUpgradeable.sol";

/**
 * @title DeploySwarmUpgradeableZkSync
 * @notice Deployment script for the upgradeable swarm contracts on ZkSync Era.
 * @dev This script excludes SwarmRegistryL1 which uses SSTORE2 (incompatible with ZkSync).
 *
 * Usage:
 *   forge script script/DeploySwarmUpgradeableZkSync.s.sol --rpc-url $L2_RPC --broadcast --verify --zksync
 *
 * Environment Variables:
 *   - DEPLOYER_PRIVATE_KEY: Private key for deployment
 *   - BOND_TOKEN: Address of the ERC20 bond token
 *   - BASE_BOND: Base bond amount in wei
 *   - OWNER: Owner address for upgrade authorization (defaults to deployer)
 */
contract DeploySwarmUpgradeableZkSync is Script {
    // Deployment artifacts
    address public serviceProviderProxy;
    address public serviceProviderImpl;
    address public fleetIdentityProxy;
    address public fleetIdentityImpl;
    address public swarmRegistryProxy;
    address public swarmRegistryImpl;

    function run() external {
        // Load environment variables
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address bondToken = vm.envAddress("BOND_TOKEN");
        uint256 baseBond = vm.envUint("BASE_BOND");
        uint256 countryMultiplier = vm.envOr("COUNTRY_MULTIPLIER", uint256(0)); // 0 means use the default
        address owner = vm.envOr("OWNER", vm.addr(deployerPrivateKey));

        console.log("=== Deploying Upgradeable Swarm Contracts on ZkSync ===");
        console.log("Bond Token:", bondToken);
        console.log("Base Bond:", baseBond);
        console.log("Owner:", owner);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy ServiceProviderUpgradeable
        console.log("1. Deploying ServiceProviderUpgradeable...");
        serviceProviderImpl = address(new ServiceProviderUpgradeable());
        console.log("   Implementation:", serviceProviderImpl);

        bytes memory serviceProviderInitData =
            abi.encodeWithSelector(ServiceProviderUpgradeable.initialize.selector, owner);
        serviceProviderProxy = address(new ERC1967Proxy(serviceProviderImpl, serviceProviderInitData));
        console.log("   Proxy:", serviceProviderProxy);
        console.log("");

        // 2. Deploy FleetIdentityUpgradeable
        console.log("2. Deploying FleetIdentityUpgradeable...");
        fleetIdentityImpl = address(new FleetIdentityUpgradeable());
        console.log("   Implementation:", fleetIdentityImpl);

        bytes memory fleetIdentityInitData =
            abi.encodeWithSelector(FleetIdentityUpgradeable.initialize.selector, owner, bondToken, baseBond, countryMultiplier);
        fleetIdentityProxy = address(new ERC1967Proxy(fleetIdentityImpl, fleetIdentityInitData));
        console.log("   Proxy:", fleetIdentityProxy);
        console.log("");

        // 3. Deploy SwarmRegistryUniversalUpgradeable
        console.log("3. Deploying SwarmRegistryUniversalUpgradeable...");
        swarmRegistryImpl = address(new SwarmRegistryUniversalUpgradeable());
        console.log("   Implementation:", swarmRegistryImpl);

        bytes memory swarmRegistryInitData = abi.encodeWithSelector(
            SwarmRegistryUniversalUpgradeable.initialize.selector, fleetIdentityProxy, serviceProviderProxy, owner
        );
        swarmRegistryProxy = address(new ERC1967Proxy(swarmRegistryImpl, swarmRegistryInitData));
        console.log("   Proxy:", swarmRegistryProxy);

        vm.stopBroadcast();

        // Summary
        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("ServiceProvider Proxy:", serviceProviderProxy);
        console.log("ServiceProvider Implementation:", serviceProviderImpl);
        console.log("FleetIdentity Proxy:", fleetIdentityProxy);
        console.log("FleetIdentity Implementation:", fleetIdentityImpl);
        console.log("SwarmRegistry Proxy:", swarmRegistryProxy);
        console.log("SwarmRegistry Implementation:", swarmRegistryImpl);
        console.log("");
        console.log("Save these proxy addresses for future upgrades!");
    }
}
