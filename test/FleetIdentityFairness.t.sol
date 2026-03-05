// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FleetIdentityUpgradeable} from "../src/swarms/FleetIdentityUpgradeable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Minimal ERC-20 mock with public mint for testing.
contract MockERC20Fairness is ERC20 {
    constructor() ERC20("Mock Bond Token", "MBOND") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title FleetIdentityFairness Tests
 * @notice Economic fairness analysis for FleetIdentity bundle allocation.
 *
 * @dev **Fairness Philosophy - Economic Advantage Model**
 *
 * The FleetIdentity contract uses a simple tier-descent algorithm:
 *   - Iterate from highest tier to lowest
 *   - At each tier: include local fleets first, then country fleets
 *   - Stop when bundle is full (20 slots)
 *
 * **Economic Fairness via COUNTRY_BOND_MULTIPLIER (16×)**
 *
 * Country fleets pay 16× more than local fleets at the same tier:
 *   - Local tier 0:  BASE_BOND * 1   = 100 NODL
 *   - Country tier 0: BASE_BOND * 16 = 1600 NODL
 *   - Local tier 4:  BASE_BOND * 16  = 1600 NODL (same cost!)
 *
 * This means a local player can reach tier 4 for the same cost a country player
 * pays for tier 0. The 16× multiplier provides significant economic advantage to locals:
 *
 *   | Tier | Local Bond | Country Bond | Country Overpay vs Local Same Tier |
 *   |------|------------|--------------|-----------------------------------|
 *   |  0   |   100 NODL |   1600 NODL  |              16×                  |
 *   |  1   |   200 NODL |   3200 NODL  |              16×                  |
 *   |  2   |   400 NODL |   6400 NODL  |              16×                  |
 *   |  3   |   800 NODL |  12800 NODL  |              16×                  |
 *
 * **Priority Rules**
 *
 * 1. Higher tier always wins (regardless of level)
 * 2. Within same tier: local beats country
 * 3. Within same tier + level: earlier registration wins
 *
 * **Whale Attack Analysis**
 *
 * A country whale trying to dominate must pay significantly more:
 * - To fill 10 country slots at tier 3: 10 × 12800 NODL = 128,000 NODL
 * - 10 locals could counter at tier 3 for: 10 × 800 NODL = 8,000 NODL
 * - Whale pays 16× more to compete at the same tier level
 */
contract FleetIdentityFairnessTest is Test {
    MockERC20Fairness bondToken;

    // Test addresses representing different market participants
    address[] localPlayers;
    address[] countryPlayers;
    address whale;

    uint256 constant BASE_BOND = 100 ether;
    uint256 constant NUM_LOCAL_PLAYERS = 20;
    uint256 constant NUM_COUNTRY_PLAYERS = 10;

    // Test country and admin areas
    uint16 constant COUNTRY_US = 840;
    uint16[] adminAreas;
    uint256 constant NUM_ADMIN_AREAS = 5;

    function setUp() public {
        bondToken = new MockERC20Fairness();

        // Create test players
        whale = address(0xABCDEF);
        for (uint256 i = 0; i < NUM_LOCAL_PLAYERS; i++) {
            localPlayers.push(address(uint160(0x1000 + i)));
        }
        for (uint256 i = 0; i < NUM_COUNTRY_PLAYERS; i++) {
            countryPlayers.push(address(uint160(0x2000 + i)));
        }

        // Create admin areas
        for (uint16 i = 1; i <= NUM_ADMIN_AREAS; i++) {
            adminAreas.push(i);
        }

        // Fund all players generously
        uint256 funding = 1_000_000_000_000 ether;
        bondToken.mint(whale, funding);
        for (uint256 i = 0; i < NUM_LOCAL_PLAYERS; i++) {
            bondToken.mint(localPlayers[i], funding);
        }
        for (uint256 i = 0; i < NUM_COUNTRY_PLAYERS; i++) {
            bondToken.mint(countryPlayers[i], funding);
        }
    }

    // ══════════════════════════════════════════════════════════════════════════════════
    // Helper Functions
    // ══════════════════════════════════════════════════════════════════════════════════

    address fleetOwner = address(0x1111);

    function _deployFleet() internal returns (FleetIdentityUpgradeable) {
        // Deploy implementation
        FleetIdentityUpgradeable impl = new FleetIdentityUpgradeable();

        // Deploy proxy with initialize call
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(FleetIdentityUpgradeable.initialize, (address(bondToken), BASE_BOND, fleetOwner))
        );

        // Cast proxy to contract type
        FleetIdentityUpgradeable fleet = FleetIdentityUpgradeable(address(proxy));

        // Approve all players
        vm.prank(whale);
        bondToken.approve(address(fleet), type(uint256).max);
        for (uint256 i = 0; i < localPlayers.length; i++) {
            vm.prank(localPlayers[i]);
            bondToken.approve(address(fleet), type(uint256).max);
        }
        for (uint256 i = 0; i < countryPlayers.length; i++) {
            vm.prank(countryPlayers[i]);
            bondToken.approve(address(fleet), type(uint256).max);
        }

        return fleet;
    }

    function _uuid(uint256 seed) internal pure returns (bytes16) {
        return bytes16(keccak256(abi.encodePacked("fleet-fairness-", seed)));
    }

    function _makeAdminRegion(uint16 cc, uint16 admin) internal pure returns (uint32) {
        return (uint32(cc) << 10) | uint32(admin);
    }

    /// @dev Count how many slots in a bundle are from country vs local registrations
    function _countBundleComposition(FleetIdentityUpgradeable fleet, uint16 cc, uint16 admin)
        internal
        view
        returns (uint256 localCount, uint256 countryCount)
    {
        (bytes16[] memory uuids, uint256 count) = fleet.buildHighestBondedUuidBundle(cc, admin);
        uint32 countryRegion = uint32(cc);

        for (uint256 i = 0; i < count; i++) {
            // Try to find token in country region first
            uint256 countryTokenId = fleet.computeTokenId(uuids[i], countryRegion);
            try fleet.ownerOf(countryTokenId) returns (address) {
                countryCount++;
            } catch {
                localCount++;
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════════════════════
    // Scenario Tests: Priority & Economic Behavior
    // ══════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Scenario A: Local-Heavy Market
     * Many local players competing, few country players.
     * Tests that locals correctly fill slots by tier-descent priority.
     */
    function test_scenarioA_localHeavyMarket() public {
        FleetIdentityUpgradeable fleet = _deployFleet();
        uint16 targetAdmin = adminAreas[0];

        // 16 local players at tiers 0-3 (4 per tier due to TIER_CAPACITY)
        for (uint256 i = 0; i < 16; i++) {
            vm.prank(localPlayers[i % NUM_LOCAL_PLAYERS]);
            fleet.registerFleetLocal(_uuid(1000 + i), COUNTRY_US, targetAdmin, i / 4);
        }

        // 4 country players at tier 0
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(countryPlayers[i]);
            fleet.registerFleetCountry(_uuid(2000 + i), COUNTRY_US, 0);
        }

        (uint256 localCount, uint256 countryCount) = _countBundleComposition(fleet, COUNTRY_US, targetAdmin);
        (, uint256 totalCount) = fleet.buildHighestBondedUuidBundle(COUNTRY_US, targetAdmin);

        emit log_string("=== Scenario A: Local-Heavy Market ===");
        emit log_named_uint("Total bundle size", totalCount);
        emit log_named_uint("Local slots used", localCount);
        emit log_named_uint("Country slots used", countryCount);

        // With tier-descent priority, all 16 locals fill first, then 4 country
        assertEq(localCount, 16, "All 16 locals should be included");
        assertEq(countryCount, 4, "All 4 country should fill remaining slots");
        assertEq(totalCount, 20, "Bundle should be full");
    }

    /**
     * @notice Scenario B: Country-Heavy Market
     * Few local players, many country players at higher tiers.
     * Tests that higher-tier country beats lower-tier local.
     */
    function test_scenarioB_countryHighTierDominance() public {
        FleetIdentityUpgradeable fleet = _deployFleet();
        uint16 targetAdmin = adminAreas[0];

        // 4 local players at tier 0
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(localPlayers[i]);
            fleet.registerFleetLocal(_uuid(1000 + i), COUNTRY_US, targetAdmin, 0);
        }

        // 12 country players at tiers 1-3 (4 per tier)
        // These are at HIGHER tiers, so they come first in bundle
        for (uint256 i = 0; i < 12; i++) {
            vm.prank(countryPlayers[i % NUM_COUNTRY_PLAYERS]);
            fleet.registerFleetCountry(_uuid(2000 + i), COUNTRY_US, (i / 4) + 1);
        }

        (uint256 localCount, uint256 countryCount) = _countBundleComposition(fleet, COUNTRY_US, targetAdmin);
        (, uint256 totalCount) = fleet.buildHighestBondedUuidBundle(COUNTRY_US, targetAdmin);

        emit log_string("=== Scenario B: Country High-Tier Dominance ===");
        emit log_named_uint("Total bundle size", totalCount);
        emit log_named_uint("Local slots used", localCount);
        emit log_named_uint("Country slots used", countryCount);

        // Country at tiers 1-3 comes before locals at tier 0
        assertEq(countryCount, 12, "All 12 country (higher tiers) included first");
        assertEq(localCount, 4, "Tier-0 locals fill remaining slots");
        assertEq(totalCount, 16, "Total should equal all registered fleets");
    }

    /**
     * @notice Scenario C: Same-Tier Competition
     * Locals and country at the same tier.
     * Tests that locals get priority within the same tier.
     */
    function test_scenarioC_sameTierLocalPriority() public {
        FleetIdentityUpgradeable fleet = _deployFleet();
        uint16 targetAdmin = adminAreas[0];

        // 4 local at tier 0
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(localPlayers[i]);
            fleet.registerFleetLocal(_uuid(1000 + i), COUNTRY_US, targetAdmin, 0);
        }

        // 4 country at tier 0 (same tier)
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(countryPlayers[i]);
            fleet.registerFleetCountry(_uuid(2000 + i), COUNTRY_US, 0);
        }

        (bytes16[] memory uuids, uint256 count) = fleet.buildHighestBondedUuidBundle(COUNTRY_US, targetAdmin);

        emit log_string("=== Scenario C: Same-Tier Local Priority ===");
        emit log_named_uint("Total bundle size", count);

        // First 4 should be locals (priority within same tier)
        for (uint256 i = 0; i < 4; i++) {
            assertEq(uuids[i], _uuid(1000 + i), "Locals should come first");
        }
        // Next 4 should be country
        for (uint256 i = 0; i < 4; i++) {
            assertEq(uuids[4 + i], _uuid(2000 + i), "Country should follow locals");
        }
    }

    /**
     * @notice Scenario D: Country Whale at High Tier
     * Single whale registers many high-tier country fleets.
     * Tests that whale can dominate IF they outbid locals on tier level.
     */
    function test_scenarioD_countryWhaleHighTier() public {
        FleetIdentityUpgradeable fleet = _deployFleet();
        uint16 targetAdmin = adminAreas[0];

        // 12 locals at tiers 0-2 (4 per tier)
        for (uint256 i = 0; i < 12; i++) {
            vm.prank(localPlayers[i]);
            fleet.registerFleetLocal(_uuid(1000 + i), COUNTRY_US, targetAdmin, i / 4);
        }

        // Whale registers 8 country fleets at tiers 3-4 (4 per tier due to TIER_CAPACITY)
        // This is above all locals (tiers 0-2)
        for (uint256 i = 0; i < 8; i++) {
            vm.prank(whale);
            fleet.registerFleetCountry(_uuid(3000 + i), COUNTRY_US, 3 + (i / 4));
        }

        (, uint256 count) = fleet.buildHighestBondedUuidBundle(COUNTRY_US, targetAdmin);
        (uint256 localCount, uint256 countryCount) = _countBundleComposition(fleet, COUNTRY_US, targetAdmin);

        emit log_string("=== Scenario D: Country Whale at High Tier ===");
        emit log_named_uint("Total bundle size", count);
        emit log_named_uint("Local slots", localCount);
        emit log_named_uint("Country slots", countryCount);

        // Whale's tier-3/4 country fleets come first (highest tiers)
        // Then locals at tiers 0-2 fill remaining slots
        assertEq(countryCount, 8, "Whale's 8 high-tier country fleets included");
        assertEq(localCount, 12, "All 12 locals at lower tiers included");
        assertEq(count, 20, "Bundle full");
    }

    /**
     * @notice Scenario E: Locals Counter Whale by Matching Tier
     * Shows that locals can economically counter a country whale.
     */
    function test_scenarioE_localsCounterWhale() public {
        FleetIdentityUpgradeable fleet = _deployFleet();
        uint16 targetAdmin = adminAreas[0];

        // Whale registers 4 country fleets at tier 3
        // Cost: 4 × (BASE_BOND × 8 × 8) = 4 × 6400 = 25,600 NODL
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(whale);
            fleet.registerFleetCountry(_uuid(3000 + i), COUNTRY_US, 3);
        }

        // 4 locals match at tier 3 (same priority, but cheaper!)
        // Cost: 4 × (BASE_BOND × 8) = 4 × 800 = 3,200 NODL
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(localPlayers[i]);
            fleet.registerFleetLocal(_uuid(1000 + i), COUNTRY_US, targetAdmin, 3);
        }

        (bytes16[] memory uuids, uint256 count) = fleet.buildHighestBondedUuidBundle(COUNTRY_US, targetAdmin);

        emit log_string("=== Scenario E: Locals Counter Whale ===");
        emit log_named_uint("Total bundle size", count);

        // Locals get priority at tier 3 (same tier, local-first)
        for (uint256 i = 0; i < 4; i++) {
            assertEq(uuids[i], _uuid(1000 + i), "Locals come first at same tier");
        }
        for (uint256 i = 0; i < 4; i++) {
            assertEq(uuids[4 + i], _uuid(3000 + i), "Country follows at same tier");
        }

        // Calculate cost ratio
        uint256 whaleCost = 4 * fleet.tierBond(3, true);  // 25,600 NODL
        uint256 localCost = 4 * fleet.tierBond(3, false); // 3,200 NODL

        emit log_named_uint("Whale total cost (ether)", whaleCost / 1 ether);
        emit log_named_uint("Locals total cost (ether)", localCost / 1 ether);
        emit log_named_uint("Whale overpay factor", whaleCost / localCost);

        assertEq(whaleCost / localCost, 16, "Whale pays 16x more for same tier");
    }

    // ══════════════════════════════════════════════════════════════════════════════════
    // Economic Metrics & Analysis
    // ══════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Verify the 16× economic advantage constants.
     */
    function test_economicAdvantage_8xMultiplier() public {
        FleetIdentityUpgradeable fleet = _deployFleet();

        // Verify multiplier
        assertEq(fleet.COUNTRY_BOND_MULTIPLIER(), 16, "Multiplier should be 16");

        // At every tier, country pays exactly 16× local
        for (uint256 tier = 0; tier < 6; tier++) {
            uint256 localBond = fleet.tierBond(tier, false);
            uint256 countryBond = fleet.tierBond(tier, true);
            assertEq(countryBond, localBond * 16, "Country should pay 16x at every tier");
        }
    }

    /**
     * @notice Demonstrate that a local at tier N+4 costs the same as country at tier N.
     */
    function test_economicAdvantage_localTierEquivalence() public {
        FleetIdentityUpgradeable fleet = _deployFleet();

        // Local tier 4 = Country tier 0 (2^4 = 16)
        assertEq(
            fleet.tierBond(4, false),
            fleet.tierBond(0, true),
            "Local tier 4 should equal country tier 0"
        );

        // Local tier 5 = Country tier 1
        assertEq(
            fleet.tierBond(5, false),
            fleet.tierBond(1, true),
            "Local tier 5 should equal country tier 1"
        );

        // Local tier 6 = Country tier 2
        assertEq(
            fleet.tierBond(6, false),
            fleet.tierBond(2, true),
            "Local tier 6 should equal country tier 2"
        );

        emit log_string("=== Local Tier Equivalence ===");
        emit log_string("Local tier N+4 costs the same as Country tier N");
        emit log_string("This gives locals a 4-tier economic advantage");
    }

    /**
     * @notice Analyze country registration efficiency across admin areas.
     */
    function test_economicAdvantage_multiRegionEfficiency() public {
        FleetIdentityUpgradeable fleet = _deployFleet();

        // Single country registration covers ALL admin areas
        uint256 countryBond = fleet.tierBond(0, true); // 800 NODL

        // To cover N admin areas locally, costs N × local_bond
        uint256 localPerArea = fleet.tierBond(0, false); // 100 NODL

        emit log_string("=== Multi-Region Efficiency Analysis ===");
        emit log_named_uint("Country tier-0 bond (ether)", countryBond / 1 ether);
        emit log_named_uint("Local tier-0 bond per area (ether)", localPerArea / 1 ether);

        // Country is MORE efficient when covering > 8 admin areas
        // Break-even: 8 local registrations = 1 country registration
        uint256 breakEvenAreas = countryBond / localPerArea;
        emit log_named_uint("Break-even admin areas", breakEvenAreas);

        assertEq(breakEvenAreas, 16, "Country efficient for 16+ admin areas");
    }

    /**
     * @notice Bond escalation analysis showing geometric growth.
     */
    function test_bondEscalationAnalysis() public {
        FleetIdentityUpgradeable fleet = _deployFleet();

        emit log_string("");
        emit log_string("=== BOND ESCALATION ANALYSIS ===");
        emit log_string("");
        emit log_string("Tier | Local Bond (ether) | Country Bond (ether)");
        emit log_string("-----+--------------------+---------------------");

        for (uint256 tier = 0; tier <= 6; tier++) {
            uint256 localBond = fleet.tierBond(tier, false);
            uint256 countryBond = fleet.tierBond(tier, true);

            // Verify geometric progression (2× per tier)
            if (tier > 0) {
                assertEq(localBond, fleet.tierBond(tier - 1, false) * 2, "Local should double each tier");
                assertEq(countryBond, fleet.tierBond(tier - 1, true) * 2, "Country should double each tier");
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════════════════════
    // Invariant Tests
    // ══════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice CRITICAL: Core invariants that must ALWAYS hold.
     */
    function test_invariant_coreGuarantees() public {
        FleetIdentityUpgradeable fleet = _deployFleet();

        // Invariant 1: Country multiplier is exactly 16
        assertEq(fleet.COUNTRY_BOND_MULTIPLIER(), 16, "INVARIANT: Country multiplier must be 16");

        // Invariant 2: Tier capacity allows fair competition
        assertEq(fleet.TIER_CAPACITY(), 10, "INVARIANT: Tier capacity must be 10");

        // Invariant 3: Bundle size reasonable for discovery
        assertEq(fleet.MAX_BONDED_UUID_BUNDLE_SIZE(), 20, "INVARIANT: Bundle size must be 20");

        // Invariant 4: Bond doubles per tier (geometric)
        for (uint256 t = 1; t <= 5; t++) {
            assertEq(
                fleet.tierBond(t, false),
                fleet.tierBond(t - 1, false) * 2,
                "INVARIANT: Bond must double per tier"
            );
        }

        emit log_string("[PASS] All core invariants verified");
    }

    /**
     * @notice Bundle always respects tier-descent priority.
     */
    function test_invariant_tierDescentPriority() public {
        FleetIdentityUpgradeable fleet = _deployFleet();
        uint16 targetAdmin = adminAreas[0];

        // Mixed setup: locals at tier 1, country at tier 2
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(localPlayers[i]);
            fleet.registerFleetLocal(_uuid(1000 + i), COUNTRY_US, targetAdmin, 1);
        }
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(countryPlayers[i]);
            fleet.registerFleetCountry(_uuid(2000 + i), COUNTRY_US, 2);
        }

        (bytes16[] memory uuids, uint256 count) = fleet.buildHighestBondedUuidBundle(COUNTRY_US, targetAdmin);

        // Tier 2 (country) must come before tier 1 (local) - higher tier wins
        for (uint256 i = 0; i < 4; i++) {
            assertEq(uuids[i], _uuid(2000 + i), "INVARIANT: Higher tier must come first");
        }
        for (uint256 i = 0; i < 4; i++) {
            assertEq(uuids[4 + i], _uuid(1000 + i), "Lower tier follows");
        }

        assertEq(count, 8);
    }

    // ══════════════════════════════════════════════════════════════════════════════════
    // Fuzz Tests
    // ══════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Fuzz test to verify bundle properties across random market conditions.
     */
    function testFuzz_bundleProperties(uint8 numLocals, uint8 numCountry) public {
        // Bound inputs to reasonable ranges
        numLocals = uint8(bound(numLocals, 1, 16));
        numCountry = uint8(bound(numCountry, 1, 12));

        FleetIdentityUpgradeable fleet = _deployFleet();
        uint16 targetAdmin = adminAreas[0];

        // Register local players (spread across tiers for variety)
        for (uint256 i = 0; i < numLocals; i++) {
            vm.prank(localPlayers[i % NUM_LOCAL_PLAYERS]);
            fleet.registerFleetLocal(_uuid(8000 + i), COUNTRY_US, targetAdmin, i / 4);
        }

        // Register country players
        for (uint256 i = 0; i < numCountry; i++) {
            vm.prank(countryPlayers[i % NUM_COUNTRY_PLAYERS]);
            fleet.registerFleetCountry(_uuid(9000 + i), COUNTRY_US, i / 4);
        }

        // Get bundle
        (, uint256 count) = fleet.buildHighestBondedUuidBundle(COUNTRY_US, targetAdmin);

        // Properties that must always hold:

        // 1. Bundle never exceeds max size
        assertLe(count, fleet.MAX_BONDED_UUID_BUNDLE_SIZE(), "Bundle must not exceed max");

        // 2. Bundle includes as many as possible (up to registered count)
        uint256 totalRegistered = uint256(numLocals) + uint256(numCountry);
        uint256 expectedMax = totalRegistered < 20 ? totalRegistered : 20;
        assertEq(count, expectedMax, "Bundle should maximize utilization");
    }

    /**
     * @notice Fuzz that 16x multiplier always holds at any tier.
     */
    function testFuzz_constantMultiplier(uint8 tier) public {
        tier = uint8(bound(tier, 0, 20));
        FleetIdentityUpgradeable fleet = _deployFleet();

        uint256 localBond = fleet.tierBond(tier, false);
        uint256 countryBond = fleet.tierBond(tier, true);

        assertEq(countryBond, localBond * 16, "16x multiplier must hold at all tiers");
    }
}
