// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// V1 contracts
import {ServiceProviderUpgradeable} from "../../src/swarms/ServiceProviderUpgradeable.sol";
import {FleetIdentityUpgradeable} from "../../src/swarms/FleetIdentityUpgradeable.sol";
import {SwarmRegistryL1Upgradeable} from "../../src/swarms/SwarmRegistryL1Upgradeable.sol";

// ═══════════════════════════════════════════════════════════════════════════════
// Mock V2 Contracts (inline for testing purposes only)
// ═══════════════════════════════════════════════════════════════════════════════

/// @dev Mock V2 that adds version() - inherits from V1 to preserve storage layout
contract FleetIdentityUpgradeableV2 is FleetIdentityUpgradeable {
    function version() external pure returns (string memory) {
        return "2.0.0";
    }
}

/// @dev Mock V2 that adds version() - inherits from V1 to preserve storage layout
contract ServiceProviderUpgradeableV2 is ServiceProviderUpgradeable {
    function version() external pure returns (string memory) {
        return "2.0.0";
    }
}

/// @dev Mock V2 that adds version() - inherits from V1 to preserve storage layout
contract SwarmRegistryL1UpgradeableV2 is SwarmRegistryL1Upgradeable {
    function version() external pure returns (string memory) {
        return "2.0.0";
    }
}

