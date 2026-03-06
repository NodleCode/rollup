// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ServiceProviderUpgradeable} from "../../src/swarms/ServiceProviderUpgradeable.sol";
import {FleetIdentityUpgradeable} from "../../src/swarms/FleetIdentityUpgradeable.sol";
import {SwarmRegistryUniversalUpgradeable} from "../../src/swarms/SwarmRegistryUniversalUpgradeable.sol";

import {MockERC20} from "../__helpers__/MockERC20.sol";

/**
 * @title ServiceProviderUpgradeableV2Mock
 * @notice Mock V2 implementation for testing upgrades
 */
contract ServiceProviderUpgradeableV2Mock is ServiceProviderUpgradeable {
    // New V2 storage
    mapping(uint256 => uint256) public providerScores;
    uint256 public v2InitializedAt;

    // Reduce gap from 49 to 47 (added 2 slots)
    uint256[47] private __gap_v2;

    function initializeV2() external reinitializer(2) {
        v2InitializedAt = block.timestamp;
    }

    function setProviderScore(uint256 tokenId, uint256 score) external {
        if (ownerOf(tokenId) != msg.sender) revert("Not owner");
        providerScores[tokenId] = score;
    }

    function version() external pure returns (string memory) {
        return "V2";
    }
}

/**
 * @title FleetIdentityUpgradeableV2Mock
 * @notice Mock V2 implementation for testing upgrades
 */
contract FleetIdentityUpgradeableV2Mock is FleetIdentityUpgradeable {
    // New V2 storage
    mapping(uint256 => string) public fleetMetadata;
    uint256 public v2InitializedAt;

    // Reduce gap from 40 to 38 (added 2 slots)
    uint256[38] private __gap_v2;

    function initializeV2() external reinitializer(2) {
        v2InitializedAt = block.timestamp;
    }

    function setFleetMetadata(uint256 tokenId, string calldata metadata) external {
        if (ownerOf(tokenId) != msg.sender) revert("Not owner");
        fleetMetadata[tokenId] = metadata;
    }

    function version() external pure returns (string memory) {
        return "V2";
    }
}

/**
 * @title SwarmRegistryUniversalUpgradeableV2Mock
 * @notice Mock V2 implementation for testing upgrades
 */
contract SwarmRegistryUniversalUpgradeableV2Mock is SwarmRegistryUniversalUpgradeable {
    // New V2 storage
    mapping(bytes32 => bool) public swarmPaused;
    uint256 public v2InitializedAt;

    // Reduce gap from 44 to 42 (added 2 slots)
    uint256[42] private __gap_v2;

    function initializeV2() external reinitializer(2) {
        v2InitializedAt = block.timestamp;
    }

    function pauseSwarm(bytes32 swarmId) external {
        swarmPaused[swarmId] = true;
    }

    function version() external pure returns (string memory) {
        return "V2";
    }
}

/**
 * @title UpgradeableContractsTest
 * @notice Tests for UUPS upgradeable swarm contracts
 */
