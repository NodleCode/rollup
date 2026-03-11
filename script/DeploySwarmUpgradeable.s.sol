// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ServiceProviderUpgradeable} from "../src/swarms/ServiceProviderUpgradeable.sol";
import {FleetIdentityUpgradeable} from "../src/swarms/FleetIdentityUpgradeable.sol";
import {SwarmRegistryL1Upgradeable} from "../src/swarms/SwarmRegistryL1Upgradeable.sol";

/**
 * @title DeploySwarmUpgradeableL1
 * @notice Deployment script for the upgradeable swarm contracts on Ethereum L1.
 * @dev This script deploys SwarmRegistryL1 which uses SSTORE2 for storage proofs.
 *      SSTORE2 relies on EXTCODECOPY which is NOT supported on ZkSync Era.
 *      For ZkSync deployments, use DeploySwarmUpgradeableZkSync.s.sol instead.
 *
 * Deploy order matters due to dependencies:
 *      1. ServiceProviderUpgradeable (no dependencies)
 *      2. FleetIdentityUpgradeable (depends on bond token)
 *      3. SwarmRegistryL1Upgradeable (depends on 1 & 2)
 *
 * Usage:
 *   # Dry run (simulation)
 *   forge script script/DeploySwarmUpgradeable.s.sol --rpc-url $L1_RPC
 *
 *   # Deploy with broadcast
 *   forge script script/DeploySwarmUpgradeable.s.sol --rpc-url $L1_RPC --broadcast --verify
 *
 * Environment Variables:
 *   - DEPLOYER_PRIVATE_KEY: Private key for deployment
 *   - BOND_TOKEN: Address of the ERC20 bond token
 *   - BASE_BOND: Base bond amount in wei
 *   - OWNER: Owner address for upgrade authorization (defaults to deployer)
 */
contract DeploySwarmUpgradeableL1 is Script {
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

        console.log("=== Deploying Upgradeable Swarm Contracts (L1) ===");
        console.log("Bond Token:", bondToken);
        console.log("Base Bond:", baseBond);
        console.log("Owner:", owner);
        console.log("Registry Type: L1 (SSTORE2)");
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

        // 3. Deploy SwarmRegistryL1Upgradeable
        console.log("3. Deploying SwarmRegistryL1Upgradeable...");
        swarmRegistryImpl = address(new SwarmRegistryL1Upgradeable());
        console.log("   Implementation:", swarmRegistryImpl);

        bytes memory swarmRegistryInitData = abi.encodeWithSelector(
            SwarmRegistryL1Upgradeable.initialize.selector, fleetIdentityProxy, serviceProviderProxy, owner
        );
        swarmRegistryProxy = address(new ERC1967Proxy(swarmRegistryImpl, swarmRegistryInitData));
        console.log("   Proxy:", swarmRegistryProxy);

        vm.stopBroadcast();

        // Summary - format matches shell script expectations for address parsing
        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("ServiceProvider Implementation:", serviceProviderImpl);
        console.log("ServiceProvider Proxy:", serviceProviderProxy);
        console.log("FleetIdentity Implementation:", fleetIdentityImpl);
        console.log("FleetIdentity Proxy:", fleetIdentityProxy);
        console.log("SwarmRegistry Implementation:", swarmRegistryImpl);
        console.log("SwarmRegistry Proxy:", swarmRegistryProxy);
        console.log("");
        console.log("Save these proxy addresses for future upgrades!");
    }
}