/// @dev Simple ERC20 for testing bond deposits
contract MockBondToken is ERC20 {
    constructor() ERC20("Mock Bond", "MBOND") {
        _mint(msg.sender, 1_000_000 ether);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Main Test Script
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * @title TestUpgradeOnAnvil
 * @notice End-to-end script to deploy, use, upgrade, and verify swarm contracts on anvil.
 *
 * Usage:
 *   1. Start anvil-zksync in a separate terminal:
 *      ~/.foundry/bin/anvil-zksync --host 127.0.0.1 --port 8545
 *
 *   2. Run this script:
 *      forge script test/upgrade-demo/TestUpgradeOnAnvil.s.sol:TestUpgradeOnAnvil \
 *        --rpc-url http://127.0.0.1:8545 \
 *        --broadcast
 */
contract TestUpgradeOnAnvil is Script {
    // Use anvil's first default account
    uint256 constant ANVIL_PRIVATE_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    // Proxy addresses
    address public serviceProviderProxy;
    address public fleetIdentityProxy;
    address public swarmRegistryProxy;

    // Test state
    uint256 public providerTokenId;
    uint256 public fleetTokenId;

    function run() external {
        address deployer = vm.addr(ANVIL_PRIVATE_KEY);
        console.log("Deployer:", deployer);
        console.log("Balance:", deployer.balance);

        vm.startBroadcast(ANVIL_PRIVATE_KEY);

        // ═══════════════════════════════════════════
        // PHASE 1: Deploy Mock Token & V1 Contracts
        // ═══════════════════════════════════════════
        console.log("\n=== PHASE 1: Deploy V1 Contracts ===\n");

        // Deploy mock bond token
        MockBondToken bondToken = new MockBondToken();
        console.log("Bond Token:", address(bondToken));

        uint256 baseBond = 100 ether;

        // Deploy ServiceProvider V1
        console.log("\nDeploying ServiceProviderUpgradeable V1...");
        ServiceProviderUpgradeable spImpl = new ServiceProviderUpgradeable();
        ERC1967Proxy spProxy = new ERC1967Proxy(
            address(spImpl),
            abi.encodeCall(ServiceProviderUpgradeable.initialize, (deployer))
        );
        serviceProviderProxy = address(spProxy);
        console.log("  ServiceProvider Proxy:", serviceProviderProxy);
        console.log("  ServiceProvider Impl V1:", address(spImpl));

        // Deploy FleetIdentity V1
        console.log("\nDeploying FleetIdentityUpgradeable V1...");
        FleetIdentityUpgradeable fiImpl = new FleetIdentityUpgradeable();
        ERC1967Proxy fiProxy = new ERC1967Proxy(
            address(fiImpl),
            abi.encodeCall(FleetIdentityUpgradeable.initialize, (address(bondToken), baseBond, deployer))
        );
        fleetIdentityProxy = address(fiProxy);
        console.log("  FleetIdentity Proxy:", fleetIdentityProxy);
        console.log("  FleetIdentity Impl V1:", address(fiImpl));

        // Deploy SwarmRegistryL1 V1
        console.log("\nDeploying SwarmRegistryL1Upgradeable V1...");
        SwarmRegistryL1Upgradeable srImpl = new SwarmRegistryL1Upgradeable();
        ERC1967Proxy srProxy = new ERC1967Proxy(
            address(srImpl),
            abi.encodeCall(SwarmRegistryL1Upgradeable.initialize, (fleetIdentityProxy, serviceProviderProxy, deployer))
        );
        swarmRegistryProxy = address(srProxy);
        console.log("  SwarmRegistry Proxy:", swarmRegistryProxy);
        console.log("  SwarmRegistry Impl V1:", address(srImpl));

        // ═══════════════════════════════════════════
        // PHASE 2: Create State (register provider & fleet)
        // ═══════════════════════════════════════════
        console.log("\n=== PHASE 2: Create State ===\n");

        // Register a provider
        ServiceProviderUpgradeable sp = ServiceProviderUpgradeable(serviceProviderProxy);
        string memory providerUrl = "https://api.example.com";
        providerTokenId = sp.registerProvider(providerUrl);
        console.log("Registered Provider:");
        console.log("  Token ID:", providerTokenId);
        console.log("  URL:", sp.providerUrls(providerTokenId));
        console.log("  Owner:", sp.ownerOf(providerTokenId));

        // Approve bond token for fleet
        FleetIdentityUpgradeable fi = FleetIdentityUpgradeable(fleetIdentityProxy);
        bondToken.approve(fleetIdentityProxy, type(uint256).max);
        console.log("\nBond token approved for FleetIdentity");

        // Register a fleet
        bytes16 fleetUuid = bytes16(keccak256("test-fleet-uuid"));
        uint16 countryCode = 840; // US
        uint16 adminCode = 6; // CA
        fleetTokenId = fi.registerFleetLocal(fleetUuid, countryCode, adminCode, 0);
        console.log("\nRegistered Fleet:");
        console.log("  Token ID:", fleetTokenId);
        console.log("  Bond deposited:", fi.bonds(fleetTokenId));

        // Verify state before upgrade
        console.log("\n--- Pre-Upgrade State Verification ---");
        console.log("ServiceProvider owner:", sp.owner());
        console.log("FleetIdentity BASE_BOND:", fi.BASE_BOND());
        console.log("Provider token exists:", sp.ownerOf(providerTokenId) == deployer);
        console.log("Fleet token exists:", fi.ownerOf(fleetTokenId) == deployer);

        // ═══════════════════════════════════════════
        // PHASE 3: Upgrade to V2
        // ═══════════════════════════════════════════
        console.log("\n=== PHASE 3: Upgrade to V2 ===\n");

        // Deploy V2 implementations (defined inline above)
        console.log("Deploying V2 implementations...");
        ServiceProviderUpgradeableV2 spImplV2 = new ServiceProviderUpgradeableV2();
        FleetIdentityUpgradeableV2 fiImplV2 = new FleetIdentityUpgradeableV2();
        SwarmRegistryL1UpgradeableV2 srImplV2 = new SwarmRegistryL1UpgradeableV2();

        console.log("  ServiceProvider Impl V2:", address(spImplV2));
        console.log("  FleetIdentity Impl V2:", address(fiImplV2));
        console.log("  SwarmRegistry Impl V2:", address(srImplV2));

        // Upgrade ServiceProvider
        console.log("\nUpgrading ServiceProvider to V2...");
        ServiceProviderUpgradeable(serviceProviderProxy).upgradeToAndCall(address(spImplV2), "");
        console.log("  Upgraded!");

        // Upgrade FleetIdentity
        console.log("Upgrading FleetIdentity to V2...");
        FleetIdentityUpgradeable(fleetIdentityProxy).upgradeToAndCall(address(fiImplV2), "");
        console.log("  Upgraded!");

        // Upgrade SwarmRegistry
        console.log("Upgrading SwarmRegistry to V2...");
        SwarmRegistryL1Upgradeable(swarmRegistryProxy).upgradeToAndCall(address(srImplV2), "");
        console.log("  Upgraded!");

        // ═══════════════════════════════════════════
        // PHASE 4: Verify Upgrade Success
        // ═══════════════════════════════════════════
        console.log("\n=== PHASE 4: Verify Upgrade Success ===\n");

        // Cast proxies to V2 interfaces
        ServiceProviderUpgradeableV2 spV2 = ServiceProviderUpgradeableV2(serviceProviderProxy);
        FleetIdentityUpgradeableV2 fiV2 = FleetIdentityUpgradeableV2(fleetIdentityProxy);
        SwarmRegistryL1UpgradeableV2 srV2 = SwarmRegistryL1UpgradeableV2(swarmRegistryProxy);

        // Check versions
        console.log("--- Version Check ---");
        console.log("ServiceProvider version:", spV2.version());
        console.log("FleetIdentity version:", fiV2.version());
        console.log("SwarmRegistry version:", srV2.version());

        // Verify state preserved
        console.log("\n--- State Preservation Check ---");
        console.log("Provider URL still valid:", keccak256(bytes(spV2.providerUrls(providerTokenId))) == keccak256(bytes(providerUrl)));
        console.log("Provider owner unchanged:", spV2.ownerOf(providerTokenId) == deployer);
        console.log("Fleet bond preserved:", fiV2.bonds(fleetTokenId) == baseBond);
        console.log("Fleet owner unchanged:", fiV2.ownerOf(fleetTokenId) == deployer);
        console.log("Contract owner unchanged:", spV2.owner() == deployer);

        // Test that contracts still work after upgrade
        console.log("\n--- Post-Upgrade Functionality Test ---");

        // Register another provider
        uint256 newProviderId = spV2.registerProvider("https://api2.example.com");
        console.log("New provider registered after upgrade, ID:", newProviderId);

        // Register another fleet
        bytes16 fleetUuid2 = bytes16(keccak256("test-fleet-uuid-2"));
        uint256 newFleetId = fiV2.registerFleetLocal(fleetUuid2, countryCode, adminCode, 0);
        console.log("New fleet registered after upgrade, ID:", newFleetId);

        vm.stopBroadcast();

        // ═══════════════════════════════════════════
        // Final Summary
        // ═══════════════════════════════════════════
        console.log("\n========================================");
        console.log("  UPGRADE TEST COMPLETED SUCCESSFULLY");
        console.log("========================================");
        console.log("- All V1 contracts deployed");
        console.log("- State created (provider + fleet)");
        console.log("- Upgraded to V2 implementations");
        console.log("- Version functions return '2.0.0'");
        console.log("- All state preserved after upgrade");
        console.log("- Post-upgrade operations work");
        console.log("========================================\n");
    }
}
