// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ServiceProviderUpgradeable} from "../src/swarms/ServiceProviderUpgradeable.sol";
import {FleetIdentityUpgradeable} from "../src/swarms/FleetIdentityUpgradeable.sol";
import {SwarmRegistryUniversalUpgradeable} from "../src/swarms/SwarmRegistryUniversalUpgradeable.sol";
import {BondTreasuryPaymaster} from "../src/paymasters/BondTreasuryPaymaster.sol";

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
 *   - COUNTRY_MULTIPLIER: (optional) Country multiplier for bond calculation (0 = use default)
 *   - L2_ADMIN: Owner address for all deployed L2 contracts (ZkSync Safe multisig)
 *   - PAYMASTER_WITHDRAWER: (optional) Address allowed to withdraw tokens from paymaster (defaults to L2_ADMIN)
 *   - BOND_QUOTA: (optional) Max bond amount sponsorable per period in wei (defaults to 100k NODL)
 *   - BOND_PERIOD: (optional) Quota renewal period in seconds (defaults to 1 day)
 *   - FLEET_OPERATOR: Address of the Nodle swarm operator (initial whitelisted user)
 */
contract DeploySwarmUpgradeableZkSync is Script {
    // Deployment artifacts
    address public serviceProviderProxy;
    address public serviceProviderImpl;
    address public fleetIdentityProxy;
    address public fleetIdentityImpl;
    address public swarmRegistryProxy;
    address public swarmRegistryImpl;
    address public bondTreasuryPaymaster;

    function run() external {
        // Load environment variables
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address bondToken = vm.envAddress("BOND_TOKEN");
        uint256 baseBond = vm.envUint("BASE_BOND");
        uint256 countryMultiplier = vm.envOr("COUNTRY_MULTIPLIER", uint256(0)); // 0 means use the default
        address owner = vm.envAddress("L2_ADMIN");
        address withdrawer = vm.envOr("PAYMASTER_WITHDRAWER", owner);
        uint256 bondQuota = vm.envOr("BOND_QUOTA", uint256(100_000 ether)); // 100k NODL default
        uint256 bondPeriod = vm.envOr("BOND_PERIOD", uint256(1 days));
        address fleetOperator = vm.envAddress("FLEET_OPERATOR");

        console.log("=== Deploying Upgradeable Swarm Contracts on ZkSync ===");
        console.log("Bond Token:", bondToken);
        console.log("Base Bond:", baseBond);
        console.log("Owner:", owner);
        console.log("Withdrawer:", withdrawer);
        console.log("Bond Quota:", bondQuota);
        console.log("Bond Period:", bondPeriod);
        console.log("Fleet Operator:", fleetOperator);
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

        bytes memory fleetIdentityInitData = abi.encodeWithSelector(
            FleetIdentityUpgradeable.initialize.selector, owner, bondToken, baseBond, countryMultiplier
        );
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

        // 4. Deploy BondTreasuryPaymaster
        console.log("4. Deploying BondTreasuryPaymaster...");
        address[] memory whitelistedContracts = new address[](3);
        whitelistedContracts[0] = fleetIdentityProxy;
        whitelistedContracts[1] = serviceProviderProxy;
        whitelistedContracts[2] = swarmRegistryProxy;
        address[] memory whitelistedUsers = new address[](1);
        whitelistedUsers[0] = fleetOperator;
        bondTreasuryPaymaster = address(
            new BondTreasuryPaymaster(
                owner,
                fleetOperator,
                withdrawer,
                whitelistedContracts,
                whitelistedUsers,
                bondToken,
                bondQuota,
                bondPeriod
            )
        );
        console.log("   Address:", bondTreasuryPaymaster);
        console.log("");

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
        console.log("BondTreasuryPaymaster:", bondTreasuryPaymaster);
        console.log("");
        console.log("Save these proxy addresses for future upgrades!");
        console.log(
            "NOTE: Fund BondTreasuryPaymaster with bond tokens and whitelist users before sponsored claims work."
        );
    }
}