contract UpgradeableContractsTest is Test {
    // Contracts
    ServiceProviderUpgradeable public serviceProviderImpl;
    ServiceProviderUpgradeable public serviceProvider;
    address public serviceProviderProxy;

    FleetIdentityUpgradeable public fleetIdentityImpl;
    FleetIdentityUpgradeable public fleetIdentity;
    address public fleetIdentityProxy;

    SwarmRegistryUniversalUpgradeable public swarmRegistryImpl;
    SwarmRegistryUniversalUpgradeable public swarmRegistry;
    address public swarmRegistryProxy;

    // Mock token
    MockERC20 public bondToken;

    // Actors
    address public owner = address(0x1111);
    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);
    address public attacker = address(0xBAD);

    // Constants
    uint256 constant BASE_BOND = 1000e18;

    function setUp() public {
        // Deploy mock token
        bondToken = new MockERC20("Mock Token", "MOCK", 18);
        bondToken.mint(alice, 1_000_000e18);
        bondToken.mint(bob, 1_000_000e18);

        // Deploy ServiceProvider
        serviceProviderImpl = new ServiceProviderUpgradeable();
        serviceProviderProxy = address(
            new ERC1967Proxy(
                address(serviceProviderImpl),
                abi.encodeCall(ServiceProviderUpgradeable.initialize, (owner))
            )
        );
        serviceProvider = ServiceProviderUpgradeable(serviceProviderProxy);

        // Deploy FleetIdentity
        fleetIdentityImpl = new FleetIdentityUpgradeable();
        fleetIdentityProxy = address(
            new ERC1967Proxy(
                address(fleetIdentityImpl),
                abi.encodeCall(FleetIdentityUpgradeable.initialize, (owner, address(bondToken), BASE_BOND, 0))
            )
        );
        fleetIdentity = FleetIdentityUpgradeable(fleetIdentityProxy);

        // Deploy SwarmRegistry
        swarmRegistryImpl = new SwarmRegistryUniversalUpgradeable();
        swarmRegistryProxy = address(
            new ERC1967Proxy(
                address(swarmRegistryImpl),
                abi.encodeCall(
                    SwarmRegistryUniversalUpgradeable.initialize,
                    (fleetIdentityProxy, serviceProviderProxy, owner)
                )
            )
        );
        swarmRegistry = SwarmRegistryUniversalUpgradeable(swarmRegistryProxy);
    }

    // =========================================================================
    // ServiceProvider Initialization Tests
    // =========================================================================

    function test_ServiceProvider_InitializesCorrectly() public view {
        assertEq(serviceProvider.owner(), owner);
        assertEq(serviceProvider.name(), "Swarm Service Provider");
        assertEq(serviceProvider.symbol(), "SSV");
    }

    function test_ServiceProvider_CannotReinitialize() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        serviceProvider.initialize(attacker);
    }

    function test_ServiceProvider_ImplementationCannotBeInitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        serviceProviderImpl.initialize(attacker);
    }

    // =========================================================================
    // ServiceProvider Upgrade Tests
    // =========================================================================

    function test_ServiceProvider_OwnerCanUpgrade() public {
        // Create some state before upgrade
        vm.startPrank(alice);
        uint256 tokenId = serviceProvider.registerProvider("https://alice.example.com/api");
        vm.stopPrank();

        // Deploy V2 and upgrade
        ServiceProviderUpgradeableV2Mock v2Impl = new ServiceProviderUpgradeableV2Mock();

        vm.prank(owner);
        serviceProvider.upgradeToAndCall(
            address(v2Impl), abi.encodeCall(ServiceProviderUpgradeableV2Mock.initializeV2, ())
        );

        // Verify upgrade
        ServiceProviderUpgradeableV2Mock v2 = ServiceProviderUpgradeableV2Mock(serviceProviderProxy);
        assertEq(v2.version(), "V2");
        assertGt(v2.v2InitializedAt(), 0);

        // Verify old state preserved
        assertEq(v2.ownerOf(tokenId), alice);
        assertEq(v2.providerUrls(tokenId), "https://alice.example.com/api");

        // New V2 functionality works
        vm.prank(alice);
        v2.setProviderScore(tokenId, 100);
        assertEq(v2.providerScores(tokenId), 100);
    }

    function test_ServiceProvider_NonOwnerCannotUpgrade() public {
        ServiceProviderUpgradeableV2Mock v2Impl = new ServiceProviderUpgradeableV2Mock();

        vm.prank(attacker);
        vm.expectRevert();
        serviceProvider.upgradeToAndCall(address(v2Impl), "");
    }

    function test_ServiceProvider_StoragePersistsAfterUpgrade() public {
        // Create multiple tokens
        vm.startPrank(alice);
        uint256 aliceToken = serviceProvider.registerProvider("https://alice.example.com");
        vm.stopPrank();

        vm.startPrank(bob);
        uint256 bobToken = serviceProvider.registerProvider("https://bob.example.com");
        vm.stopPrank();

        // Upgrade
        ServiceProviderUpgradeableV2Mock v2Impl = new ServiceProviderUpgradeableV2Mock();
        vm.prank(owner);
        serviceProvider.upgradeToAndCall(address(v2Impl), "");

        ServiceProviderUpgradeableV2Mock v2 = ServiceProviderUpgradeableV2Mock(serviceProviderProxy);

        // Verify all state
        assertEq(v2.ownerOf(aliceToken), alice);
        assertEq(v2.ownerOf(bobToken), bob);
        assertEq(v2.providerUrls(aliceToken), "https://alice.example.com");
        assertEq(v2.providerUrls(bobToken), "https://bob.example.com");
        assertEq(v2.owner(), owner);
    }

    // =========================================================================
    // FleetIdentity Initialization Tests
    // =========================================================================

    function test_FleetIdentity_InitializesCorrectly() public view {
        assertEq(fleetIdentity.owner(), owner);
        assertEq(address(fleetIdentity.BOND_TOKEN()), address(bondToken));
        assertEq(fleetIdentity.BASE_BOND(), BASE_BOND);
        assertEq(fleetIdentity.name(), "Swarm Fleet Identity");
        assertEq(fleetIdentity.symbol(), "SFID");
    }

    function test_FleetIdentity_CannotReinitialize() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        fleetIdentity.initialize(attacker, address(bondToken), BASE_BOND, 0);
    }

    function test_FleetIdentity_ImplementationCannotBeInitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        fleetIdentityImpl.initialize(attacker, address(bondToken), BASE_BOND, 0);
    }

    // =========================================================================
    // FleetIdentity Upgrade Tests
    // =========================================================================

    function test_FleetIdentity_OwnerCanUpgrade() public {
        // Approve and claim a UUID (simplest operation)
        vm.startPrank(alice);
        bondToken.approve(address(fleetIdentity), BASE_BOND);
        bytes16 uuid1 = bytes16(keccak256("test-fleet-1"));
        uint256 tokenId = fleetIdentity.claimUuid(uuid1, address(0));
        vm.stopPrank();

        // Deploy V2 and upgrade
        FleetIdentityUpgradeableV2Mock v2Impl = new FleetIdentityUpgradeableV2Mock();

        vm.prank(owner);
        fleetIdentity.upgradeToAndCall(address(v2Impl), abi.encodeCall(FleetIdentityUpgradeableV2Mock.initializeV2, ()));

        // Verify upgrade
        FleetIdentityUpgradeableV2Mock v2 = FleetIdentityUpgradeableV2Mock(fleetIdentityProxy);
        assertEq(v2.version(), "V2");
        assertGt(v2.v2InitializedAt(), 0);

        // Verify old state preserved
        assertEq(v2.ownerOf(tokenId), alice);

        // Both old and new functionality work
        vm.prank(alice);
        v2.setFleetMetadata(tokenId, "metadata://test");
        assertEq(v2.fleetMetadata(tokenId), "metadata://test");
    }

    function test_FleetIdentity_NonOwnerCannotUpgrade() public {
        FleetIdentityUpgradeableV2Mock v2Impl = new FleetIdentityUpgradeableV2Mock();

        vm.prank(attacker);
        vm.expectRevert();
        fleetIdentity.upgradeToAndCall(address(v2Impl), "");
    }

    function test_FleetIdentity_BondStatePersistsAfterUpgrade() public {
        // Claim UUIDs (each costs BASE_BOND)
        vm.startPrank(alice);
        bondToken.approve(address(fleetIdentity), BASE_BOND * 2);
        bytes16 uuid1 = bytes16(keccak256("fleet-1"));
        bytes16 uuid2 = bytes16(keccak256("fleet-2"));
        uint256 token1 = fleetIdentity.claimUuid(uuid1, address(0));
        uint256 token2 = fleetIdentity.claimUuid(uuid2, address(0));
        vm.stopPrank();

        uint256 bond1 = fleetIdentity.bonds(token1);
        uint256 bond2 = fleetIdentity.bonds(token2);

        // Upgrade
        FleetIdentityUpgradeableV2Mock v2Impl = new FleetIdentityUpgradeableV2Mock();
        vm.prank(owner);
        fleetIdentity.upgradeToAndCall(address(v2Impl), "");

        FleetIdentityUpgradeableV2Mock v2 = FleetIdentityUpgradeableV2Mock(fleetIdentityProxy);

        // Verify bonds match
        assertEq(v2.bonds(token1), bond1);
        assertEq(v2.bonds(token2), bond2);
        assertEq(address(v2.BOND_TOKEN()), address(bondToken));
        assertEq(v2.BASE_BOND(), BASE_BOND);
    }

    // =========================================================================
    // SwarmRegistry Initialization Tests
    // =========================================================================

    function test_SwarmRegistry_InitializesCorrectly() public view {
        assertEq(swarmRegistry.owner(), owner);
        assertEq(address(swarmRegistry.FLEET_CONTRACT()), fleetIdentityProxy);
        assertEq(address(swarmRegistry.PROVIDER_CONTRACT()), serviceProviderProxy);
    }

    function test_SwarmRegistry_CannotReinitialize() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        swarmRegistry.initialize(address(fleetIdentity), address(serviceProvider), attacker);
    }

    function test_SwarmRegistry_ImplementationCannotBeInitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        swarmRegistryImpl.initialize(address(fleetIdentity), address(serviceProvider), attacker);
    }

    // =========================================================================
    // SwarmRegistry Upgrade Tests
    // =========================================================================

    function test_SwarmRegistry_OwnerCanUpgrade() public {
        // Claim UUID first to get a fleet ID
        vm.startPrank(alice);
        bondToken.approve(address(fleetIdentity), BASE_BOND);
        bytes16 uuid = bytes16(keccak256("swarm-test-fleet"));
        uint256 fleetId = fleetIdentity.claimUuid(uuid, address(0));
        vm.stopPrank();

        vm.startPrank(bob);
        uint256 providerId = serviceProvider.registerProvider("https://bob.example.com");
        vm.stopPrank();

        // Register swarm with correct parameters
        bytes memory filterData = hex"0102030405";
        uint8 fingerprintSize = 16;
        SwarmRegistryUniversalUpgradeable.TagType tagType = SwarmRegistryUniversalUpgradeable.TagType.IBEACON_PAYLOAD_ONLY;
        
        vm.prank(alice);
        uint256 swarmId = swarmRegistry.registerSwarm(uuid, providerId, filterData, fingerprintSize, tagType);

        // Deploy V2 and upgrade
        SwarmRegistryUniversalUpgradeableV2Mock v2Impl = new SwarmRegistryUniversalUpgradeableV2Mock();

        vm.prank(owner);
        swarmRegistry.upgradeToAndCall(
            address(v2Impl), abi.encodeCall(SwarmRegistryUniversalUpgradeableV2Mock.initializeV2, ())
        );

        // Verify upgrade
        SwarmRegistryUniversalUpgradeableV2Mock v2 = SwarmRegistryUniversalUpgradeableV2Mock(swarmRegistryProxy);
        assertEq(v2.version(), "V2");
        assertGt(v2.v2InitializedAt(), 0);

        // Verify old state preserved - swarm still exists via public mapping
        (bytes16 storedUuid, uint256 storedProviderId,,,,) = v2.swarms(swarmId);
        assertEq(storedUuid, uuid);
        assertEq(storedProviderId, providerId);

        // New V2 functionality works
        v2.pauseSwarm(bytes32(swarmId));
        assertTrue(v2.swarmPaused(bytes32(swarmId)));
    }

    function test_SwarmRegistry_NonOwnerCannotUpgrade() public {
        SwarmRegistryUniversalUpgradeableV2Mock v2Impl = new SwarmRegistryUniversalUpgradeableV2Mock();

        vm.prank(attacker);
        vm.expectRevert();
        swarmRegistry.upgradeToAndCall(address(v2Impl), "");
    }

    // =========================================================================
    // Fuzz Tests
    // =========================================================================

    function testFuzz_ServiceProvider_MultipleUpgradesPreserveState(uint8 registrations) public {
        vm.assume(registrations > 0 && registrations < 10);

        // Register multiple providers
        uint256[] memory tokenIds = new uint256[](registrations);
        for (uint256 i = 0; i < registrations; i++) {
            address user = address(uint160(0x1000 + i));
            vm.prank(user);
            tokenIds[i] = serviceProvider.registerProvider(string(abi.encodePacked("https://", i, ".example.com")));
        }

        // Upgrade to V2
        ServiceProviderUpgradeableV2Mock v2Impl = new ServiceProviderUpgradeableV2Mock();
        vm.prank(owner);
        serviceProvider.upgradeToAndCall(address(v2Impl), "");

        // Verify all tokens still exist with correct owners
        ServiceProviderUpgradeableV2Mock v2 = ServiceProviderUpgradeableV2Mock(serviceProviderProxy);
        for (uint256 i = 0; i < registrations; i++) {
            address expectedOwner = address(uint160(0x1000 + i));
            assertEq(v2.ownerOf(tokenIds[i]), expectedOwner);
        }
    }
}
