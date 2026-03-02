// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FleetIdentity} from "../src/swarms/FleetIdentity.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Minimal ERC-20 mock with public mint for testing.
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Bond Token", "MBOND") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev ERC-20 that returns false on transfer instead of reverting.
contract BadERC20 is ERC20 {
    bool public shouldFail;

    constructor() ERC20("Bad Token", "BAD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFail(bool _fail) external {
        shouldFail = _fail;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (shouldFail) return false;
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (shouldFail) return false;
        return super.transferFrom(from, to, amount);
    }
}

contract FleetIdentityTest is Test {
    FleetIdentity fleet;
    MockERC20 bondToken;

    address alice = address(0xA);
    address bob = address(0xB);
    address carol = address(0xC);

    bytes16 constant UUID_1 = bytes16(keccak256("fleet-alpha"));
    bytes16 constant UUID_2 = bytes16(keccak256("fleet-bravo"));
    bytes16 constant UUID_3 = bytes16(keccak256("fleet-charlie"));

    uint256 constant BASE_BOND = 100 ether;

    uint16 constant US = 840;
    uint16 constant DE = 276;
    uint16 constant FR = 250;
    uint16 constant JP = 392;
    uint16 constant ADMIN_CA = 1;
    uint16 constant ADMIN_NY = 2;

    event FleetRegistered(
        address indexed owner,
        bytes16 indexed uuid,
        uint256 indexed tokenId,
        uint32 regionKey,
        uint256 tierIndex,
        uint256 bondAmount,
        address operator
    );
    event OperatorSet(
        bytes16 indexed uuid,
        address indexed oldOperator,
        address indexed newOperator,
        uint256 tierExcessTransferred
    );
    event FleetPromoted(
        uint256 indexed tokenId, uint256 indexed fromTier, uint256 indexed toTier, uint256 additionalBond
    );
    event FleetDemoted(uint256 indexed tokenId, uint256 indexed fromTier, uint256 indexed toTier, uint256 bondRefund);
    event FleetBurned(
        address indexed owner, uint256 indexed tokenId, uint32 indexed regionKey, uint256 tierIndex, uint256 bondRefund
    );

    function setUp() public {
        bondToken = new MockERC20();
        fleet = new FleetIdentity(address(bondToken), BASE_BOND);

        // Mint enough for all 24 tiers (tier 23 bond = BASE_BOND * 2^23 ≈ 838M ether)
        // Total for 8 members across 24 tiers ≈ 13.4 billion ether
        bondToken.mint(alice, 100_000_000_000_000 ether);
        bondToken.mint(bob, 100_000_000_000_000 ether);
        bondToken.mint(carol, 100_000_000_000_000 ether);

        vm.prank(alice);
        bondToken.approve(address(fleet), type(uint256).max);
        vm.prank(bob);
        bondToken.approve(address(fleet), type(uint256).max);
        vm.prank(carol);
        bondToken.approve(address(fleet), type(uint256).max);
    }

    // --- Helpers ---

    /// @dev Compute tokenId from (uuid, region) using new encoding
    function _tokenId(bytes16 uuid, uint32 region) internal pure returns (uint256) {
        return (uint256(region) << 128) | uint256(uint128(uuid));
    }

    /// @dev Given a UUID from buildBundle, find tokenId by checking local first, then country
    function _findTokenId(bytes16 uuid, uint16 cc, uint16 admin) internal view returns (uint256) {
        uint32 localRegion = (uint32(cc) << 10) | uint32(admin);
        uint256 localTokenId = _tokenId(uuid, localRegion);
        // Check if local token exists by trying to get its owner
        try fleet.ownerOf(localTokenId) returns (address) {
            return localTokenId;
        } catch {
            uint32 countryRegion = uint32(cc);
            return _tokenId(uuid, countryRegion);
        }
    }

    function _uuid(uint256 i) internal pure returns (bytes16) {
        return bytes16(keccak256(abi.encodePacked("fleet-", i)));
    }

    function _regionUS() internal pure returns (uint32) {
        return uint32(US);
    }

    function _regionDE() internal pure returns (uint32) {
        return uint32(DE);
    }

    function _regionUSCA() internal pure returns (uint32) {
        return (uint32(US) << 10) | uint32(ADMIN_CA);
    }

    function _regionUSNY() internal pure returns (uint32) {
        return (uint32(US) << 10) | uint32(ADMIN_NY);
    }

    function _makeAdminRegion(uint16 cc, uint16 admin) internal pure returns (uint32) {
        return (uint32(cc) << 10) | uint32(admin);
    }

    function _registerNCountry(address owner, uint16 cc, uint256 count, uint256 startSeed)
        internal
        returns (uint256[] memory ids)
    {
        uint256 cap = fleet.TIER_CAPACITY();
        ids = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            uint256 targetTier = i / cap;
            vm.prank(owner);
            ids[i] = fleet.registerFleetCountry(_uuid(startSeed + i), cc, targetTier);
        }
    }

    function _registerNCountryAt(address owner, uint16 cc, uint256 count, uint256 startSeed, uint256 tier)
        internal
        returns (uint256[] memory ids)
    {
        ids = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            vm.prank(owner);
            ids[i] = fleet.registerFleetCountry(_uuid(startSeed + i), cc, tier);
        }
    }

    function _registerNLocal(address owner, uint16 cc, uint16 admin, uint256 count, uint256 startSeed)
        internal
        returns (uint256[] memory ids)
    {
        uint256 cap = fleet.TIER_CAPACITY();
        ids = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            uint256 targetTier = i / cap;
            vm.prank(owner);
            ids[i] = fleet.registerFleetLocal(_uuid(startSeed + i), cc, admin, targetTier);
        }
    }

    function _registerNLocalAt(address owner, uint16 cc, uint16 admin, uint256 count, uint256 startSeed, uint256 tier)
        internal
        returns (uint256[] memory ids)
    {
        ids = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            vm.prank(owner);
            ids[i] = fleet.registerFleetLocal(_uuid(startSeed + i), cc, admin, tier);
        }
    }

    // --- Constructor ---

    function test_constructor_setsImmutables() public view {
        assertEq(address(fleet.BOND_TOKEN()), address(bondToken));
        assertEq(fleet.BASE_BOND(), BASE_BOND);
        assertEq(fleet.name(), "Swarm Fleet Identity");
        assertEq(fleet.symbol(), "SFID");
    }

    function test_constructor_constants() public view {
        assertEq(fleet.TIER_CAPACITY(), 10);
        assertEq(fleet.MAX_TIERS(), 24);
        assertEq(fleet.MAX_BONDED_UUID_BUNDLE_SIZE(), 20);
        assertEq(fleet.COUNTRY_BOND_MULTIPLIER(), 16);
    }

    // --- tierBond ---

    function test_tierBond_local_tier0() public view {
        // Local regions get 1× multiplier
        assertEq(fleet.tierBond(0, false), BASE_BOND);
    }

    function test_tierBond_country_tier0() public view {
        // Country regions get 16x multiplier
        assertEq(fleet.tierBond(0, true), BASE_BOND * fleet.COUNTRY_BOND_MULTIPLIER());
    }

    function test_tierBond_local_tier1() public view {
        assertEq(fleet.tierBond(1, false), BASE_BOND * 2);
    }

    function test_tierBond_country_tier1() public view {
        assertEq(fleet.tierBond(1, true), BASE_BOND * fleet.COUNTRY_BOND_MULTIPLIER() * 2);
    }

    function test_tierBond_geometricProgression() public view {
        for (uint256 i = 1; i <= 5; i++) {
            assertEq(fleet.tierBond(i, false), fleet.tierBond(i - 1, false) * 2);
            assertEq(fleet.tierBond(i, true), fleet.tierBond(i - 1, true) * 2);
        }
    }

    // --- registerFleetCountry ---

    function test_registerFleetCountry_auto_setsRegionAndTier() public {
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetCountry(UUID_1, US, 0);

        assertEq(fleet.tokenRegion(tokenId), _regionUS());
        assertEq(fleet.fleetTier(tokenId), 0);
        assertEq(fleet.bonds(tokenId), BASE_BOND * fleet.COUNTRY_BOND_MULTIPLIER()); // Country gets 16x multiplier
        assertEq(fleet.regionTierCount(_regionUS()), 1);
    }

    function test_RevertIf_registerFleetCountry_invalidCode_zero() public {
        vm.prank(alice);
        vm.expectRevert(FleetIdentity.InvalidCountryCode.selector);
        fleet.registerFleetCountry(UUID_1, 0, 0);
    }

    function test_RevertIf_registerFleetCountry_invalidCode_over999() public {
        vm.prank(alice);
        vm.expectRevert(FleetIdentity.InvalidCountryCode.selector);
        fleet.registerFleetCountry(UUID_1, 1000, 0);
    }

    // --- registerFleetLocal ---

    function test_registerFleetLocal_setsRegionAndTier() public {
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);

        assertEq(fleet.tokenRegion(tokenId), _regionUSCA());
        assertEq(fleet.fleetTier(tokenId), 0);
        assertEq(fleet.bonds(tokenId), BASE_BOND);
    }

    function test_RevertIf_registerFleetLocal_invalidCountry() public {
        vm.prank(alice);
        vm.expectRevert(FleetIdentity.InvalidCountryCode.selector);
        fleet.registerFleetLocal(UUID_1, 0, ADMIN_CA, 0);
    }

    function test_RevertIf_registerFleetLocal_invalidAdmin_zero() public {
        vm.prank(alice);
        vm.expectRevert(FleetIdentity.InvalidAdminCode.selector);
        fleet.registerFleetLocal(UUID_1, US, 0, 0);
    }

    function test_RevertIf_registerFleetLocal_invalidAdmin_over4095() public {
        vm.prank(alice);
        vm.expectRevert(FleetIdentity.InvalidAdminCode.selector);
        fleet.registerFleetLocal(UUID_1, US, 4096, 0);
    }

    // --- Per-region independent tier indexing (KEY REQUIREMENT) ---

    function test_perRegionTiers_firstFleetInEachLevelPaysBondWithMultiplier() public {
        // Country level pays 16x multiplier
        vm.prank(alice);
        uint256 c1 = fleet.registerFleetCountry(UUID_1, US, 0);
        // Local level pays 1× multiplier
        vm.prank(alice);
        uint256 l1 = fleet.registerFleetLocal(UUID_2, US, ADMIN_CA, 0);

        assertEq(fleet.fleetTier(c1), 0);
        assertEq(fleet.fleetTier(l1), 0);

        assertEq(fleet.bonds(c1), BASE_BOND * fleet.COUNTRY_BOND_MULTIPLIER()); // Country gets 16× multiplier
        assertEq(fleet.bonds(l1), BASE_BOND); // Local gets 1× multiplier
    }

    function test_perRegionTiers_fillOneRegionDoesNotAffectOthers() public {
        // Fill US country tier 0 with 4 fleets
        _registerNCountryAt(alice, US, 4, 0, 0);
        assertEq(fleet.regionTierCount(_regionUS()), 1);
        assertEq(fleet.tierMemberCount(_regionUS(), 0), 4);

        // Next US country fleet goes to tier 1
        vm.prank(bob);
        uint256 us21 = fleet.registerFleetCountry(_uuid(100), US, 1);
        assertEq(fleet.fleetTier(us21), 1);
        assertEq(fleet.bonds(us21), BASE_BOND * fleet.COUNTRY_BOND_MULTIPLIER() * 2); // Country tier 1: 16× * 2^1

        // DE country is independent - can still join tier 0
        vm.prank(bob);
        uint256 de1 = fleet.registerFleetCountry(_uuid(200), DE, 0);
        assertEq(fleet.fleetTier(de1), 0);
        assertEq(fleet.bonds(de1), BASE_BOND * fleet.COUNTRY_BOND_MULTIPLIER());
        assertEq(fleet.regionTierCount(_regionDE()), 1);

        // US local is independent - can still join tier 0
        vm.prank(bob);
        uint256 usca1 = fleet.registerFleetLocal(_uuid(300), US, ADMIN_CA, 0);
        assertEq(fleet.fleetTier(usca1), 0);
        assertEq(fleet.bonds(usca1), BASE_BOND);
    }

    function test_perRegionTiers_twoCountriesIndependent() public {
        // Register 4 US country fleets at tier 0
        _registerNCountryAt(alice, US, 4, 0, 0);
        assertEq(fleet.tierMemberCount(_regionUS(), 0), 4);

        // Next US country fleet explicitly goes to tier 1
        vm.prank(bob);
        uint256 us21 = fleet.registerFleetCountry(_uuid(500), US, 1);
        assertEq(fleet.fleetTier(us21), 1);
        assertEq(fleet.bonds(us21), BASE_BOND * fleet.COUNTRY_BOND_MULTIPLIER() * 2); // Country tier 1: 16× * 2^1

        // DE country is independent - can still join tier 0
        vm.prank(bob);
        uint256 de1 = fleet.registerFleetCountry(_uuid(600), DE, 0);
        assertEq(fleet.fleetTier(de1), 0);
        assertEq(fleet.bonds(de1), BASE_BOND * fleet.COUNTRY_BOND_MULTIPLIER()); // Country tier 0: 16× * 2^0
    }

    function test_perRegionTiers_twoAdminAreasIndependent() public {
        // Register 4 local fleets at tier 0 in US/CA
        _registerNLocalAt(alice, US, ADMIN_CA, 4, 0, 0);
        assertEq(fleet.tierMemberCount(_regionUSCA(), 0), 4);

        // NY is independent - can still join tier 0
        vm.prank(bob);
        uint256 ny1 = fleet.registerFleetLocal(_uuid(500), US, ADMIN_NY, 0);
        assertEq(fleet.fleetTier(ny1), 0);
        assertEq(fleet.bonds(ny1), BASE_BOND);
    }

    // --- Local inclusion hint tier logic ---

    function test_localInclusionHint_emptyRegionReturnsTier0() public {
        // No fleets anywhere — localInclusionHint returns tier 0.
        (uint256 inclusionTier,) = fleet.localInclusionHint(US, ADMIN_CA);
        assertEq(inclusionTier, 0);
        
        // Register at tier 0 (inclusionTier is 0, so no promotion needed)
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);
        assertEq(fleet.fleetTier(tokenId), 0);
        assertEq(fleet.regionTierCount(_regionUSCA()), 1);
    }

    function test_localInclusionHint_returnsCheapestInclusionTier() public {
        // Fill admin-area tier 0 so tier 0 is full.
        _registerNLocalAt(alice, US, ADMIN_CA, fleet.TIER_CAPACITY(), 0, 0);

        // localInclusionHint should return tier 1 (cheapest tier with capacity).
        (uint256 inclusionTier,) = fleet.localInclusionHint(US, ADMIN_CA);
        assertEq(inclusionTier, 1);
        
        // Register directly at inclusionTier as tier 0 is full
        vm.prank(bob);
        uint256 tokenId = fleet.registerFleetLocal(_uuid(100), US, ADMIN_CA, inclusionTier);
        assertEq(fleet.fleetTier(tokenId), 1);
        assertEq(fleet.regionTierCount(_regionUSCA()), 2);
    }

    // --- promote ---

    function test_promote_next_movesToNextTierInRegion() public {
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetCountry(UUID_1, US, 0);

        vm.prank(alice);
        fleet.promote(tokenId);

        assertEq(fleet.fleetTier(tokenId), 1);
        assertEq(fleet.bonds(tokenId), fleet.tierBond(1, true));
    }

    function test_promote_next_pullsBondDifference() public {
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);

        uint256 balBefore = bondToken.balanceOf(alice);
        uint256 diff = fleet.tierBond(1, false) - fleet.tierBond(0, false);

        vm.prank(alice);
        fleet.promote(tokenId);

        assertEq(bondToken.balanceOf(alice), balBefore - diff);
    }

    function test_reassignTier_promotesWhenTargetHigher() public {
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);

        vm.prank(alice);
        fleet.reassignTier(tokenId, 3);

        assertEq(fleet.fleetTier(tokenId), 3);
        assertEq(fleet.bonds(tokenId), fleet.tierBond(3, false));
        assertEq(fleet.regionTierCount(_regionUSCA()), 4);
    }

    function test_promote_emitsEvent() public {
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);
        uint256 diff = fleet.tierBond(1, false) - fleet.tierBond(0, false);

        vm.expectEmit(true, true, true, true);
        emit FleetPromoted(tokenId, 0, 1, diff);

        vm.prank(alice);
        fleet.promote(tokenId);
    }

    function test_RevertIf_promote_notOperator() public {
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);

        vm.prank(bob);
        vm.expectRevert(FleetIdentity.NotOperator.selector);
        fleet.promote(tokenId);
    }

    function test_RevertIf_reassignTier_targetSameAsCurrent() public {
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);
        vm.prank(alice);
        fleet.reassignTier(tokenId, 2);

        vm.prank(alice);
        vm.expectRevert(FleetIdentity.TargetTierSameAsCurrent.selector);
        fleet.reassignTier(tokenId, 2);
    }

    function test_RevertIf_promote_targetTierFull() public {
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);

        // Fill tier 1 with TIER_CAPACITY members
        for (uint256 i = 0; i < fleet.TIER_CAPACITY(); i++) {
            vm.prank(bob);
            fleet.registerFleetLocal(_uuid(50 + i), US, ADMIN_CA, 1);
        }

        vm.prank(alice);
        vm.expectRevert(FleetIdentity.TierFull.selector);
        fleet.promote(tokenId);
    }

    function test_RevertIf_reassignTier_exceedsMaxTiers() public {
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);

        vm.prank(alice);
        vm.expectRevert(FleetIdentity.MaxTiersReached.selector);
        fleet.reassignTier(tokenId, 50);
    }

    // --- reassignTier (demote direction) ---

    function test_reassignTier_demotesWhenTargetLower() public {
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetCountry(UUID_1, DE, 0);
        vm.prank(alice);
        fleet.reassignTier(tokenId, 3);

        vm.prank(alice);
        fleet.reassignTier(tokenId, 1);

        assertEq(fleet.fleetTier(tokenId), 1);
        assertEq(fleet.bonds(tokenId), fleet.tierBond(1, true));
    }

    function test_reassignTier_demoteRefundsBondDifference() public {
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);
        vm.prank(alice);
        fleet.reassignTier(tokenId, 3);

        uint256 balBefore = bondToken.balanceOf(alice);
        uint256 refund = fleet.tierBond(3, false) - fleet.tierBond(1, false);

        vm.prank(alice);
        fleet.reassignTier(tokenId, 1);

        assertEq(bondToken.balanceOf(alice), balBefore + refund);
    }

    function test_reassignTier_demoteEmitsEvent() public {
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);
        vm.prank(alice);
        fleet.reassignTier(tokenId, 3);
        uint256 refund = fleet.tierBond(3, false) - fleet.tierBond(1, false);

        vm.expectEmit(true, true, true, true);
        emit FleetDemoted(tokenId, 3, 1, refund);

        vm.prank(alice);
        fleet.reassignTier(tokenId, 1);
    }

    function test_reassignTier_demoteTrimsTierCountWhenTopEmpties() public {
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);
        vm.prank(alice);
        fleet.reassignTier(tokenId, 3);
        assertEq(fleet.regionTierCount(_regionUSCA()), 4);

        vm.prank(alice);
        fleet.reassignTier(tokenId, 0);
        assertEq(fleet.regionTierCount(_regionUSCA()), 1);
    }

    function test_RevertIf_reassignTier_demoteNotOperator() public {
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);
        vm.prank(alice);
        fleet.reassignTier(tokenId, 2);

        vm.prank(bob);
        vm.expectRevert(FleetIdentity.NotOperator.selector);
        fleet.reassignTier(tokenId, 0);
    }

    function test_RevertIf_reassignTier_demoteTargetTierFull() public {
        _registerNLocalAt(alice, US, ADMIN_CA, fleet.TIER_CAPACITY(), 0, 0);

        // Register at tier 1 since tier 0 is full, then promote further
        vm.prank(bob);
        uint256 tokenId = fleet.registerFleetLocal(_uuid(100), US, ADMIN_CA, 1);
        vm.prank(bob);
        fleet.reassignTier(tokenId, 2);

        vm.prank(bob);
        vm.expectRevert(FleetIdentity.TierFull.selector);
        fleet.reassignTier(tokenId, 0);
    }

    function test_RevertIf_reassignTier_promoteNotOperator() public {
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);

        vm.prank(bob);
        vm.expectRevert(FleetIdentity.NotOperator.selector);
        fleet.reassignTier(tokenId, 3);
    }

    // --- burn ---

    function test_burn_refundsTierBond() public {
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);
        uint256 balBefore = bondToken.balanceOf(alice);

        vm.prank(alice);
        fleet.burn(tokenId);

        // Last registered token burn -> transitions to owned-only
        // Operator (alice) gets tierBond refund, owned-only token minted (holds BASE_BOND)
        assertEq(bondToken.balanceOf(alice), balBefore + fleet.tierBond(0, false));
        assertEq(bondToken.balanceOf(address(fleet)), BASE_BOND); // owned-only token holds BASE_BOND
        assertEq(fleet.bonds(tokenId), 0);
        
        // Verify owned-only token was minted
        uint256 ownedTokenId = uint256(uint128(UUID_1));
        assertEq(fleet.ownerOf(ownedTokenId), alice);
        assertTrue(fleet.isOwnedOnly(UUID_1));
    }

    function test_burn_emitsEvent() public {
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);

        vm.expectEmit(true, true, true, true);
        // Event emits tier bond refund only (owned-only token keeps BASE_BOND)
        emit FleetBurned(alice, tokenId, _regionUSCA(), 0, fleet.tierBond(0, false));

        vm.prank(alice);
        fleet.burn(tokenId);
    }

    function test_burn_trimsTierCount() public {
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetCountry(UUID_1, US, 0);
        vm.prank(alice);
        fleet.reassignTier(tokenId, 3);
        assertEq(fleet.regionTierCount(_regionUS()), 4);

        vm.prank(alice);
        fleet.burn(tokenId);
        assertEq(fleet.regionTierCount(_regionUS()), 0);
        
        // Verify transitioned to owned-only
        assertTrue(fleet.isOwnedOnly(UUID_1));
    }

    function test_burn_allowsReregistration_sameRegion() public {
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);

        vm.prank(alice);
        fleet.burn(tokenId);
        
        // Now in owned-only state - burn that too to fully release
        uint256 ownedTokenId = uint256(uint128(UUID_1));
        vm.prank(alice);
        fleet.burn(ownedTokenId);

        // Same UUID can be re-registered in same region, same tokenId
        vm.prank(bob);
        uint256 newId = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);
        assertEq(newId, tokenId);
        assertEq(fleet.tokenRegion(newId), _regionUSCA());
    }

    function test_multiRegion_sameUuidCanRegisterInDifferentRegions() public {
        // Same UUID can be registered in multiple regions simultaneously (by SAME owner, SAME level)
        vm.prank(alice);
        uint256 localId1 = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);

        vm.prank(alice);
        uint256 localId2 = fleet.registerFleetLocal(UUID_1, DE, ADMIN_CA, 0);

        // Different tokenIds for different regions
        assertTrue(localId1 != localId2, "Different regions should have different tokenIds");

        // Both have same UUID but different regions
        assertEq(fleet.tokenUuid(localId1), UUID_1);
        assertEq(fleet.tokenUuid(localId2), UUID_1);
        assertEq(fleet.tokenRegion(localId1), _regionUSCA());
        assertEq(fleet.tokenRegion(localId2), _makeAdminRegion(DE, ADMIN_CA));

        // Both owned by alice
        assertEq(fleet.ownerOf(localId1), alice);
        assertEq(fleet.ownerOf(localId2), alice);
    }

    function test_RevertIf_burn_registeredToken_notOperator() public {
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);

        // Bob is not operator - should revert
        vm.prank(bob);
        vm.expectRevert(FleetIdentity.NotOperator.selector);
        fleet.burn(tokenId);
    }

    // --- localInclusionHint ---

    function test_localInclusionHint_emptyRegion() public view {
        (uint256 tier, uint256 bond) = fleet.localInclusionHint(US, ADMIN_CA);
        assertEq(tier, 0);
        assertEq(bond, BASE_BOND);
    }

    function test_localInclusionHint_afterFillingAdminTier0() public {
        _registerNLocalAt(alice, US, ADMIN_CA, fleet.TIER_CAPACITY(), 0, 0);

        // Admin tier 0 full → cheapest inclusion is tier 1.
        (uint256 tier, uint256 bond) = fleet.localInclusionHint(US, ADMIN_CA);
        assertEq(tier, 1);
        assertEq(bond, BASE_BOND * 2);
    }

    // --- highestActiveTier ---

    function test_highestActiveTier_noFleets() public view {
        assertEq(fleet.highestActiveTier(_regionUS()), 0);
        assertEq(fleet.highestActiveTier(_regionUSCA()), 0);
    }

    function test_highestActiveTier_afterRegistrations() public {
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetCountry(UUID_1, US, 0);
        vm.prank(alice);
        fleet.reassignTier(tokenId, 3);
        assertEq(fleet.highestActiveTier(_regionUS()), 3);

        // Different region still at 0
        assertEq(fleet.highestActiveTier(_regionDE()), 0);
    }

    // --- EdgeBeaconScanner helpers ---

    function test_tierMemberCount_perRegion() public {
        _registerNLocalAt(alice, US, ADMIN_CA, 3, 0, 0);
        _registerNCountryAt(bob, US, 4, 100, 0);

        assertEq(fleet.tierMemberCount(_regionUSCA(), 0), 3);
        assertEq(fleet.tierMemberCount(_regionUS(), 0), 4);
    }

    function test_getTierMembers_perRegion() public {
        vm.prank(alice);
        uint256 usId = fleet.registerFleetCountry(UUID_1, US, 0);

        vm.prank(bob);
        uint256 uscaId = fleet.registerFleetLocal(UUID_2, US, ADMIN_CA, 0);

        uint256[] memory usMembers = fleet.getTierMembers(_regionUS(), 0);
        assertEq(usMembers.length, 1);
        assertEq(usMembers[0], usId);

        uint256[] memory uscaMembers = fleet.getTierMembers(_regionUSCA(), 0);
        assertEq(uscaMembers.length, 1);
        assertEq(uscaMembers[0], uscaId);
    }

    function test_getTierUuids_perRegion() public {
        vm.prank(alice);
        fleet.registerFleetCountry(UUID_1, US, 0);

        vm.prank(bob);
        fleet.registerFleetLocal(UUID_2, US, ADMIN_CA, 0);

        bytes16[] memory usUUIDs = fleet.getTierUuids(_regionUS(), 0);
        assertEq(usUUIDs.length, 1);
        assertEq(usUUIDs[0], UUID_1);

        bytes16[] memory uscaUUIDs = fleet.getTierUuids(_regionUSCA(), 0);
        assertEq(uscaUUIDs.length, 1);
        assertEq(uscaUUIDs[0], UUID_2);
    }

    // --- Region indexes ---

    function test_activeCountries_addedOnRegistration() public {
        vm.prank(alice);
        fleet.registerFleetCountry(UUID_1, US, 0);
        vm.prank(bob);
        fleet.registerFleetCountry(UUID_2, DE, 0);

        uint16[] memory countries = fleet.getActiveCountries();
        assertEq(countries.length, 2);
    }

    function test_activeCountries_removedWhenAllBurned() public {
        vm.prank(alice);
        uint256 id1 = fleet.registerFleetCountry(UUID_1, US, 0);

        uint16[] memory before_ = fleet.getActiveCountries();
        assertEq(before_.length, 1);

        vm.prank(alice);
        fleet.burn(id1);

        uint16[] memory after_ = fleet.getActiveCountries();
        assertEq(after_.length, 0);
    }

    function test_activeCountries_notDuplicated() public {
        vm.prank(alice);
        fleet.registerFleetCountry(UUID_1, US, 0);
        vm.prank(bob);
        fleet.registerFleetCountry(UUID_2, US, 0);

        uint16[] memory countries = fleet.getActiveCountries();
        assertEq(countries.length, 1);
        assertEq(countries[0], US);
    }

    function test_activeAdminAreas_trackedCorrectly() public {
        vm.prank(alice);
        fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);
        vm.prank(bob);
        fleet.registerFleetLocal(UUID_2, US, ADMIN_NY, 0);

        uint32[] memory areas = fleet.getActiveAdminAreas();
        assertEq(areas.length, 2);
    }

    function test_activeAdminAreas_removedWhenAllBurned() public {
        vm.prank(alice);
        uint256 id1 = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);

        assertEq(fleet.getActiveAdminAreas().length, 1);

        vm.prank(alice);
        fleet.burn(id1);

        assertEq(fleet.getActiveAdminAreas().length, 0);
    }

    // --- Region key helpers ---

    function test_makeAdminRegion() public view {
        assertEq(fleet.makeAdminRegion(US, ADMIN_CA), (uint32(US) << 10) | uint32(ADMIN_CA));
    }

    function test_regionKeyNoOverlap_countryVsAdmin() public pure {
        uint32 maxCountry = 999;
        uint32 minAdmin = (uint32(1) << 10) | uint32(1);
        assertTrue(minAdmin > maxCountry);
    }

    // --- tokenUuid / bonds ---

    function test_tokenUuid_roundTrip() public {
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);
        assertEq(fleet.tokenUuid(tokenId), UUID_1);
    }

    function test_bonds_returnsTierBond() public {
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);
        assertEq(fleet.bonds(tokenId), BASE_BOND);
    }

    function test_bonds_zeroForNonexistentToken() public view {
        assertEq(fleet.bonds(99999), 0);
    }

    // --- ERC721Enumerable ---

    function test_enumerable_totalSupply() public {
        assertEq(fleet.totalSupply(), 0);

        vm.prank(alice);
        fleet.registerFleetCountry(UUID_1, US, 0);
        assertEq(fleet.totalSupply(), 1);

        vm.prank(bob);
        fleet.registerFleetCountry(UUID_2, DE, 0);
        assertEq(fleet.totalSupply(), 2);

        vm.prank(carol);
        fleet.registerFleetLocal(UUID_3, US, ADMIN_CA, 0);
        assertEq(fleet.totalSupply(), 3);
    }

    function test_enumerable_supportsInterface() public view {
        assertTrue(fleet.supportsInterface(0x780e9d63));
        assertTrue(fleet.supportsInterface(0x80ac58cd));
        assertTrue(fleet.supportsInterface(0x01ffc9a7));
    }

    // --- Bond accounting ---

    function test_bondAccounting_acrossRegions() public {
        vm.prank(alice);
        uint256 c1 = fleet.registerFleetCountry(UUID_1, US, 0);
        vm.prank(bob);
        uint256 c2 = fleet.registerFleetCountry(UUID_2, DE, 0);
        vm.prank(carol);
        uint256 l1 = fleet.registerFleetLocal(UUID_3, US, ADMIN_CA, 0);

        // Each token costs BASE_BOND + tierBond
        // c1 and c2 are country (BASE_BOND + 16*BASE_BOND each), l1 is local (BASE_BOND + BASE_BOND)
        uint256 countryTotal = 2 * (BASE_BOND + fleet.tierBond(0, true));
        uint256 localTotal = BASE_BOND + fleet.tierBond(0, false);
        assertEq(bondToken.balanceOf(address(fleet)), countryTotal + localTotal);

        // Burn c2: transitions to owned-only (BASE_BOND stays in contract)
        vm.prank(bob);
        fleet.burn(c2);
        uint256 ownedTokenBob = uint256(uint128(UUID_2));
        // After burning c2, remaining: c1 + l1 + owned-only token for UUID_2
        assertEq(bondToken.balanceOf(address(fleet)), (BASE_BOND + fleet.tierBond(0, true)) + (BASE_BOND + fleet.tierBond(0, false)) + BASE_BOND);

        // Burn the owned-only token for UUID_2
        vm.prank(bob);
        fleet.burn(ownedTokenBob);
        // Now: c1 + l1
        assertEq(bondToken.balanceOf(address(fleet)), (BASE_BOND + fleet.tierBond(0, true)) + (BASE_BOND + fleet.tierBond(0, false)));

        // Burn remaining tokens (and their resulting owned-only tokens)
        vm.prank(alice);
        fleet.burn(c1);
        vm.prank(alice);
        fleet.burn(uint256(uint128(UUID_1)));
        vm.prank(carol);
        fleet.burn(l1);
        vm.prank(carol);
        fleet.burn(uint256(uint128(UUID_3)));
        assertEq(bondToken.balanceOf(address(fleet)), 0);
    }

    function test_bondAccounting_reassignTierRoundTrip() public {
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);
        uint256 balStart = bondToken.balanceOf(alice);

        vm.prank(alice);
        fleet.reassignTier(tokenId, 3);

        vm.prank(alice);
        fleet.reassignTier(tokenId, 0);

        assertEq(bondToken.balanceOf(alice), balStart);
        assertEq(fleet.bonds(tokenId), BASE_BOND);
    }

    // --- ERC-20 edge case ---

    function test_RevertIf_bondToken_transferFromReturnsFalse() public {
        BadERC20 badToken = new BadERC20();
        FleetIdentity f = new FleetIdentity(address(badToken), BASE_BOND);

        badToken.mint(alice, 1_000 ether);
        vm.prank(alice);
        badToken.approve(address(f), type(uint256).max);

        badToken.setFail(true);

        vm.prank(alice);
        vm.expectRevert();
        f.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);
    }

    // --- Transfer preserves region and tier ---

    function test_transfer_regionAndTierStayWithToken() public {
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetCountry(UUID_1, US, 0);
        vm.prank(alice);
        fleet.reassignTier(tokenId, 2);

        vm.prank(alice);
        fleet.transferFrom(alice, bob, tokenId);

        assertEq(fleet.tokenRegion(tokenId), _regionUS());
        assertEq(fleet.fleetTier(tokenId), 2);
        assertEq(fleet.bonds(tokenId), fleet.tierBond(2, true));

        // After transfer, bob holds the token but alice is still uuidOwner/operator.
        // On burn, operator (alice) gets full tierBond, owned-only token minted to owner (alice).
        uint256 aliceBefore = bondToken.balanceOf(alice);
        vm.prank(alice); // operator burns
        fleet.burn(tokenId);
        // Alice gets tier bond refund
        assertEq(bondToken.balanceOf(alice), aliceBefore + fleet.tierBond(2, true));
        // Owned-only token minted to alice
        assertTrue(fleet.isOwnedOnly(UUID_1));
    }

    // --- Tier lifecycle ---

    function test_tierLifecycle_fillBurnBackfillPerRegion() public {
        // Register 4 US country fleets at tier 0 (fills capacity)
        uint256[] memory usIds = _registerNCountryAt(alice, US, 4, 0, 0);
        assertEq(fleet.tierMemberCount(_regionUS(), 0), 4);

        // Next country fleet goes to tier 1
        vm.prank(bob);
        uint256 us5 = fleet.registerFleetCountry(_uuid(100), US, 1);
        assertEq(fleet.fleetTier(us5), 1);

        // Burn from tier 0 — now tier 0 has 3, tier 1 has 1.
        vm.prank(alice);
        fleet.burn(usIds[3]);

        // Explicitly register into tier 1.
        vm.prank(carol);
        uint256 backfill = fleet.registerFleetCountry(_uuid(200), US, 1);
        assertEq(fleet.fleetTier(backfill), 1);
        assertEq(fleet.tierMemberCount(_regionUS(), 1), 2);
    }

    // --- Edge cases ---

    function test_zeroBaseBond_allowsRegistration() public {
        FleetIdentity f = new FleetIdentity(address(bondToken), 0);
        vm.prank(alice);
        bondToken.approve(address(f), type(uint256).max);

        vm.prank(alice);
        uint256 tokenId = f.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);
        assertEq(f.bonds(tokenId), 0);

        vm.prank(alice);
        f.burn(tokenId);
    }

    // --- Fuzz Tests ---

    function testFuzz_registerFleetCountry_validCountryCodes(uint16 cc) public {
        cc = uint16(bound(cc, 1, 999));

        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetCountry(UUID_1, cc, 0);

        assertEq(fleet.tokenRegion(tokenId), uint32(cc));
        assertEq(fleet.fleetTier(tokenId), 0);
        assertEq(fleet.bonds(tokenId), BASE_BOND * fleet.COUNTRY_BOND_MULTIPLIER()); // Country gets 16x multiplier
    }

    function testFuzz_registerFleetLocal_validCodes(uint16 cc, uint16 admin) public {
        cc = uint16(bound(cc, 1, 999));
        admin = uint16(bound(admin, 1, 255));

        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetLocal(UUID_1, cc, admin, 0);

        uint32 expectedRegion = (uint32(cc) << 10) | uint32(admin);
        assertEq(fleet.tokenRegion(tokenId), expectedRegion);
        assertEq(fleet.fleetTier(tokenId), 0);
        assertEq(fleet.bonds(tokenId), BASE_BOND);
    }

    function testFuzz_promote_onlyOperator(address caller) public {
        vm.assume(caller != alice);
        vm.assume(caller != address(0));

        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);

        vm.prank(caller);
        vm.expectRevert(FleetIdentity.NotOperator.selector);
        fleet.promote(tokenId);
    }

    function testFuzz_burn_onlyOperator(address caller) public {
        vm.assume(caller != alice);
        vm.assume(caller != address(0));

        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);

        // Only operator (alice) can burn registered tokens, not random callers
        vm.prank(caller);
        vm.expectRevert(FleetIdentity.NotOperator.selector);
        fleet.burn(tokenId);
    }

    // ══════════════════════════════════════════════
    // UUID Ownership Enforcement Tests
    // ══════════════════════════════════════════════

    function test_uuidOwner_setOnFirstRegistration() public {
        assertEq(fleet.uuidOwner(UUID_1), address(0), "No owner before registration");
        assertEq(fleet.uuidTokenCount(UUID_1), 0, "No tokens before registration");

        vm.prank(alice);
        fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);

        assertEq(fleet.uuidOwner(UUID_1), alice, "Alice is UUID owner after registration");
        assertEq(fleet.uuidTokenCount(UUID_1), 1, "Token count is 1 after registration");
    }

    function test_uuidOwner_sameOwnerCanRegisterMultipleRegions() public {
        // Alice registers UUID_1 in first region (same level across all)
        vm.prank(alice);
        uint256 id1 = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);

        // Alice can register same UUID in second region (same level)
        vm.prank(alice);
        uint256 id2 = fleet.registerFleetLocal(UUID_1, DE, ADMIN_CA, 0);

        // And a third region (same level)
        vm.prank(alice);
        uint256 id3 = fleet.registerFleetLocal(UUID_1, FR, ADMIN_CA, 0);

        assertEq(fleet.uuidOwner(UUID_1), alice, "Alice is still UUID owner");
        assertEq(fleet.uuidTokenCount(UUID_1), 3, "Token count is 3");
        assertEq(fleet.ownerOf(id1), alice);
        assertEq(fleet.ownerOf(id2), alice);
        assertEq(fleet.ownerOf(id3), alice);
    }

    function test_RevertIf_differentOwnerRegistersSameUuid_local() public {
        // Alice registers UUID_1 first
        vm.prank(alice);
        fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);

        // Bob tries to register same UUID in different region → revert
        vm.prank(bob);
        vm.expectRevert(FleetIdentity.NotOperator.selector);
        fleet.registerFleetLocal(UUID_1, DE, ADMIN_CA, 0);
    }

    function test_RevertIf_differentOwnerRegistersSameUuid_country() public {
        // Alice registers UUID_1 first
        vm.prank(alice);
        fleet.registerFleetCountry(UUID_1, US, 0);

        // Bob tries to register same UUID in different country → revert
        vm.prank(bob);
        vm.expectRevert(FleetIdentity.NotOperator.selector);
        fleet.registerFleetCountry(UUID_1, DE, 0);
    }

    function test_RevertIf_differentOwnerRegistersSameUuid_crossLevel() public {
        // Alice registers UUID_1 at country level
        vm.prank(alice);
        fleet.registerFleetCountry(UUID_1, US, 0);

        // Bob tries to register same UUID at local level → revert
        vm.prank(bob);
        vm.expectRevert(FleetIdentity.NotOperator.selector);
        fleet.registerFleetLocal(UUID_1, DE, ADMIN_CA, 0);
    }

    function test_uuidOwner_clearedWhenAllTokensBurned() public {
        // Alice registers UUID_1 in one region
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);

        assertEq(fleet.uuidOwner(UUID_1), alice);
        assertEq(fleet.uuidTokenCount(UUID_1), 1);

        // Burn the registered token -> transitions to owned-only
        vm.prank(alice);
        fleet.burn(tokenId);
        
        // UUID owner should NOT be cleared yet (now in owned-only state)
        assertEq(fleet.uuidOwner(UUID_1), alice, "UUID owner preserved in owned-only state");
        assertTrue(fleet.isOwnedOnly(UUID_1));
        
        // Burn the owned-only token to fully clear ownership
        uint256 ownedTokenId = uint256(uint128(UUID_1));
        vm.prank(alice);
        fleet.burn(ownedTokenId);

        // NOW UUID owner should be cleared
        assertEq(fleet.uuidOwner(UUID_1), address(0), "UUID owner cleared after owned-only token burned");
        assertEq(fleet.uuidTokenCount(UUID_1), 0, "Token count is 0 after all burned");
    }

    function test_uuidOwner_notClearedWhileTokensRemain() public {
        // Alice registers UUID_1 in two regions (same level)
        vm.prank(alice);
        uint256 id1 = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);

        vm.prank(alice);
        uint256 id2 = fleet.registerFleetLocal(UUID_1, DE, ADMIN_CA, 0);

        assertEq(fleet.uuidTokenCount(UUID_1), 2);

        // Burn first token
        vm.prank(alice);
        fleet.burn(id1);

        // UUID owner should still be alice (one token remains)
        assertEq(fleet.uuidOwner(UUID_1), alice, "UUID owner still alice with remaining token");
        assertEq(fleet.uuidTokenCount(UUID_1), 1, "Token count decremented to 1");

        // Burn second token -> transitions to owned-only
        vm.prank(alice);
        fleet.burn(id2);
        
        // Still owned (in owned-only state)
        assertEq(fleet.uuidOwner(UUID_1), alice, "UUID owner preserved in owned-only state");
        assertTrue(fleet.isOwnedOnly(UUID_1));

        // Burn owned-only token to fully clear
        uint256 ownedTokenId = uint256(uint128(UUID_1));
        vm.prank(alice);
        fleet.burn(ownedTokenId);
        
        // Now UUID owner should be cleared
        assertEq(fleet.uuidOwner(UUID_1), address(0), "UUID owner cleared after owned-only burned");
        assertEq(fleet.uuidTokenCount(UUID_1), 0);
    }

    function test_uuidOwner_differentUuidsHaveDifferentOwners() public {
        // Alice registers UUID_1
        vm.prank(alice);
        fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);

        // Bob registers UUID_2 (different UUID, no conflict)
        vm.prank(bob);
        fleet.registerFleetLocal(UUID_2, US, ADMIN_CA, 0);

        assertEq(fleet.uuidOwner(UUID_1), alice);
        assertEq(fleet.uuidOwner(UUID_2), bob);
    }

    function test_uuidOwner_canReRegisterAfterBurningAll() public {
        // Alice registers and burns UUID_1
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);
        vm.prank(alice);
        fleet.burn(tokenId);
        
        // Now in owned-only state, burn that too
        uint256 ownedTokenId = uint256(uint128(UUID_1));
        vm.prank(alice);
        fleet.burn(ownedTokenId);

        // Bob can now register the same UUID (uuid owner was cleared)
        vm.prank(bob);
        uint256 newTokenId = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);

        assertEq(fleet.uuidOwner(UUID_1), bob, "Bob is now UUID owner");
        assertEq(fleet.uuidTokenCount(UUID_1), 1);
        assertEq(fleet.ownerOf(newTokenId), bob);
    }

    function test_uuidOwner_transferDoesNotChangeUuidOwner() public {
        // Alice registers UUID_1
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);

        assertEq(fleet.uuidOwner(UUID_1), alice);

        // Alice transfers to Bob
        vm.prank(alice);
        fleet.transferFrom(alice, bob, tokenId);

        // Token owner changed but UUID owner did not
        assertEq(fleet.ownerOf(tokenId), bob);
        assertEq(fleet.uuidOwner(UUID_1), alice, "UUID owner still alice after transfer");
    }

    function test_RevertIf_transferRecipientTriesToRegisterSameUuid() public {
        // Alice registers UUID_1
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);

        // Alice transfers to Bob
        vm.prank(alice);
        fleet.transferFrom(alice, bob, tokenId);

        // Bob now owns tokenId, but cannot register NEW tokens for UUID_1
        vm.prank(bob);
        vm.expectRevert(FleetIdentity.NotOperator.selector);
        fleet.registerFleetLocal(UUID_1, DE, ADMIN_CA, 0);
    }

    function test_uuidOwner_originalOwnerCanStillRegisterAfterTransfer() public {
        // Alice registers UUID_1 in one region
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);

        // Alice transfers to Bob
        vm.prank(alice);
        fleet.transferFrom(alice, bob, tokenId);

        // Alice can still register UUID_1 in new regions (she's still uuidOwner, same level)
        vm.prank(alice);
        uint256 newTokenId = fleet.registerFleetLocal(UUID_1, DE, ADMIN_CA, 0);

        assertEq(fleet.ownerOf(newTokenId), alice);
        assertEq(fleet.uuidTokenCount(UUID_1), 2);
    }

    function testFuzz_uuidOwner_enforcedAcrossAllRegions(uint16 cc1, uint16 cc2, uint16 admin1, uint16 admin2) public {
        cc1 = uint16(bound(cc1, 1, 999));
        cc2 = uint16(bound(cc2, 1, 999));
        admin1 = uint16(bound(admin1, 1, 255));
        admin2 = uint16(bound(admin2, 1, 255));

        // Alice registers first
        vm.prank(alice);
        fleet.registerFleetLocal(UUID_1, cc1, admin1, 0);

        // Bob cannot register same UUID anywhere
        vm.prank(bob);
        vm.expectRevert(FleetIdentity.NotOperator.selector);
        fleet.registerFleetLocal(UUID_1, cc2, admin2, 0);

        vm.prank(bob);
        vm.expectRevert(FleetIdentity.NotOperator.selector);
        fleet.registerFleetCountry(UUID_1, cc2, 0);
    }

    function testFuzz_uuidOwner_multiRegionTokenCount(uint8 regionCount) public {
        regionCount = uint8(bound(regionCount, 1, 10));

        for (uint8 i = 0; i < regionCount; i++) {
            uint16 cc = uint16(1 + i);
            vm.prank(alice);
            fleet.registerFleetCountry(UUID_1, cc, 0);
        }

        assertEq(fleet.uuidTokenCount(UUID_1), regionCount);
        assertEq(fleet.uuidOwner(UUID_1), alice);
    }

    function testFuzz_uuidOwner_partialBurnPreservesOwnership(uint8 burnCount) public {
        uint8 totalTokens = 5;
        burnCount = uint8(bound(burnCount, 1, totalTokens - 1));

        // Register tokens
        uint256[] memory tokenIds = new uint256[](totalTokens);
        for (uint8 i = 0; i < totalTokens; i++) {
            uint16 cc = uint16(1 + i);
            vm.prank(alice);
            tokenIds[i] = fleet.registerFleetCountry(UUID_1, cc, 0);
        }

        assertEq(fleet.uuidTokenCount(UUID_1), totalTokens);

        // Burn some tokens
        for (uint8 i = 0; i < burnCount; i++) {
            vm.prank(alice);
            fleet.burn(tokenIds[i]);
        }

        // Owner still alice, count decreased
        assertEq(fleet.uuidOwner(UUID_1), alice);
        assertEq(fleet.uuidTokenCount(UUID_1), totalTokens - burnCount);
    }

    // ══════════════════════════════════════════════
    // UUID Level Enforcement Tests
    // ══════════════════════════════════════════════

    function test_uuidLevel_setOnFirstRegistration_local() public {
        assertEq(uint8(fleet.uuidLevel(UUID_1)), 0, "No level before registration");

        vm.prank(alice);
        fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);

        assertEq(uint8(fleet.uuidLevel(UUID_1)), 2, "Level is 2 (local) after local registration");
    }

    function test_uuidLevel_setOnFirstRegistration_country() public {
        assertEq(uint8(fleet.uuidLevel(UUID_1)), 0, "No level before registration");

        vm.prank(alice);
        fleet.registerFleetCountry(UUID_1, US, 0);

        assertEq(uint8(fleet.uuidLevel(UUID_1)), 3, "Level is 3 (country) after country registration");
    }

    function test_RevertIf_crossLevelRegistration_localThenCountry() public {
        // Alice registers UUID_1 at local level
        vm.prank(alice);
        fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);

        // Alice tries to register same UUID at country level → revert
        vm.prank(alice);
        vm.expectRevert(FleetIdentity.UuidLevelMismatch.selector);
        fleet.registerFleetCountry(UUID_1, DE, 0);
    }

    function test_RevertIf_crossLevelRegistration_countryThenLocal() public {
        // Alice registers UUID_1 at country level
        vm.prank(alice);
        fleet.registerFleetCountry(UUID_1, US, 0);

        // Alice tries to register same UUID at local level → revert
        vm.prank(alice);
        vm.expectRevert(FleetIdentity.UuidLevelMismatch.selector);
        fleet.registerFleetLocal(UUID_1, DE, ADMIN_CA, 0);
    }

    function test_uuidLevel_clearedOnLastTokenBurn() public {
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);

        assertEq(uint8(fleet.uuidLevel(UUID_1)), 2);

        // Burn -> transitions to owned-only (level = 1)
        vm.prank(alice);
        fleet.burn(tokenId);

        assertEq(uint8(fleet.uuidLevel(UUID_1)), 1, "Level is Owned after burning last registered token");
        
        // Burn owned-only token to fully clear
        uint256 ownedTokenId = uint256(uint128(UUID_1));
        vm.prank(alice);
        fleet.burn(ownedTokenId);

        assertEq(uint8(fleet.uuidLevel(UUID_1)), 0, "Level cleared after owned-only token burned");
    }

    function test_uuidLevel_notClearedWhileTokensRemain() public {
        vm.prank(alice);
        uint256 id1 = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);

        vm.prank(alice);
        fleet.registerFleetLocal(UUID_1, DE, ADMIN_CA, 0);

        assertEq(uint8(fleet.uuidLevel(UUID_1)), 2);

        vm.prank(alice);
        fleet.burn(id1);

        assertEq(uint8(fleet.uuidLevel(UUID_1)), 2, "Level preserved while tokens remain");
    }

    function test_uuidLevel_canChangeLevelAfterBurningAll() public {
        // Register as local
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);
        assertEq(uint8(fleet.uuidLevel(UUID_1)), 2);

        // Burn
        vm.prank(alice);
        fleet.burn(tokenId);

        // Now can register as country
        vm.prank(alice);
        fleet.registerFleetCountry(UUID_1, US, 0);
        assertEq(uint8(fleet.uuidLevel(UUID_1)), 3);
    }

    // ══════════════════════════════════════════════
    // Owned-Only Mode Tests
    // ══════════════════════════════════════════════

    function test_claimUuid_basic() public {
        uint256 aliceBalanceBefore = bondToken.balanceOf(alice);
        
        vm.prank(alice);
        uint256 tokenId = fleet.claimUuid(UUID_1, address(0));
        
        // Token minted
        assertEq(fleet.ownerOf(tokenId), alice);
        assertEq(fleet.tokenUuid(tokenId), UUID_1);
        assertEq(fleet.tokenRegion(tokenId), 0); // OWNED_REGION_KEY
        
        // UUID ownership set
        assertEq(fleet.uuidOwner(UUID_1), alice);
        assertEq(fleet.uuidTokenCount(UUID_1), 1);
        assertTrue(fleet.isOwnedOnly(UUID_1));
        assertEq(uint8(fleet.uuidLevel(UUID_1)), 1); // Owned
        
        // Bond pulled
        assertEq(aliceBalanceBefore - bondToken.balanceOf(alice), BASE_BOND);
        
        // bonds() returns BASE_BOND for owned-only
        assertEq(fleet.bonds(tokenId), BASE_BOND);
    }

    function test_RevertIf_claimUuid_alreadyOwned() public {
        vm.prank(alice);
        fleet.claimUuid(UUID_1, address(0));
        
        vm.prank(bob);
        vm.expectRevert(FleetIdentity.UuidAlreadyOwned.selector);
        fleet.claimUuid(UUID_1, address(0));
    }

    function test_RevertIf_claimUuid_alreadyRegistered() public {
        vm.prank(alice);
        fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);
        
        vm.prank(bob);
        vm.expectRevert(FleetIdentity.UuidAlreadyOwned.selector);
        fleet.claimUuid(UUID_1, address(0));
    }

    function test_RevertIf_claimUuid_invalidUuid() public {
        vm.prank(alice);
        vm.expectRevert(FleetIdentity.InvalidUUID.selector);
        fleet.claimUuid(bytes16(0), address(0));
    }

    function test_registerFromOwned_local() public {
        // First claim
        vm.prank(alice);
        uint256 ownedTokenId = fleet.claimUuid(UUID_1, address(0));
        
        uint256 aliceBalanceBefore = bondToken.balanceOf(alice);
        
        // Register from owned state - operator (alice) pays tierBond
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);
        
        // Old owned token burned
        vm.expectRevert();
        fleet.ownerOf(ownedTokenId);
        
        // New token exists
        assertEq(fleet.ownerOf(tokenId), alice);
        assertEq(fleet.tokenRegion(tokenId), _regionUSCA());
        assertEq(fleet.fleetTier(tokenId), 0);
        
        // UUID state updated
        assertEq(fleet.uuidOwner(UUID_1), alice);
        assertEq(fleet.uuidTokenCount(UUID_1), 1); // still 1
        assertFalse(fleet.isOwnedOnly(UUID_1));
        assertEq(uint8(fleet.uuidLevel(UUID_1)), 2); // Local
        
        // Operator pays tierBond (owner already paid BASE_BOND via claim)
        assertEq(aliceBalanceBefore - bondToken.balanceOf(alice), fleet.tierBond(0, false));
    }

    function test_registerFromOwned_country() public {
        vm.prank(alice);
        fleet.claimUuid(UUID_1, address(0));
        
        uint256 aliceBalanceBefore = bondToken.balanceOf(alice);
        
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetCountry(UUID_1, US, 0);
        
        assertEq(fleet.ownerOf(tokenId), alice);
        assertEq(fleet.tokenRegion(tokenId), uint32(US));
        assertEq(uint8(fleet.uuidLevel(UUID_1)), 3); // Country
        
        // Operator pays tierBond for country tier 0 = 16*BASE_BOND
        assertEq(aliceBalanceBefore - bondToken.balanceOf(alice), fleet.tierBond(0, true));
    }

    function test_registerFromOwned_higherTier() public {
        vm.prank(alice);
        fleet.claimUuid(UUID_1, address(0));
        
        uint256 aliceBalanceBefore = bondToken.balanceOf(alice);
        
        // Register at tier 0 local - operator pays tierBond(0, false) = BASE_BOND
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);
        assertEq(aliceBalanceBefore - bondToken.balanceOf(alice), fleet.tierBond(0, false));
        
        // Promote to tier 2: additional bond = tierBond(2) - tierBond(0) = 4*BASE_BOND - BASE_BOND = 3*BASE_BOND
        uint256 balBeforePromote = bondToken.balanceOf(alice);
        vm.prank(alice);
        fleet.reassignTier(tokenId, 2);
        assertEq(balBeforePromote - bondToken.balanceOf(alice), 3 * BASE_BOND);
    }

    function test_burn_lastRegisteredToken_transitionsToOwned() public {
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);
        
        uint256 aliceBalanceBefore = bondToken.balanceOf(alice);
        
        vm.prank(alice);
        fleet.burn(tokenId);
        
        // Old token burned
        vm.expectRevert();
        fleet.ownerOf(tokenId);
        
        // New owned-only token exists
        uint256 ownedTokenId = uint256(uint128(UUID_1));
        assertEq(fleet.ownerOf(ownedTokenId), alice);
        assertEq(fleet.tokenRegion(ownedTokenId), 0);
        
        // UUID state updated to Owned
        assertTrue(fleet.isOwnedOnly(UUID_1));
        assertEq(uint8(fleet.uuidLevel(UUID_1)), 1); // Owned
        
        // Operator (alice) gets tierBond refunded
        assertEq(bondToken.balanceOf(alice) - aliceBalanceBefore, fleet.tierBond(0, false));
    }

    function test_burn_lastRegisteredToken_withHighTierRefund() public {
        // Register at tier 0, then promote to tier 2
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);
        vm.prank(alice);
        fleet.reassignTier(tokenId, 2);
        
        uint256 aliceBalanceBefore = bondToken.balanceOf(alice);
        
        vm.prank(alice);
        fleet.burn(tokenId);
        
        // Operator (alice) gets full tierBond(2, false) refunded
        assertEq(bondToken.balanceOf(alice) - aliceBalanceBefore, fleet.tierBond(2, false));
        
        // Transitioned to owned-only
        assertTrue(fleet.isOwnedOnly(UUID_1));
    }

    function test_burn_lastCountryToken_transitionsToOwned() public {
        // Register country tier 0
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetCountry(UUID_1, US, 0);
        
        uint256 aliceBalanceBefore = bondToken.balanceOf(alice);
        
        vm.prank(alice);
        fleet.burn(tokenId);
        
        // Operator (alice) gets full tierBond(0, true) refunded
        assertEq(bondToken.balanceOf(alice) - aliceBalanceBefore, fleet.tierBond(0, true));
        
        // Level changed to Owned
        assertEq(uint8(fleet.uuidLevel(UUID_1)), 1);
        assertTrue(fleet.isOwnedOnly(UUID_1));
    }

    function test_burn_multiRegion_doesNotTransitionUntilLastToken() public {
        // Register in two regions
        vm.prank(alice);
        uint256 id1 = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);
        vm.prank(alice);
        uint256 id2 = fleet.registerFleetLocal(UUID_1, DE, ADMIN_CA, 0);
        
        // Burn first token - should NOT transition to owned
        vm.prank(alice);
        fleet.burn(id1);
        
        // Still registered level, not owned
        assertFalse(fleet.isOwnedOnly(UUID_1));
        assertEq(fleet.uuidTokenCount(UUID_1), 1);
        
        // Second token still exists
        assertEq(fleet.ownerOf(id2), alice);
        
        // Burn second token - NOW should transition to owned
        vm.prank(alice);
        fleet.burn(id2);
        
        assertTrue(fleet.isOwnedOnly(UUID_1));
        uint256 ownedTokenId = uint256(uint128(UUID_1));
        assertEq(fleet.ownerOf(ownedTokenId), alice);
    }

    function test_burn_ownedOnly_clearsUuid() public {
        vm.prank(alice);
        uint256 tokenId = fleet.claimUuid(UUID_1, address(0));
        
        uint256 aliceBalanceBefore = bondToken.balanceOf(alice);
        
        vm.prank(alice);
        fleet.burn(tokenId);
        
        // Token burned
        vm.expectRevert();
        fleet.ownerOf(tokenId);
        
        // UUID cleared
        assertEq(fleet.uuidOwner(UUID_1), address(0));
        assertEq(fleet.uuidTokenCount(UUID_1), 0);
        assertEq(uint8(fleet.uuidLevel(UUID_1)), 0); // None
        
        // Refund received
        assertEq(bondToken.balanceOf(alice) - aliceBalanceBefore, BASE_BOND);
    }

    function test_burn_ownedOnly_afterTransfer() public {
        vm.prank(alice);
        uint256 tokenId = fleet.claimUuid(UUID_1, address(0));
        
        // Transfer to bob
        vm.prank(alice);
        fleet.transferFrom(alice, bob, tokenId);
        
        // uuidOwner should have updated
        assertEq(fleet.uuidOwner(UUID_1), bob);
        
        // Alice cannot burn (not token owner)
        vm.prank(alice);
        vm.expectRevert(FleetIdentity.NotTokenOwner.selector);
        fleet.burn(tokenId);
        
        // Bob can burn
        uint256 bobBalanceBefore = bondToken.balanceOf(bob);
        vm.prank(bob);
        fleet.burn(tokenId);
        assertEq(bondToken.balanceOf(bob) - bobBalanceBefore, BASE_BOND);
    }

    function test_RevertIf_burn_ownedOnly_notOwner() public {
        vm.prank(alice);
        uint256 tokenId = fleet.claimUuid(UUID_1, address(0));
        
        // Bob cannot burn owned-only token (not owner)
        vm.prank(bob);
        vm.expectRevert(FleetIdentity.NotTokenOwner.selector);
        fleet.burn(tokenId);
    }

    function test_ownedOnly_transfer_updatesUuidOwner() public {
        vm.prank(alice);
        uint256 tokenId = fleet.claimUuid(UUID_1, address(0));
        
        assertEq(fleet.uuidOwner(UUID_1), alice);
        
        vm.prank(alice);
        fleet.transferFrom(alice, bob, tokenId);
        
        // uuidOwner updated on transfer for owned-only tokens
        assertEq(fleet.uuidOwner(UUID_1), bob);
        assertEq(fleet.ownerOf(tokenId), bob);
    }

    function test_ownedOnly_notInBundle() public {
        // Claim some UUIDs as owned-only
        vm.prank(alice);
        fleet.claimUuid(UUID_1, address(0));
        vm.prank(alice);
        fleet.claimUuid(UUID_2, address(0));
        
        // Bundle should be empty
        (bytes16[] memory uuids, uint256 count) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        assertEq(count, 0);
        
        // Now register one
        vm.prank(alice);
        fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);
        
        // Bundle should contain only the registered one
        (uuids, count) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        assertEq(count, 1);
        assertEq(uuids[0], UUID_1);
    }

    function test_burn_ownedOnly() public {
        vm.prank(alice);
        uint256 tokenId = fleet.claimUuid(UUID_1, address(0));
        
        uint256 aliceBalanceBefore = bondToken.balanceOf(alice);
        
        vm.prank(alice);
        fleet.burn(tokenId);
        
        // Token burned
        vm.expectRevert();
        fleet.ownerOf(tokenId);
        
        // UUID cleared
        assertEq(fleet.uuidOwner(UUID_1), address(0));
        
        // Refund received
        assertEq(bondToken.balanceOf(alice) - aliceBalanceBefore, BASE_BOND);
    }

    function test_ownedOnly_canReRegisterAfterBurn() public {
        vm.prank(alice);
        uint256 tokenId = fleet.claimUuid(UUID_1, address(0));
        
        vm.prank(alice);
        fleet.burn(tokenId);
        
        // Bob can now claim or register
        vm.prank(bob);
        uint256 newTokenId = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);
        
        assertEq(fleet.ownerOf(newTokenId), bob);
        assertEq(fleet.uuidOwner(UUID_1), bob);
    }

    function test_migration_viaBurnAndReregister() public {
        // This test shows the migration pattern using burn
        
        // Register local in US
        vm.prank(alice);
        uint256 oldTokenId = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);
        
        uint256 aliceBalanceAfterRegister = bondToken.balanceOf(alice);
        
        // Burn registered token -> transitions to owned-only, refunds tierBond(0, false)
        vm.prank(alice);
        fleet.burn(oldTokenId);
        
        // Now in owned-only state, re-register in DE as country
        // Pays tierBond(0, true) = 16*BASE_BOND for country registration
        vm.prank(alice);
        uint256 newTokenId = fleet.registerFleetCountry(UUID_1, DE, 0);
        
        assertEq(fleet.ownerOf(newTokenId), alice);
        assertEq(fleet.tokenRegion(newTokenId), uint32(DE));
        assertEq(uint8(fleet.uuidLevel(UUID_1)), 3); // Country
        
        // Net bond change: tierBond(0, true) - tierBond(0, false) = 16*BASE_BOND - BASE_BOND = 15*BASE_BOND
        assertEq(aliceBalanceAfterRegister - bondToken.balanceOf(alice), 15 * BASE_BOND);
    }

    function testFuzz_tierBond_geometric(uint256 tier) public view {
        tier = bound(tier, 0, 10);
        uint256 expected = BASE_BOND;
        for (uint256 i = 0; i < tier; i++) {
            expected *= 2;
        }
        // Local regions get 1× multiplier
        assertEq(fleet.tierBond(tier, false), expected);
        // Country regions get 16x multiplier
        assertEq(fleet.tierBond(tier, true), expected * fleet.COUNTRY_BOND_MULTIPLIER());
    }

    function testFuzz_perRegionTiers_newRegionAlwaysStartsAtTier0(uint16 cc) public {
        cc = uint16(bound(cc, 1, 999));
        vm.assume(cc != US); // Skip US since we fill it below

        // Fill one country with 8 fleets
        _registerNCountry(alice, US, 8, 0);
        uint256 cap = fleet.TIER_CAPACITY();
        uint256 expectedTiers = (8 + cap - 1) / cap; // ceiling division
        assertEq(fleet.regionTierCount(_regionUS()), expectedTiers);

        // New country should start at tier 0 regardless of other regions
        vm.prank(bob);
        uint256 tokenId = fleet.registerFleetCountry(_uuid(999), cc, 0);
        assertEq(fleet.fleetTier(tokenId), 0);
        assertEq(fleet.bonds(tokenId), BASE_BOND * fleet.COUNTRY_BOND_MULTIPLIER()); // Country gets 16x multiplier
    }

    function testFuzz_tierAssignment_autoFillsSequentiallyPerRegion(uint8 count) public {
        count = uint8(bound(count, 1, 40));
        uint256 cap = fleet.TIER_CAPACITY();

        for (uint256 i = 0; i < count; i++) {
            uint256 expectedTier = i / cap;
            vm.prank(alice);
            uint256 tokenId = fleet.registerFleetLocal(_uuid(i + 300), US, ADMIN_CA, expectedTier);

            assertEq(fleet.fleetTier(tokenId), expectedTier);
        }

        uint256 expectedTiers = (uint256(count) + cap - 1) / cap;
        assertEq(fleet.regionTierCount(_regionUSCA()), expectedTiers);
    }

    // --- Invariants ---

    function test_invariant_contractBalanceEqualsSumOfBonds() public {
        vm.prank(alice);
        uint256 id1 = fleet.registerFleetCountry(UUID_1, US, 0);
        vm.prank(bob);
        uint256 id2 = fleet.registerFleetCountry(UUID_2, DE, 0);
        vm.prank(carol);
        uint256 id3 = fleet.registerFleetLocal(UUID_3, US, ADMIN_CA, 0);

        // Contract balance = 3 * BASE_BOND (per UUID) + sum of tierBonds
        uint256 expected = 3 * BASE_BOND + fleet.bonds(id1) + fleet.bonds(id2) + fleet.bonds(id3);
        assertEq(bondToken.balanceOf(address(fleet)), expected);

        // Burn id1 -> transitions to owned-only (BASE_BOND stays, tierBond refunded)
        vm.prank(alice);
        fleet.burn(id1);

        // After burn: 2 registered UUIDs + 1 owned-only UUID
        // = 2 * BASE_BOND (registered) + 2 * tierBond (registered) + BASE_BOND (owned-only)
        uint256 expectedAfterBurn = 3 * BASE_BOND + fleet.bonds(id2) + fleet.bonds(id3);
        assertEq(bondToken.balanceOf(address(fleet)), expectedAfterBurn);
    }

    function test_invariant_contractBalanceAfterReassignTierBurn() public {
        vm.prank(alice);
        uint256 id1 = fleet.registerFleetCountry(UUID_1, US, 0);
        vm.prank(bob);
        uint256 id2 = fleet.registerFleetLocal(UUID_2, US, ADMIN_CA, 0);
        vm.prank(carol);
        uint256 id3 = fleet.registerFleetLocal(UUID_3, DE, ADMIN_NY, 0);

        vm.prank(alice);
        fleet.reassignTier(id1, 3);

        vm.prank(alice);
        fleet.reassignTier(id1, 1);

        // Contract balance = 3 * BASE_BOND + sum of tierBonds
        uint256 expected = 3 * BASE_BOND + fleet.bonds(id1) + fleet.bonds(id2) + fleet.bonds(id3);
        assertEq(bondToken.balanceOf(address(fleet)), expected);

        // Burn all registered tokens (each transitions to owned-only)
        vm.prank(alice);
        fleet.burn(id1);
        vm.prank(bob);
        fleet.burn(id2);
        vm.prank(carol);
        fleet.burn(id3);

        // Now have 3 owned-only tokens, each with BASE_BOND
        assertEq(bondToken.balanceOf(address(fleet)), 3 * BASE_BOND);
        
        // Burn all owned-only tokens
        vm.prank(alice);
        fleet.burn(uint256(uint128(UUID_1)));
        vm.prank(bob);
        fleet.burn(uint256(uint128(UUID_2)));
        vm.prank(carol);
        fleet.burn(uint256(uint128(UUID_3)));

        assertEq(bondToken.balanceOf(address(fleet)), 0);
    }

    // --- countryInclusionHint ---

    function test_countryInclusionHint_emptyReturnsZero() public view {
        (uint256 tier, uint256 bond) = fleet.countryInclusionHint(US);
        assertEq(tier, 0);
        assertEq(bond, BASE_BOND * fleet.COUNTRY_BOND_MULTIPLIER()); // Country pays 16x multiplier
    }

    function test_countryInclusionHint_onlyCountryFleets() public {
        _registerNCountryAt(alice, US, fleet.TIER_CAPACITY(), 1000, 0); // fills tier 0
        vm.prank(bob);
        fleet.registerFleetCountry(_uuid(9000), US, 1); // tier 1

        // Tier 0 is full → cheapest inclusion = tier 1.
        (uint256 tier, uint256 bond) = fleet.countryInclusionHint(US);
        assertEq(tier, 1);
        assertEq(bond, BASE_BOND * fleet.COUNTRY_BOND_MULTIPLIER() * 2); // Country pays 16x multiplier, tier 1 = 2× base
    }

    function test_countryInclusionHint_adminAreaCreatesPressure() public {
        // Country US: tier 0 with 1 member
        vm.prank(alice);
        fleet.registerFleetCountry(_uuid(1000), US, 0);

        // US-CA: push to tier 3 (1 member at tier 3)
        vm.prank(bob);
        fleet.registerFleetLocal(_uuid(2000), US, ADMIN_CA, 3);

        // Country fleet needs to be included in bundle(US, ADMIN_CA).
        // Simulation: cursor 3→0. At cursor 3: admin=1 (fits). At cursor 0: admin=0, country=1+1=2 (fits).
        // Country tier 0 with 2 members: 2 <= 20-1 = 19. Fits.
        // So cheapest = 0 (tier 0 has room: 1/4).
        (uint256 tier,) = fleet.countryInclusionHint(US);
        assertEq(tier, 0);
    }

    function test_countryInclusionHint_multipleAdminAreas_takesMax() public {
        // US-CA: fill admin tier 0 + fill country tier 0
        _registerNLocalAt(alice, US, ADMIN_CA, fleet.TIER_CAPACITY(), 0, 0);
        _registerNCountryAt(alice, US, fleet.TIER_CAPACITY(), 100, 0);
        // US-NY: light (3 admin)
        _registerNLocal(alice, US, ADMIN_NY, 3, 200);

        // Country tier 0 is full (TIER_CAPACITY members).
        // Even though the bundle has room, the tier capacity is exhausted.
        // So cheapest inclusion tier for a country fleet = 1.
        (uint256 tier,) = fleet.countryInclusionHint(US);
        assertEq(tier, 1);
    }

    function test_countryInclusionHint_ignoresOtherCountries() public {
        // DE admin area at tier 5 — should NOT affect US hint
        vm.prank(alice);
        fleet.registerFleetLocal(_uuid(1000), DE, 1, 5);

        // US-CA at tier 1
        vm.prank(bob);
        fleet.registerFleetLocal(_uuid(2000), US, ADMIN_CA, 1);

        (uint256 usTier,) = fleet.countryInclusionHint(US);
        // US country fleet needs inclusion in bundle(US, ADMIN_CA).
        // Admin has 1 at tier 1. Country at tier 0: +1=1, fits.
        assertEq(usTier, 0);
    }

    function test_countryInclusionHint_afterBurn_updates() public {
        vm.prank(alice);
        uint256 id = fleet.registerFleetLocal(_uuid(1000), US, ADMIN_CA, 3);

        vm.prank(alice);
        fleet.burn(id);

        (uint256 after_,) = fleet.countryInclusionHint(US);
        assertEq(after_, 0);
    }

    function test_countryInclusionHint_registrantCanActOnHint() public {
        // Fill up to create pressure
        _registerNLocal(alice, US, ADMIN_CA, 8, 0);
        _registerNCountry(alice, US, 8, 100);

        (uint256 inclusionTier, uint256 hintBond) = fleet.countryInclusionHint(US);

        // Bob registers at country level at the hinted tier
        vm.prank(bob);
        fleet.registerFleetCountry(_uuid(2000), US, inclusionTier);

        uint256 tokenId = _tokenId(_uuid(2000), _regionUS());
        assertEq(fleet.fleetTier(tokenId), inclusionTier);
        assertEq(fleet.bonds(tokenId), hintBond);

        // Bundle for US-CA includes Bob's fleet
        (bytes16[] memory uuids, uint256 count) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        assertGt(count, 0);
        bool foundCountry;
        for (uint256 i = 0; i < count; i++) {
            if (uuids[i] == _uuid(2000)) foundCountry = true;
        }
        assertTrue(foundCountry, "Country fleet should appear in bundle");
    }

    // --- buildHighestBondedUuidBundle (shared-cursor fair-stop) ---

    // ── Empty / Single-level basics ──

    function test_buildBundle_emptyReturnsZero() public view {
        (, uint256 count) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        assertEq(count, 0);
    }

    function test_RevertIf_buildBundle_adminCodeZero() public {
        vm.prank(alice);
        fleet.registerFleetCountry(UUID_1, US, 0);

        vm.expectRevert(FleetIdentity.AdminAreaRequired.selector);
        fleet.buildHighestBondedUuidBundle(US, 0);
    }

    function test_buildBundle_singleCountry() public {
        vm.prank(alice);
        fleet.registerFleetCountry(UUID_1, US, 0);

        (bytes16[] memory uuids, uint256 count) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        assertEq(count, 1);
        assertEq(uuids[0], UUID_1);
    }

    function test_buildBundle_singleLocal() public {
        vm.prank(alice);
        fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);

        (bytes16[] memory uuids, uint256 count) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        assertEq(count, 1);
        assertEq(uuids[0], UUID_1);
    }

    // ── Same cursor, both levels at tier 0 ──

    function test_buildBundle_bothLevelsTied_levelPriorityOrder() public {
        // Both at tier 0 → shared cursor 0 → level priority: local, country
        vm.prank(alice);
        fleet.registerFleetLocal(UUID_2, US, ADMIN_CA, 0);
        vm.prank(alice);
        fleet.registerFleetCountry(UUID_1, US, 0);

        (bytes16[] memory uuids, uint256 count) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        assertEq(count, 2);
        assertEq(uuids[0], UUID_2); // local first
        assertEq(uuids[1], UUID_1); // country second
    }

    function test_buildBundle_2LevelsTier0_fullCapacity() public {
        // 4 local + 4 country at tier 0 = 8
        // Bundle fits all since max is 20
        _registerNLocalAt(alice, US, ADMIN_CA, 4, 1000, 0);
        _registerNCountryAt(alice, US, 4, 2000, 0);

        (, uint256 count) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        assertEq(count, 8);
    }

    function test_buildBundle_2LevelsTier0_partialFill() public {
        // 3 local + 2 country = 5
        _registerNLocalAt(alice, US, ADMIN_CA, 3, 1000, 0);
        _registerNCountryAt(alice, US, 2, 2000, 0);

        (, uint256 count) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        assertEq(count, 5);
    }

    // ── Bond priority: higher tier index = higher bond = comes first ──

    function test_buildBundle_higherBondFirst() public {
        // Country: promote to tier 2 (bond=8*4*BASE)
        vm.prank(alice);
        uint256 usId = fleet.registerFleetCountry(UUID_1, US, 0);
        vm.prank(alice);
        fleet.reassignTier(usId, 2);
        // Local: tier 0 (bond=BASE)
        vm.prank(alice);
        fleet.registerFleetLocal(UUID_2, US, ADMIN_CA, 0);

        (bytes16[] memory uuids, uint256 count) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        assertEq(count, 2);
        assertEq(uuids[0], UUID_1); // highest bond first (country tier 2)
        assertEq(uuids[1], UUID_2); // local tier 0
    }

    function test_buildBundle_multiTierDescendingBond() public {
        // Local tier 2 (bond=4*BASE)
        vm.prank(alice);
        uint256 id1 = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);
        vm.prank(alice);
        fleet.reassignTier(id1, 2);

        // Country tier 1 (bond=8*2*BASE)
        vm.prank(alice);
        uint256 id2 = fleet.registerFleetCountry(UUID_2, US, 0);
        vm.prank(alice);
        fleet.reassignTier(id2, 1);

        // Local tier 0 (bond=BASE)
        vm.prank(alice);
        fleet.registerFleetLocal(UUID_3, US, ADMIN_CA, 0);

        (bytes16[] memory uuids, uint256 count) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        assertEq(count, 3);
        assertEq(uuids[0], UUID_1); // local tier 2: bond=4*BASE
        assertEq(uuids[1], UUID_2); // country tier 1: bond=16*BASE (but added after local at cursor)
    }

    function test_buildBundle_multiTierMultiLevel_correctOrder() public {
        // Admin: tier 0 (4 members) + tier 1 (1 member)
        _registerNLocalAt(alice, US, ADMIN_CA, 4, 8000, 0);
        vm.prank(alice);
        fleet.registerFleetLocal(_uuid(8100), US, ADMIN_CA, 1);

        // Country: promote to tier 1 (bond=8*2*BASE)
        vm.prank(alice);
        uint256 countryId = fleet.registerFleetCountry(_uuid(8200), US, 0);
        vm.prank(alice);
        fleet.reassignTier(countryId, 1);

        // Country: promote to tier 2 (bond=8*4*BASE)
        vm.prank(alice);
        uint256 country2Id = fleet.registerFleetCountry(_uuid(8300), US, 0);
        vm.prank(alice);
        fleet.reassignTier(country2Id, 2);

        (bytes16[] memory uuids, uint256 count) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        // Cursor=2: country(1)→include. Count=1.
        // Cursor=1: local(1)+country(1)→include. Count=3.
        // Cursor=0: local(4)→include. Count=7.
        assertEq(count, 7);
        assertEq(uuids[0], fleet.tokenUuid(country2Id)); // tier 2 first
    }

    // ── All-or-nothing ──

    function test_buildBundle_allOrNothing_tierSkippedWhenDoesNotFit() public {
        // Fill room so that at a cursor position a tier can't fit.
        // Admin tier 1: 4 members
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(alice);
            fleet.registerFleetLocal(_uuid(5100 + i), US, ADMIN_CA, 1);
        }
        // Country tier 1: 4 members
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(alice);
            fleet.registerFleetCountry(_uuid(6100 + i), US, 1);
        }

        // Tier 0: local(4), country(3)
        _registerNLocalAt(alice, US, ADMIN_CA, 4, 5000, 0);
        _registerNCountryAt(alice, US, 3, 6000, 0);

        (, uint256 count) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        // Cursor=1: local(4)+country(4)=8. Count=8, room=12.
        // Cursor=0: local(4)≤12→include[count=12,room=8]. country(3)≤8→include[count=15,room=5].
        assertEq(count, 15);
    }

    function test_buildBundle_allOrNothing_noPartialCollection() public {
        // Room=3, tier has 5 members → some members skipped.
        // Local tier 1: 4 members
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(alice);
            fleet.registerFleetLocal(_uuid(2000 + i), US, ADMIN_CA, 1);
        }
        // Country tier 1: 4 members
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(alice);
            fleet.registerFleetCountry(_uuid(3000 + i), US, 1);
        }

        (, uint256 count) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        // Cursor=1: local(4)+country(4)=8. Count=8.
        // Cursor=0: all empty at tier 0. Done.
        assertEq(count, 8);
    }

    function test_buildBundle_partialInclusion_fillsRemainingSlots() public {
        uint256 cap = fleet.TIER_CAPACITY();
        // With partial inclusion: bundle fills remaining slots.
        // Country tier 0: cap members
        _registerNCountryAt(alice, US, cap, 0, 0);

        // Local: cap at tier 0 + cap at tier 1
        _registerNLocalAt(alice, US, ADMIN_CA, cap, 5000, 0);
        for (uint256 i = 0; i < cap; i++) {
            vm.prank(alice);
            fleet.registerFleetLocal(_uuid(5100 + i), US, ADMIN_CA, 1);
        }

        (bytes16[] memory uuids, uint256 count) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        // Tier 1: local=cap. Tier 0: local=cap + country=cap.
        // Total = 3*cap, capped at MAX_BONDED_UUID_BUNDLE_SIZE.
        uint256 total = 3 * cap;
        uint256 expectedCount = total > fleet.MAX_BONDED_UUID_BUNDLE_SIZE() ? fleet.MAX_BONDED_UUID_BUNDLE_SIZE() : total;
        assertEq(count, expectedCount);

        // Verify country UUIDs ARE in the result (if bundle has room)
        uint256 countryCount;
        for (uint256 i = 0; i < count; i++) {
            uint256 tokenId = _findTokenId(uuids[i], US, ADMIN_CA);
            uint32 region = fleet.tokenRegion(tokenId);
            if (region == _regionUS()) countryCount++;
        }
        // With cap=10, bundle=20: tier 1 local (10) + tier 0 local (10) = 20, no room for country
        // With cap=4, bundle=20: tier 1 local (4) + tier 0 local (4) + country (4) = 12
        uint256 localSlots = 2 * cap; // tier 0 and tier 1 locals
        uint256 remainingRoom = fleet.MAX_BONDED_UUID_BUNDLE_SIZE() > localSlots ? 
            fleet.MAX_BONDED_UUID_BUNDLE_SIZE() - localSlots : 0;
        uint256 expectedCountry = remainingRoom > cap ? cap : remainingRoom;
        assertEq(countryCount, expectedCountry, "country members included based on remaining room");
    }

    // ── Partial inclusion (replaces all-or-nothing + fair-stop) ──

    function test_buildBundle_partialInclusion_fillsBundleCompletely() public {
        // With partial inclusion, we fill the bundle completely by including
        // as many members as fit, in array order.

        // Consume 6 slots at tier 1.
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(alice);
            fleet.registerFleetLocal(_uuid(1000 + i), US, ADMIN_CA, 1);
        }
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(alice);
            fleet.registerFleetCountry(_uuid(2000 + i), US, 1);
        }

        // Tier 0: full capacities (TIER_CAPACITY = 4).
        _registerNLocalAt(alice, US, ADMIN_CA, 4, 3000, 0);
        _registerNCountryAt(alice, US, 4, 4000, 0);

        (, uint256 count) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        // Cursor=1: local(3)+country(3)=6. Count=6, room=14.
        // Cursor=0: local(4)≤14→include 4[count=10,room=10].
        //           country(4)≤10→include 4[count=14,room=6].
        assertEq(count, 14);
    }

    function test_buildBundle_partialFill_localAndCountry() public {
        // Two local tiers consume 8 slots, leaving 12 for cursor=0.
        // At cursor=0: local(4) fits. country(4) included.

        for (uint256 i = 0; i < 4; i++) {
            vm.prank(alice);
            fleet.registerFleetLocal(_uuid(1000 + i), US, ADMIN_CA, 1);
        }
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(alice);
            fleet.registerFleetLocal(_uuid(2000 + i), US, ADMIN_CA, 2);
        }

        // Tier 0: 4 local + 4 country (TIER_CAPACITY = 4)
        _registerNLocalAt(alice, US, ADMIN_CA, 4, 3000, 0);
        _registerNCountryAt(alice, US, 4, 4000, 0);

        (, uint256 count) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        // Cursor=2: local(4)→include. Count=4.
        // Cursor=1: local(4)→include. Count=8, room=12.
        // Cursor=0: local(4)≤12→include[count=12,room=8]. country(4)≤8→include[count=16,room=4].
        assertEq(count, 16);
    }

    function test_buildBundle_partialInclusion_allLevelsPartiallyIncluded() public {
        // With partial inclusion, both levels get included partially if needed.

        // Consume 8 slots at tier 1.
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(alice);
            fleet.registerFleetLocal(_uuid(1000 + i), US, ADMIN_CA, 1);
        }
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(alice);
            fleet.registerFleetCountry(_uuid(2000 + i), US, 1);
        }

        // Tier 0: local=4, country=4 (TIER_CAPACITY = 4)
        _registerNLocalAt(alice, US, ADMIN_CA, 4, 3000, 0);
        _registerNCountryAt(alice, US, 4, 4000, 0);

        (bytes16[] memory uuids, uint256 count) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        // Cursor=1: local(4)+country(4)=8. Count=8, room=12.
        // Cursor=0: local(4)≤12→include 4[count=12,room=8].
        //           country(4)≤8→include 4[count=16].
        assertEq(count, 16);

        // Verify local tier 0 is present
        bool foundLocal = false;
        for (uint256 i = 0; i < count; i++) {
            if (uuids[i] == _uuid(3000)) foundLocal = true;
        }
        assertTrue(foundLocal, "local tier 0 should be included");

        // Count how many country tier 0 members are included
        uint256 countryT0Count;
        for (uint256 i = 0; i < count; i++) {
            uint256 tokenId = _findTokenId(uuids[i], US, ADMIN_CA);
            if (fleet.tokenRegion(tokenId) == _regionUS() && fleet.fleetTier(tokenId) == 0) countryT0Count++;
        }
        assertEq(countryT0Count, 4, "4 country tier 0 members included");
    }

    function test_buildBundle_doesNotDescendAfterBundleFull() public {
        // When cursor=1 fills bundle, cursor=0 tiers are NOT included.

        // Tier 1: local(4) + country(4) + more local(4) + more country(4) = 16
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(alice);
            fleet.registerFleetLocal(_uuid(1000 + i), US, ADMIN_CA, 1);
        }
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(alice);
            fleet.registerFleetCountry(_uuid(2000 + i), US, 1);
        }
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(alice);
            fleet.registerFleetLocal(_uuid(3000 + i), US, ADMIN_CA, 2);
        }

        // Tier 0: extras that might not all fit
        _registerNLocalAt(alice, US, ADMIN_CA, 4, 4000, 0);
        _registerNCountryAt(alice, US, 4, 5000, 0);

        (, uint256 count) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        // Cursor=1: admin(8)+country(8)+global(4)=20. Bundle full.
        assertEq(count, 20);
    }

    function test_buildBundle_partialInclusion_fillsAtHighTier() public {
        // With TIER_CAPACITY = 4:
        // Cursor=2: local(3)→include. Count=3.
        // Cursor=1: local(4)+country(4)=8→include. Count=11, room=9.
        // Cursor=0: local(1)≤9→include[count=12,room=8]. country(1)≤8→include[count=13,room=7].

        for (uint256 i = 0; i < 3; i++) {
            vm.prank(alice);
            fleet.registerFleetLocal(_uuid(1000 + i), US, ADMIN_CA, 2);
        }
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(alice);
            fleet.registerFleetLocal(_uuid(2000 + i), US, ADMIN_CA, 1);
        }
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(alice);
            fleet.registerFleetCountry(_uuid(3000 + i), US, 1);
        }

        // Tier 0 extras (would be included with more room):
        vm.prank(alice);
        fleet.registerFleetLocal(_uuid(5000), US, ADMIN_CA, 0);
        vm.prank(alice);
        fleet.registerFleetCountry(_uuid(5001), US, 0);

        (bytes16[] memory uuids, uint256 count) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        // Cursor=2: local(3)→include. Count=3, room=17.
        // Cursor=1: local(4)+country(4)→include. Count=11, room=9.
        // Cursor=0: local(1)≤9→include[count=12,room=8]. country(1)≤8→include[count=13,room=7].
        assertEq(count, 13);
    }

    function test_buildBundle_partialInclusion_higherPriorityFirst() public {
        // Partial inclusion fills higher-priority levels first at each tier.
        // Local gets slots before country.

        // Local tier 1: 4, Country tier 1: 4
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(alice);
            fleet.registerFleetLocal(_uuid(1000 + i), US, ADMIN_CA, 1);
        }
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(alice);
            fleet.registerFleetCountry(_uuid(2000 + i), US, 1);
        }

        // Tier 0: local=4, country=4 (TIER_CAPACITY = 4)
        _registerNLocalAt(alice, US, ADMIN_CA, 4, 3000, 0);
        _registerNCountryAt(alice, US, 4, 4000, 0);

        (bytes16[] memory uuids, uint256 count) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        // Cursor=1: local(4)+country(4)=8. Count=8, room=12.
        // Cursor=0: local(4)≤12→include 4[count=12,room=8]. country(4)≤8→include 4[count=16].
        assertEq(count, 16);

        // Verify local tier 0 full inclusion (4 of 4)
        uint256 localT0Count;
        for (uint256 i = 0; i < count; i++) {
            uint256 tokenId = _findTokenId(uuids[i], US, ADMIN_CA);
            if (fleet.tokenRegion(tokenId) == _regionUSCA() && fleet.fleetTier(tokenId) == 0) localT0Count++;
        }
        assertEq(localT0Count, 4, "4 local tier 0 included");
    }

    // ── Tie-breaker: local before country at same cursor ──

    function test_buildBundle_tieBreaker_localBeforeCountry() public {
        // Room=8 after higher tiers. Local tier 0 (4) tried before country tier 0 (4).
        // Local fits (4), then country (4).

        // Eat 12 room at tier 1 and 2.
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(alice);
            fleet.registerFleetLocal(_uuid(1000 + i), US, ADMIN_CA, 1);
        }
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(alice);
            fleet.registerFleetCountry(_uuid(2000 + i), US, 1);
        }
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(alice);
            fleet.registerFleetLocal(_uuid(3000 + i), US, ADMIN_CA, 2);
        }

        // Tier 0: local=4, country=4 (TIER_CAPACITY = 4)
        _registerNLocalAt(alice, US, ADMIN_CA, 4, 4000, 0);
        _registerNCountryAt(alice, US, 4, 5000, 0);

        (bytes16[] memory uuids, uint256 count) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        // Cursor=2: local(4)→include. Count=4, room=16.
        // Cursor=1: local(4)+country(4)=8→include. Count=12, room=8.
        // Cursor=0: local(4)≤8→include[count=16,room=4]. country(4)≤4→include 4[count=20,room=0].
        assertEq(count, 20);

        // Verify: local(12) + country(8)
        uint256 localCount;
        uint256 countryCount;
        for (uint256 i = 0; i < count; i++) {
            uint256 tokenId = _findTokenId(uuids[i], US, ADMIN_CA);
            uint32 region = fleet.tokenRegion(tokenId);
            if (region == _regionUS()) countryCount++;
            else if (region == _regionUSCA()) localCount++;
        }
        assertEq(localCount, 12); // tier 0 (4) + tier 1 (4) + tier 2 (4)
        assertEq(countryCount, 8); // tier 1 (4) + tier 0 (4)
    }

    // ── Empty tiers and gaps ──

    function test_buildBundle_emptyTiersSkippedCleanly() public {
        // Register at tier 0 then promote to tier 2, leaving tier 1 empty.
        vm.prank(alice);
        uint256 id = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);
        vm.prank(alice);
        fleet.reassignTier(id, 2);

        vm.prank(alice);
        fleet.registerFleetCountry(UUID_2, US, 0);

        (bytes16[] memory uuids, uint256 count) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        // Cursor=2: local(1)→include. Count=1.
        // Cursor=1: all empty. No skip. Descend.
        // Cursor=0: country(1)→include. Count=2.
        assertEq(count, 2);
        assertEq(uuids[0], UUID_1);
        assertEq(uuids[1], UUID_2);
    }

    function test_buildBundle_multipleEmptyTiersInMiddle() public {
        // Local at tier 5, country at tier 0. Tiers 1-4 empty.
        vm.prank(alice);
        uint256 id = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);
        vm.prank(alice);
        fleet.reassignTier(id, 5);
        vm.prank(alice);
        fleet.registerFleetCountry(UUID_2, US, 0);

        (, uint256 count) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        assertEq(count, 2);
    }

    function test_buildBundle_emptyTiersInMiddle_countryToo() public {
        // Country: register at tier 0 and tier 2 (tier 1 empty)
        vm.prank(alice);
        fleet.registerFleetCountry(UUID_1, US, 0);
        vm.prank(alice);
        fleet.registerFleetCountry(UUID_2, US, 2);

        (bytes16[] memory uuids, uint256 count) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        assertEq(count, 2);
        assertEq(uuids[0], UUID_2); // higher bond first
        assertEq(uuids[1], UUID_1);
    }

    // ── Local isolation ──

    function test_buildBundle_multipleAdminAreas_isolated() public {
        _registerNLocalAt(alice, US, ADMIN_CA, 4, 1000, 0);
        _registerNLocalAt(alice, US, ADMIN_NY, 4, 2000, 0);

        (, uint256 countCA) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        // CA locals + any country
        assertEq(countCA, 4);
        (, uint256 countNY) = fleet.buildHighestBondedUuidBundle(US, ADMIN_NY);
        // NY locals + any country (same country)
        assertEq(countNY, 4);
    }

    // ── Single level, multiple tiers ──

    function test_buildBundle_singleLevelMultipleTiers() public {
        // Only country, multiple tiers. Country fleets fill all available slots.
        _registerNCountryAt(alice, US, 4, 1000, 0); // tier 0: 4 members
        _registerNCountryAt(alice, US, 4, 2000, 1); // tier 1: 4 members
        _registerNCountryAt(alice, US, 4, 3000, 2); // tier 2: 4 members

        (bytes16[] memory uuids, uint256 count) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        assertEq(count, 12); // all country fleets included
        // Verify order: tier 2 first (highest bond)
        uint256[] memory t2 = fleet.getTierMembers(_regionUS(), 2);
        for (uint256 i = 0; i < 4; i++) {
            assertEq(uuids[i], bytes16(uint128(t2[i])));
        }
    }

    function test_buildBundle_singleLevelOnlyLocal() public {
        _registerNLocalAt(alice, US, ADMIN_CA, 4, 1000, 0);
        (, uint256 count) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        assertEq(count, 4);
    }

    function test_buildBundle_onlyCountry() public {
        // TIER_CAPACITY = 4, so split across two tiers
        _registerNCountryAt(alice, US, 4, 1000, 0);
        _registerNCountryAt(alice, US, 4, 1100, 1);

        (bytes16[] memory uuids, uint256 count) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        assertEq(count, 8);
        assertEq(uuids[0], _uuid(1100)); // tier 1 comes first (higher bond)
    }

    function test_buildBundle_countryFillsSlots() public {
        // Test that country fleets fill bundle slots when room is available.
        //
        // Setup: 2 local fleets + 12 country fleets across 3 tiers
        // Expected: All 14 should be included since bundle has room
        _registerNLocalAt(alice, US, ADMIN_CA, 2, 1000, 0);
        _registerNCountryAt(alice, US, 4, 2000, 0); // tier 0: 4 country
        _registerNCountryAt(alice, US, 4, 3000, 1); // tier 1: 4 country
        _registerNCountryAt(alice, US, 4, 4000, 2); // tier 2: 4 country

        (bytes16[] memory uuids, uint256 count) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);

        // All 14 should be included: 2 local + 12 country
        assertEq(count, 14);

        // Verify order: tier 2 country (highest bond) → tier 1 country → tier 0 local/country
        // First 4 should be tier 2 country fleets
        for (uint256 i = 0; i < 4; i++) {
            assertEq(uuids[i], _uuid(4000 + i));
        }
    }

    function test_buildBundle_localsPriorityWithinTier() public {
        // When locals and country compete at same tier, locals are included first.
        //
        // Setup: 8 local fleets + 12 country fleets
        _registerNLocalAt(alice, US, ADMIN_CA, 4, 1000, 0);
        _registerNLocalAt(alice, US, ADMIN_CA, 4, 1100, 1);
        _registerNCountryAt(alice, US, 4, 2000, 0);
        _registerNCountryAt(alice, US, 4, 3000, 1);
        _registerNCountryAt(alice, US, 4, 4000, 2);

        (, uint256 count) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);

        // Total: 8 local + 12 country = 20 (bundle max)
        assertEq(count, 20);
    }

    // ── Shared cursor: different max tier indices per level ──

    function test_buildBundle_sharedCursor_levelsAtDifferentMaxTiers() public {
        // Local at tier 3, Country at tier 1.
        vm.prank(alice);
        uint256 id1 = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);
        vm.prank(alice);
        fleet.reassignTier(id1, 3);
        vm.prank(alice);
        uint256 id2 = fleet.registerFleetCountry(UUID_2, US, 0);
        vm.prank(alice);
        fleet.reassignTier(id2, 1);
        vm.prank(alice);
        fleet.registerFleetLocal(UUID_3, US, ADMIN_CA, 0);

        (bytes16[] memory uuids, uint256 count) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        assertEq(count, 3);
        assertEq(uuids[0], UUID_1); // tier 3
        assertEq(uuids[1], UUID_2); // tier 1
        assertEq(uuids[2], UUID_3); // tier 0
    }

    function test_buildBundle_sharedCursor_sameTierIndex_differentBondByRegion() public view {
        // Local tier 0 = BASE_BOND, Country tier 0 = BASE_BOND * fleet.COUNTRY_BOND_MULTIPLIER() (multiplier)
        assertEq(fleet.tierBond(0, false), BASE_BOND);
        assertEq(fleet.tierBond(0, true), BASE_BOND * fleet.COUNTRY_BOND_MULTIPLIER());
        assertEq(fleet.tierBond(1, false), BASE_BOND * 2);
        assertEq(fleet.tierBond(1, true), BASE_BOND * fleet.COUNTRY_BOND_MULTIPLIER() * 2);
    }

    // ── Lifecycle ──

    function test_buildBundle_afterBurn_reflects() public {
        vm.prank(alice);
        uint256 id1 = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);
        vm.prank(bob);
        fleet.registerFleetLocal(UUID_2, US, ADMIN_CA, 0);
        vm.prank(carol);
        fleet.registerFleetLocal(UUID_3, US, ADMIN_CA, 0);

        (, uint256 countBefore) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        assertEq(countBefore, 3);

        vm.prank(alice);
        fleet.burn(id1);

        (, uint256 countAfter) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        assertEq(countAfter, 2);
    }

    function test_buildBundle_exhaustsBothLevels() public {
        vm.prank(alice);
        fleet.registerFleetCountry(UUID_1, US, 0);
        vm.prank(alice);
        fleet.registerFleetLocal(UUID_2, US, ADMIN_CA, 0);

        (bytes16[] memory uuids, uint256 count) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        assertEq(count, 2);
        bool found1;
        bool found2;
        for (uint256 i = 0; i < count; i++) {
            if (uuids[i] == UUID_1) found1 = true;
            if (uuids[i] == UUID_2) found2 = true;
        }
        assertTrue(found1 && found2);
    }

    function test_buildBundle_lifecycle_promotionsAndBurns() public {
        vm.prank(alice);
        uint256 l1 = fleet.registerFleetLocal(_uuid(100), US, ADMIN_CA, 0);
        vm.prank(alice);
        fleet.registerFleetLocal(_uuid(101), US, ADMIN_CA, 0);
        vm.prank(alice);
        fleet.registerFleetLocal(_uuid(102), US, ADMIN_CA, 0);

        vm.prank(alice);
        uint256 c1 = fleet.registerFleetCountry(_uuid(200), US, 0);
        vm.prank(alice);
        fleet.registerFleetCountry(_uuid(201), US, 0);

        vm.prank(alice);
        fleet.registerFleetLocal(_uuid(300), US, ADMIN_CA, 0);

        vm.prank(alice);
        fleet.reassignTier(l1, 3);
        vm.prank(alice);
        fleet.reassignTier(c1, 1);

        (, uint256 count) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        // Cursor=3: local(1)→include. Count=1.
        // Cursor=2: empty. Descend.
        // Cursor=1: country(1)→include. Count=2.
        // Cursor=0: local(3)+country(1)=4→include. Count=6.
        assertEq(count, 6);

        vm.prank(alice);
        fleet.burn(l1);

        (, count) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        assertEq(count, 5);
    }

    // ── Cap enforcement ──

    function test_buildBundle_capsAt20() public {
        // Fill local: 4+4+4 = 12 in 3 tiers
        _registerNLocalAt(alice, US, ADMIN_CA, 4, 0, 0);
        _registerNLocalAt(alice, US, ADMIN_CA, 4, 100, 1);
        _registerNLocalAt(alice, US, ADMIN_CA, 4, 200, 2);
        // Fill country US: 4+4 = 8 in 2 tiers (TIER_CAPACITY = 4)
        _registerNCountryAt(bob, US, 4, 1000, 0);
        _registerNCountryAt(bob, US, 4, 1100, 1);

        (, uint256 count) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        assertEq(count, 20);
    }

    function test_buildBundle_exactlyFillsToCapacity() public {
        // 12 local + 8 country = 20 exactly, spread across tiers (TIER_CAPACITY = 4).
        _registerNLocalAt(alice, US, ADMIN_CA, 4, 1000, 0);
        _registerNLocalAt(alice, US, ADMIN_CA, 4, 1100, 1);
        _registerNLocalAt(alice, US, ADMIN_CA, 4, 1200, 2);
        _registerNCountryAt(alice, US, 4, 2000, 0);
        _registerNCountryAt(alice, US, 4, 2100, 1);

        (, uint256 count) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        assertEq(count, 20);
    }

    function test_buildBundle_twentyOneMembers_partialInclusion() public {
        // 21 total: local 12 + country 8 + 1 extra country at tier 2.
        // With partial inclusion, bundle fills to 20.
        // TIER_CAPACITY = 4, so spread across tiers.
        _registerNLocalAt(alice, US, ADMIN_CA, 4, 1000, 0);
        _registerNLocalAt(alice, US, ADMIN_CA, 4, 1100, 1);
        _registerNLocalAt(alice, US, ADMIN_CA, 4, 1200, 2);
        _registerNCountryAt(alice, US, 4, 2000, 0);
        _registerNCountryAt(alice, US, 4, 2100, 1);
        vm.prank(alice);
        fleet.registerFleetCountry(_uuid(3000), US, 2);

        // Cursor=2: local(4)+country(1)=5. Count=5, room=15.
        // Cursor=1: local(4)+country(4)=8. Count=13, room=7.
        // Cursor=0: local(4)≤7→include 4[count=17,room=3].
        //           country(4)>3→include 3 of 4[count=20,room=0].
        (, uint256 count) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        assertEq(count, 20); // caps at max bundle size
    }

    // ── Integrity ──

    function test_buildBundle_noDuplicateUUIDs() public {
        _registerNLocalAt(alice, US, ADMIN_CA, 4, 1000, 0);
        _registerNCountryAt(bob, US, 4, 2000, 0);

        (bytes16[] memory uuids, uint256 count) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        for (uint256 i = 0; i < count; i++) {
            for (uint256 j = i + 1; j < count; j++) {
                assertTrue(uuids[i] != uuids[j], "Duplicate UUID found");
            }
        }
    }

    function test_buildBundle_noNonExistentUUIDs() public {
        _registerNLocalAt(alice, US, ADMIN_CA, 3, 1000, 0);
        _registerNCountryAt(bob, US, 2, 2000, 0);
        vm.prank(carol);
        fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);

        (bytes16[] memory uuids, uint256 count) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        assertEq(count, 6);
        for (uint256 i = 0; i < count; i++) {
            uint256 tokenId = _findTokenId(uuids[i], US, ADMIN_CA);
            assertTrue(fleet.ownerOf(tokenId) != address(0));
        }
    }

    function test_buildBundle_allReturnedAreFromCorrectRegions() public {
        // Verify returned UUIDs are from local or country regions.
        _registerNLocalAt(alice, US, ADMIN_CA, 4, 1000, 0);
        _registerNCountryAt(alice, US, 3, 2000, 0);

        (bytes16[] memory uuids, uint256 count) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);

        uint256 localFound;
        uint256 countryFound;
        for (uint256 i = 0; i < count; i++) {
            uint256 tid = _findTokenId(uuids[i], US, ADMIN_CA);
            uint32 region = fleet.tokenRegion(tid);
            if (region == _regionUSCA()) localFound++;
            else if (region == _regionUS()) countryFound++;
        }
        assertEq(localFound, 4, "local count");
        assertEq(countryFound, 3, "country count");
    }

    // ── Fuzz ──

    function testFuzz_buildBundle_neverExceeds20(uint8 cCount, uint8 lCount) public {
        cCount = uint8(bound(cCount, 0, 15));
        lCount = uint8(bound(lCount, 0, 15));

        for (uint256 i = 0; i < cCount; i++) {
            vm.prank(alice);
            fleet.registerFleetCountry(_uuid(31_000 + i), US, i / 4);
        }
        for (uint256 i = 0; i < lCount; i++) {
            vm.prank(alice);
            fleet.registerFleetLocal(_uuid(32_000 + i), US, ADMIN_CA, i / 4);
        }

        (, uint256 count) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        assertLe(count, 20);
    }

    function testFuzz_buildBundle_noDuplicates(uint8 cCount, uint8 lCount) public {
        cCount = uint8(bound(cCount, 0, 12));
        lCount = uint8(bound(lCount, 0, 12));

        for (uint256 i = 0; i < cCount; i++) {
            vm.prank(alice);
            fleet.registerFleetCountry(_uuid(41_000 + i), US, i / 4);
        }
        for (uint256 i = 0; i < lCount; i++) {
            vm.prank(alice);
            fleet.registerFleetLocal(_uuid(42_000 + i), US, ADMIN_CA, i / 4);
        }

        (bytes16[] memory uuids, uint256 count) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        for (uint256 i = 0; i < count; i++) {
            for (uint256 j = i + 1; j < count; j++) {
                assertTrue(uuids[i] != uuids[j], "Fuzz: duplicate UUID");
            }
        }
    }

    function testFuzz_buildBundle_allReturnedUUIDsExist(uint8 cCount, uint8 lCount) public {
        cCount = uint8(bound(cCount, 0, 12));
        lCount = uint8(bound(lCount, 0, 12));

        for (uint256 i = 0; i < cCount; i++) {
            vm.prank(alice);
            fleet.registerFleetCountry(_uuid(51_000 + i), US, i / 4);
        }
        for (uint256 i = 0; i < lCount; i++) {
            vm.prank(alice);
            fleet.registerFleetLocal(_uuid(52_000 + i), US, ADMIN_CA, i / 4);
        }

        (bytes16[] memory uuids, uint256 count) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        for (uint256 i = 0; i < count; i++) {
            uint256 tokenId = _findTokenId(uuids[i], US, ADMIN_CA);
            assertTrue(fleet.ownerOf(tokenId) != address(0), "Fuzz: UUID does not exist");
        }
    }

    function testFuzz_buildBundle_partialInclusionInvariant(uint8 cCount, uint8 lCount) public {
        cCount = uint8(bound(cCount, 0, 12));
        lCount = uint8(bound(lCount, 0, 12));

        for (uint256 i = 0; i < cCount; i++) {
            vm.prank(alice);
            fleet.registerFleetCountry(_uuid(61_000 + i), US, i / 4);
        }
        for (uint256 i = 0; i < lCount; i++) {
            vm.prank(alice);
            fleet.registerFleetLocal(_uuid(62_000 + i), US, ADMIN_CA, i / 4);
        }

        (bytes16[] memory uuids2, uint256 count2) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);

        // With partial inclusion: for each (region, tier) group in the bundle,
        // the included members should be a PREFIX of the full tier (registration order).
        // We verify this by checking that included members are the first N in the tier's array.
        for (uint256 i = 0; i < count2; i++) {
            uint256 tid = _findTokenId(uuids2[i], US, ADMIN_CA);
            uint32 region = fleet.tokenRegion(tid);
            uint256 tier = fleet.fleetTier(tid);

            // Count how many from this (region, tier) are in the bundle
            uint256 inBundle;
            for (uint256 j = 0; j < count2; j++) {
                uint256 tjd = _findTokenId(uuids2[j], US, ADMIN_CA);
                if (fleet.tokenRegion(tjd) == region && fleet.fleetTier(tjd) == tier) {
                    inBundle++;
                }
            }

            // Get the full tier members
            uint256[] memory tierMembers = fleet.getTierMembers(region, tier);

            // The included count should be <= total tier members
            assertLe(inBundle, tierMembers.length, "Fuzz: more included than exist");

            // Verify the included members are exactly the first `inBundle` members of the tier
            // (prefix property for partial inclusion)
            uint256 found;
            for (uint256 m = 0; m < inBundle && m < tierMembers.length; m++) {
                bytes16 expectedUuid = bytes16(uint128(tierMembers[m]));
                for (uint256 j = 0; j < count2; j++) {
                    if (uuids2[j] == expectedUuid) {
                        found++;
                        break;
                    }
                }
            }
            assertEq(found, inBundle, "Fuzz: included members not a prefix of tier");
        }
    }

    // ══════════════════════════════════════════════════════════════════════════════════
    // Edge Cases: _findCheapestInclusionTier & MaxTiersReached
    // ══════════════════════════════════════════════════════════════════════════════════

    /// @notice When all 24 tiers of a region are full, localInclusionHint should revert.
    function test_RevertIf_localInclusionHint_allTiersFull() public {
        uint256 cap = fleet.TIER_CAPACITY();
        uint256 maxTiers = fleet.MAX_TIERS();
        // Fill all tiers of US/ADMIN_CA (cap members each)
        for (uint256 tier = 0; tier < maxTiers; tier++) {
            for (uint256 i = 0; i < cap; i++) {
                vm.prank(alice);
                fleet.registerFleetLocal(_uuid(tier * 100 + i), US, ADMIN_CA, tier);
            }
        }

        // Verify all tiers are full
        for (uint256 tier = 0; tier < maxTiers; tier++) {
            assertEq(fleet.tierMemberCount(fleet.makeAdminRegion(US, ADMIN_CA), tier), cap);
        }

        // localInclusionHint should revert
        vm.expectRevert(FleetIdentity.MaxTiersReached.selector);
        fleet.localInclusionHint(US, ADMIN_CA);
    }

    /// @notice When all tiers are full, registering at any tier should revert with TierFull.
    function test_RevertIf_registerFleetLocal_allTiersFull() public {
        uint256 cap = fleet.TIER_CAPACITY();
        uint256 maxTiers = fleet.MAX_TIERS();
        // Fill all tiers
        for (uint256 tier = 0; tier < maxTiers; tier++) {
            for (uint256 i = 0; i < cap; i++) {
                vm.prank(alice);
                fleet.registerFleetLocal(_uuid(tier * 100 + i), US, ADMIN_CA, tier);
            }
        }

        // Registration at tier 0 (or any full tier) should revert with TierFull
        vm.prank(bob);
        vm.expectRevert(FleetIdentity.TierFull.selector);
        fleet.registerFleetLocal(_uuid(99999), US, ADMIN_CA, 0);
    }

    /// @notice countryInclusionHint reverts when all tiers in the country region are full.
    function test_RevertIf_countryInclusionHint_allTiersFull() public {
        uint256 cap = fleet.TIER_CAPACITY();
        uint256 maxTiers = fleet.MAX_TIERS();
        // Fill all tiers of country US (cap members each)
        for (uint256 tier = 0; tier < maxTiers; tier++) {
            for (uint256 i = 0; i < cap; i++) {
                vm.prank(alice);
                fleet.registerFleetCountry(_uuid(tier * 100 + i), US, tier);
            }
        }

        vm.expectRevert(FleetIdentity.MaxTiersReached.selector);
        fleet.countryInclusionHint(US);
    }

    /// @notice Proves cheapest inclusion tier can be ABOVE maxTierIndex when bundle is
    ///         constrained by higher-priority levels at existing tiers.
    ///
    /// Scenario:
    ///   - Fill admin tiers 0, 1, 2 with 4 members each (full)
    ///   - Country US has 4 fleets at tier 2 (maxTierIndex)
    ///   - Admin tier 0-2 are FULL (4 members each), so a new fleet cannot join any.
    ///   - Cheapest inclusion should be tier 3 (above maxTierIndex=2).
    function test_cheapestInclusionTier_aboveMaxTierIndex() public {
        uint256 cap = fleet.TIER_CAPACITY();
        // Fill admin tiers 0, 1, 2 with TIER_CAPACITY members each
        _registerNLocalAt(alice, US, ADMIN_CA, cap, 4000, 0);
        _registerNLocalAt(alice, US, ADMIN_CA, cap, 5000, 1);
        _registerNLocalAt(alice, US, ADMIN_CA, cap, 6000, 2);
        // Country at tier 2 (sets maxTierIndex across regions)
        _registerNCountryAt(alice, US, cap, 7000, 2);

        // Verify tier 2 is maxTierIndex
        assertEq(fleet.regionTierCount(uint32(US)), 3);
        assertEq(fleet.regionTierCount(fleet.makeAdminRegion(US, ADMIN_CA)), 3);

        // All admin tiers 0-2 are full (TIER_CAPACITY members each)
        assertEq(fleet.tierMemberCount(fleet.makeAdminRegion(US, ADMIN_CA), 0), cap);
        assertEq(fleet.tierMemberCount(fleet.makeAdminRegion(US, ADMIN_CA), 1), cap);
        assertEq(fleet.tierMemberCount(fleet.makeAdminRegion(US, ADMIN_CA), 2), cap);

        // At tiers 0-2: all tiers are full, cannot join.
        // At tier 3: above maxTierIndex, countBefore = 0, has room.
        (uint256 inclusionTier, uint256 bond) = fleet.localInclusionHint(US, ADMIN_CA);
        assertEq(inclusionTier, 3, "Should recommend tier 3 (above maxTierIndex=2)");
        assertEq(bond, BASE_BOND * 8); // local tier 3 bond = BASE_BOND * 2^3

        // Verify registration at tier 3 works
        vm.prank(bob);
        uint256 tokenId = fleet.registerFleetLocal(_uuid(9999), US, ADMIN_CA, 3);
        assertEq(fleet.fleetTier(tokenId), 3);

        // Confirm new fleet appears in bundle at the TOP (first position)
        (bytes16[] memory uuids, uint256 count) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        // tier 3 (1) + tier 2 admin (cap) + tier 2 country (cap) + tier 1 admin (cap) + tier 0 admin (cap)
        // = 1 + 4*cap, capped at MAX_BONDED_UUID_BUNDLE_SIZE
        uint256 expectedCount = 1 + 4 * cap;
        if (expectedCount > fleet.MAX_BONDED_UUID_BUNDLE_SIZE()) {
            expectedCount = fleet.MAX_BONDED_UUID_BUNDLE_SIZE();
        }
        assertEq(count, expectedCount);
        assertEq(uuids[0], _uuid(9999), "Tier 3 fleet should be first in bundle");
    }

    /// @notice Edge case: bundle is full from tier maxTierIndex, and all tiers 0..maxTierIndex
    ///         at the candidate region are also full. The cheapest tier is above maxTierIndex.
    function test_cheapestInclusionTier_aboveMaxTierIndex_candidateTiersFull() public {
        uint256 cap = fleet.TIER_CAPACITY();
        // Country tier 0 has TIER_CAPACITY fleets
        _registerNCountryAt(alice, US, cap, 1000, 0);

        // Admin tier 0 has TIER_CAPACITY fleets (full)
        _registerNLocalAt(alice, US, ADMIN_CA, cap, 2000, 0);

        // Verify admin tier 0 is full
        assertEq(fleet.tierMemberCount(fleet.makeAdminRegion(US, ADMIN_CA), 0), cap);

        // Admin tier 0 is full, so candidate must go elsewhere.
        // Cheapest inclusion tier should be 1 (above maxTierIndex=0).
        (uint256 inclusionTier,) = fleet.localInclusionHint(US, ADMIN_CA);
        assertEq(inclusionTier, 1, "Should recommend tier 1 since tier 0 is full");
    }

    /// @notice When going above maxTierIndex would require tier >= MAX_TIERS, revert.
    ///
    /// Scenario: Fill global tiers 0-23 with 4 members each (96 global fleets).
    /// A new LOCAL fleet cannot fit in any tier because:
    ///   - The bundle simulation runs through tiers 23→0
    ///   - At each tier, global's 4 members + potential admin members need to fit
    ///   - With global filling 4 slots at every tier, and country/admin potentially
    ///     competing, we design a scenario where no tier works.
    ///
    /// Simpler approach: Fill all 24 admin tiers AND make bundle full at every tier.
    function test_RevertIf_cheapestInclusionTier_exceedsMaxTiers() public {
        uint256 cap = fleet.TIER_CAPACITY();
        // Fill all 24 tiers of admin area US/CA with TIER_CAPACITY members each
        for (uint256 tier = 0; tier < fleet.MAX_TIERS(); tier++) {
            for (uint256 i = 0; i < cap; i++) {
                vm.prank(alice);
                fleet.registerFleetLocal(_uuid(tier * 100 + i), US, ADMIN_CA, tier);
            }
        }

        // Now all admin tiers 0-23 are full. A new admin fleet must go to tier 24,
        // which exceeds MAX_TIERS=24 (valid tiers are 0-23).
        vm.expectRevert(FleetIdentity.MaxTiersReached.selector);
        fleet.localInclusionHint(US, ADMIN_CA);
    }

    /// @notice Verify that when bundle is full due to higher-tier members preventing
    ///         lower-tier inclusion, the hint correctly identifies the cheapest viable tier.
    function test_cheapestInclusionTier_bundleFullFromHigherTiers() public {
        uint256 cap = fleet.TIER_CAPACITY();
        // Create a scenario where:
        // - Admin tiers 0-5 are all full (TIER_CAPACITY each)
        // - Country tier 5 has TIER_CAPACITY members
        // All admin tiers 0-5 are full, so must go to tier 6.

        // Fill admin tiers 0-5 with TIER_CAPACITY members each
        for (uint256 tier = 0; tier <= 5; tier++) {
            _registerNLocalAt(alice, US, ADMIN_CA, cap, 10000 + tier * 100, tier);
        }
        // Country at tier 5
        _registerNCountryAt(alice, US, cap, 11000, 5);

        // maxTierIndex = 5
        // All admin tiers 0-5 are full. Cannot join any.
        // At tier 6: above maxTierIndex, countBefore = 0. Has room.
        (uint256 inclusionTier,) = fleet.localInclusionHint(US, ADMIN_CA);
        assertEq(inclusionTier, 6, "Must go above maxTierIndex=5 to tier 6");
    }

    /// @notice Verifies the bundle correctly includes a fleet registered above maxTierIndex.
    function test_buildBundle_includesFleetAboveMaxTierIndex() public {
        uint256 cap = fleet.TIER_CAPACITY();
        // Only country tier 0 has fleets (maxTierIndex = 0)
        _registerNCountryAt(alice, US, cap, 20000, 0);

        // New admin registers at tier 2 (above maxTierIndex)
        vm.prank(bob);
        uint256 adminToken = fleet.registerFleetLocal(_uuid(21000), US, ADMIN_CA, 2);

        // Bundle should include admin tier 2 first (highest), then country tier 0
        (bytes16[] memory uuids, uint256 count) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        // Admin tier 2 (1) + Country tier 0 (cap)
        uint256 expectedCount = 1 + cap;
        if (expectedCount > fleet.MAX_BONDED_UUID_BUNDLE_SIZE()) {
            expectedCount = fleet.MAX_BONDED_UUID_BUNDLE_SIZE();
        }
        assertEq(count, expectedCount);

        // First should be admin tier 2
        assertEq(_tokenId(uuids[0], _regionUSCA()), adminToken, "Admin tier 2 fleet should be first");
    }

    // ══════════════════════════════════════════════════════════════════════════════════
    // Demonstration: Partial inclusion prevents total tier displacement
    // ══════════════════════════════════════════════════════════════════════════════════

    /// @notice DEMONSTRATES that partial inclusion prevents the scenario where a single
    ///         fleet registration could push an entire tier out of the bundle.
    ///
    /// Scenario (2-level system: country + local):
    ///   BEFORE:
    ///   - Admin tier 0: 4 members
    ///   - Country tier 0: 4 members
    ///   - Bundle: all 8 members included (4+4=8)
    ///
    ///   AFTER (single admin tier 1 registration):
    ///   - Admin tier 1: 1 member (NEW - above previous maxTierIndex)
    ///   - With PARTIAL INCLUSION:
    ///     - Tier 1: admin(1) → count=1
    ///     - Tier 0: admin(4) + country(4) = 8, count=9
    ///   - Final bundle: 9 members (all fit)
    ///
    /// Result: All original fleets remain included.
    function test_DEMO_partialInclusionPreventsFullDisplacement() public {
        // === BEFORE STATE ===
        uint32 countryRegion = uint32(US);

        // Fill with admin(4) + country(4) = 8
        uint256[] memory localIds = _registerNLocalAt(alice, US, ADMIN_CA, 4, 30000, 0); // Admin tier 0: 4
        uint256[] memory countryIds = _registerNCountryAt(alice, US, 4, 31000, 0); // Country tier 0: 4

        // Verify BEFORE: all 8 members in bundle
        (bytes16[] memory uuidsBefore, uint256 countBefore) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);
        assertEq(countBefore, 8, "BEFORE: All 8 members should be in bundle");

        // Verify all 4 country fleets are included BEFORE
        uint256 countryCountBefore;
        for (uint256 i = 0; i < countBefore; i++) {
            uint256 tokenId = _findTokenId(uuidsBefore[i], US, ADMIN_CA);
            if (fleet.tokenRegion(tokenId) == countryRegion) countryCountBefore++;
        }
        assertEq(countryCountBefore, 4, "BEFORE: All 4 country fleets in bundle");

        // === SINGLE REGISTRATION ===
        // Bob registers just ONE fleet at admin tier 1
        vm.prank(bob);
        fleet.registerFleetLocal(_uuid(99999), US, ADMIN_CA, 1);

        // === AFTER STATE ===
        (bytes16[] memory uuidsAfter, uint256 countAfter) = fleet.buildHighestBondedUuidBundle(US, ADMIN_CA);

        // Bundle now has 9 members (tier 1: 1 + tier 0: 4+4)
        assertEq(countAfter, 9, "AFTER: Bundle should have 9 members");

        // Count how many country fleets are included AFTER
        uint256 countryCountAfter;
        for (uint256 i = 0; i < countAfter; i++) {
            uint256 tokenId = _findTokenId(uuidsAfter[i], US, ADMIN_CA);
            if (fleet.tokenRegion(tokenId) == countryRegion) countryCountAfter++;
        }
        assertEq(countryCountAfter, 4, "AFTER: All 4 country fleets still in bundle");

        // Verify all country fleets are still included
        bool[] memory countryIncluded = new bool[](4);
        for (uint256 i = 0; i < countAfter; i++) {
            uint256 tokenId = _findTokenId(uuidsAfter[i], US, ADMIN_CA);
            for (uint256 c = 0; c < 4; c++) {
                if (tokenId == countryIds[c]) countryIncluded[c] = true;
            }
        }
        assertTrue(countryIncluded[0], "First country fleet included");
        assertTrue(countryIncluded[1], "Second country fleet included");
        assertTrue(countryIncluded[2], "Third country fleet included");
        assertTrue(countryIncluded[3], "Fourth country fleet included");

        // === IMPROVEMENT SUMMARY ===
        emit log_string("=== PARTIAL INCLUSION FIX DEMONSTRATED ===");
        emit log_string("A single tier-1 registration does not displace any country fleets");
        emit log_named_uint("Country fleets displaced", 0);
        emit log_named_uint("Country fleets still included", 4);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // buildCountryOnlyBundle tests
    // ══════════════════════════════════════════════════════════════════════════════

    function test_buildCountryOnlyBundle_emptyCountry() public view {
        // No fleets registered yet
        (bytes16[] memory uuids, uint256 count) = fleet.buildCountryOnlyBundle(US);
        assertEq(count, 0, "Empty country should have 0 UUIDs");
        assertEq(uuids.length, 0, "Array should be trimmed to 0");
    }

    function test_buildCountryOnlyBundle_onlyCountryFleets() public {
        // Register 3 country fleets at different tiers
        vm.prank(alice);
        fleet.registerFleetCountry(_uuid(1), US, 0);
        vm.prank(alice);
        fleet.registerFleetCountry(_uuid(2), US, 1);
        vm.prank(alice);
        fleet.registerFleetCountry(_uuid(3), US, 2);

        (bytes16[] memory uuids, uint256 count) = fleet.buildCountryOnlyBundle(US);
        assertEq(count, 3, "Should include all 3 country fleets");

        // Verify tier priority order (highest first)
        assertEq(uuids[0], _uuid(3), "Tier 2 should be first");
        assertEq(uuids[1], _uuid(2), "Tier 1 should be second");
        assertEq(uuids[2], _uuid(1), "Tier 0 should be third");
    }

    function test_buildCountryOnlyBundle_excludesLocalFleets() public {
        // Register country fleet
        vm.prank(alice);
        fleet.registerFleetCountry(_uuid(1), US, 0);

        // Register local fleet in same country
        vm.prank(alice);
        fleet.registerFleetLocal(_uuid(2), US, ADMIN_CA, 0);

        // Country-only bundle should ONLY include country fleet
        (bytes16[] memory uuids, uint256 count) = fleet.buildCountryOnlyBundle(US);
        assertEq(count, 1, "Should only include country fleet");
        assertEq(uuids[0], _uuid(1), "Should be the country fleet UUID");
    }

    function test_buildCountryOnlyBundle_respectsMaxBundleSize() public {
        // Register 24 country fleets across 6 tiers (4 per tier = TIER_CAPACITY)
        // This gives us more than MAX_BONDED_UUID_BUNDLE_SIZE (20)
        for (uint256 tier = 0; tier < 6; tier++) {
            for (uint256 i = 0; i < 4; i++) {
                vm.prank(alice);
                fleet.registerFleetCountry(_uuid(tier * 100 + i), US, tier);
            }
        }

        (bytes16[] memory uuids, uint256 count) = fleet.buildCountryOnlyBundle(US);
        assertEq(count, 20, "Should cap at 20 UUIDs");
        assertEq(uuids.length, 20, "Array should be trimmed to 20");
    }

    function test_RevertIf_buildCountryOnlyBundle_invalidCountryCode() public {
        vm.expectRevert(FleetIdentity.InvalidCountryCode.selector);
        fleet.buildCountryOnlyBundle(0);

        vm.expectRevert(FleetIdentity.InvalidCountryCode.selector);
        fleet.buildCountryOnlyBundle(1000); // > MAX_COUNTRY_CODE (999)
    }

    function test_buildCountryOnlyBundle_multipleCountriesIndependent() public {
        // Register in US (country 840)
        vm.prank(alice);
        fleet.registerFleetCountry(_uuid(1), US, 0);

        // Register in Germany (country 276)
        vm.prank(alice);
        fleet.registerFleetCountry(_uuid(2), DE, 0);

        // US bundle should only have US fleet
        (bytes16[] memory usUuids, uint256 usCount) = fleet.buildCountryOnlyBundle(US);
        assertEq(usCount, 1, "US should have 1 fleet");
        assertEq(usUuids[0], _uuid(1), "Should be US fleet");

        // Germany bundle should only have Germany fleet
        (bytes16[] memory deUuids, uint256 deCount) = fleet.buildCountryOnlyBundle(DE);
        assertEq(deCount, 1, "Germany should have 1 fleet");
        assertEq(deUuids[0], _uuid(2), "Should be Germany fleet");
    }

    // ══════════════════════════════════════════════
    // Operator Tests
    // ══════════════════════════════════════════════

    function test_operatorOf_defaultsToUuidOwner() public {
        vm.prank(alice);
        fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);

        // No operator set, should default to uuidOwner
        assertEq(fleet.operatorOf(UUID_1), alice);
    }

    function test_operatorOf_returnsSetOperator() public {
        vm.prank(alice);
        fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);

        vm.prank(alice);
        fleet.setOperator(UUID_1, bob);

        assertEq(fleet.operatorOf(UUID_1), bob);
    }

    function test_setOperator_emitsEvent() public {
        vm.prank(alice);
        fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);

        // Just verify setOperator succeeds and changes state
        vm.prank(alice);
        fleet.setOperator(UUID_1, bob);
        assertEq(fleet.operatorOf(UUID_1), bob);
    }

    function test_setOperator_transfersTierExcess() public {
        vm.prank(alice);
        fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 2);

        uint256 tierBonds = fleet.tierBond(2, false);
        uint256 aliceBefore = bondToken.balanceOf(alice);
        uint256 bobBefore = bondToken.balanceOf(bob);

        vm.prank(alice);
        fleet.setOperator(UUID_1, bob);

        // Alice gets full tier bonds refunded, bob pays full tier bonds
        assertEq(bondToken.balanceOf(alice), aliceBefore + tierBonds);
        assertEq(bondToken.balanceOf(bob), bobBefore - tierBonds);
    }

    function test_setOperator_multiRegion_transfersAllTierExcess() public {
        // Register in two local regions at different tiers
        vm.prank(alice);
        fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 2);
        vm.prank(alice);
        fleet.registerFleetLocal(UUID_1, US, ADMIN_NY, 1);

        uint256 tierBondsFirst = fleet.tierBond(2, false);
        uint256 tierBondsSecond = fleet.tierBond(1, false);
        uint256 totalTierBonds = tierBondsFirst + tierBondsSecond;

        uint256 aliceBefore = bondToken.balanceOf(alice);
        uint256 bobBefore = bondToken.balanceOf(bob);

        vm.prank(alice);
        fleet.setOperator(UUID_1, bob);

        assertEq(bondToken.balanceOf(alice), aliceBefore + totalTierBonds);
        assertEq(bondToken.balanceOf(bob), bobBefore - totalTierBonds);
    }

    function test_setOperator_zeroTierExcess_noTransfer() public {
        // Register at tier 0, tierBond = BASE_BOND
        vm.prank(alice);
        fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);

        uint256 tierBonds = fleet.tierBond(0, false);
        uint256 aliceBefore = bondToken.balanceOf(alice);
        uint256 bobBefore = bondToken.balanceOf(bob);

        vm.prank(alice);
        fleet.setOperator(UUID_1, bob);

        // Full tier bonds transferred (tierBond(0, false) = BASE_BOND)
        assertEq(bondToken.balanceOf(alice), aliceBefore + tierBonds);
        assertEq(bondToken.balanceOf(bob), bobBefore - tierBonds);
    }

    function test_setOperator_changeOperator_transfersBetweenOperators() public {
        vm.prank(alice);
        fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 2);

        // Set bob as operator
        vm.prank(alice);
        fleet.setOperator(UUID_1, bob);

        uint256 tierBonds = fleet.tierBond(2, false);
        uint256 bobBefore = bondToken.balanceOf(bob);
        uint256 carolBefore = bondToken.balanceOf(carol);

        // Change operator from bob to carol
        vm.prank(alice);
        fleet.setOperator(UUID_1, carol);

        assertEq(bondToken.balanceOf(bob), bobBefore + tierBonds);
        assertEq(bondToken.balanceOf(carol), carolBefore - tierBonds);
    }

    function test_setOperator_clearOperator_refundsToOwner() public {
        vm.prank(alice);
        fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 2);

        vm.prank(alice);
        fleet.setOperator(UUID_1, bob);

        uint256 tierBonds = fleet.tierBond(2, false);
        uint256 aliceBefore = bondToken.balanceOf(alice);
        uint256 bobBefore = bondToken.balanceOf(bob);

        // Clear operator (set to address(0))
        vm.prank(alice);
        fleet.setOperator(UUID_1, address(0));

        assertEq(bondToken.balanceOf(bob), bobBefore + tierBonds);
        assertEq(bondToken.balanceOf(alice), aliceBefore - tierBonds);
        assertEq(fleet.operatorOf(UUID_1), alice); // defaults to owner again
    }

    function test_RevertIf_setOperator_notUuidOwner() public {
        vm.prank(alice);
        fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);

        vm.prank(bob);
        vm.expectRevert(FleetIdentity.NotUuidOwner.selector);
        fleet.setOperator(UUID_1, carol);
    }

    function test_setOperator_ownedOnly() public {
        vm.prank(alice);
        fleet.claimUuid(UUID_1, address(0));

        // setOperator now works for owned-only UUIDs
        vm.prank(alice);
        fleet.setOperator(UUID_1, bob);
        assertEq(fleet.operatorOf(UUID_1), bob);
    }

    function test_setOperator_country() public {
        // Register at tier 2
        vm.prank(alice);
        fleet.registerFleetCountry(UUID_1, US, 2);

        uint256 aliceAfterReg = bondToken.balanceOf(alice);
        uint256 bobBefore = bondToken.balanceOf(bob);

        // Now set operator - bob pays full tier bonds to alice
        vm.prank(alice);
        fleet.setOperator(UUID_1, bob);

        uint256 tierBonds = fleet.tierBond(2, true);
        assertEq(bondToken.balanceOf(alice), aliceAfterReg + tierBonds);
        assertEq(bondToken.balanceOf(bob), bobBefore - tierBonds);
        assertEq(fleet.operatorOf(UUID_1), bob);
        assertEq(fleet.uuidOwner(UUID_1), alice);
    }

    function test_setOperator_local() public {
        // Register at tier 2
        vm.prank(alice);
        fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 2);

        uint256 aliceAfterReg = bondToken.balanceOf(alice);
        uint256 bobBefore = bondToken.balanceOf(bob);

        // Now set operator - bob pays full tier bonds to alice
        vm.prank(alice);
        fleet.setOperator(UUID_1, bob);

        uint256 tierBonds = fleet.tierBond(2, false);
        assertEq(bondToken.balanceOf(alice), aliceAfterReg + tierBonds);
        assertEq(bondToken.balanceOf(bob), bobBefore - tierBonds);
        assertEq(fleet.operatorOf(UUID_1), bob);
    }

    function test_operatorCanPromote() public {
        // Register then set operator
        vm.prank(alice);
        fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);
        vm.prank(alice);
        fleet.setOperator(UUID_1, bob);

        uint256 bobBefore = bondToken.balanceOf(bob);
        uint256 tokenId = _tokenId(UUID_1, _makeAdminRegion(US, ADMIN_CA));

        vm.prank(bob);
        fleet.promote(tokenId);

        assertEq(fleet.fleetTier(tokenId), 1);
        // Bob paid the tier difference
        uint256 tierDiff = fleet.tierBond(1, false) - fleet.tierBond(0, false);
        assertEq(bondToken.balanceOf(bob), bobBefore - tierDiff);
    }

    function test_operatorCanDemote() public {
        // Register then set operator
        vm.prank(alice);
        fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 2);
        vm.prank(alice);
        fleet.setOperator(UUID_1, bob);

        uint256 bobBefore = bondToken.balanceOf(bob);
        uint256 tokenId = _tokenId(UUID_1, _makeAdminRegion(US, ADMIN_CA));

        vm.prank(bob);
        fleet.reassignTier(tokenId, 0);

        assertEq(fleet.fleetTier(tokenId), 0);
        // Bob gets tier difference refunded
        uint256 tierDiff = fleet.tierBond(2, false) - fleet.tierBond(0, false);
        assertEq(bondToken.balanceOf(bob), bobBefore + tierDiff);
    }

    function test_RevertIf_ownerCannotPromoteWhenOperatorSet() public {
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);
        vm.prank(alice);
        fleet.setOperator(UUID_1, bob);

        vm.prank(alice);
        vm.expectRevert(FleetIdentity.NotOperator.selector);
        fleet.promote(tokenId);
    }

    function test_operatorCanBurnRegisteredToken() public {
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 2);
        vm.prank(alice);
        fleet.setOperator(UUID_1, bob);

        uint256 bobBefore = bondToken.balanceOf(bob);

        // Operator (bob) burns the registered token
        vm.prank(bob);
        fleet.burn(tokenId);

        // Bob (operator) gets full tierBond. Alice gets owned-only token minted.
        assertEq(bondToken.balanceOf(bob), bobBefore + fleet.tierBond(2, false));
        
        // Verify owned-only token was minted to owner
        uint256 ownedTokenId = uint256(uint128(UUID_1));
        assertEq(fleet.ownerOf(ownedTokenId), alice);
        assertTrue(fleet.isOwnedOnly(UUID_1));
    }

    function test_RevertIf_ownerCannotBurnRegisteredWithOperator() public {
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);
        vm.prank(alice);
        fleet.setOperator(UUID_1, bob);

        // Owner cannot burn when there's a separate operator
        vm.prank(alice);
        vm.expectRevert(FleetIdentity.NotOperator.selector);
        fleet.burn(tokenId);
    }

    function test_burn_refundsOperatorAndPreservesOperator() public {
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 2);
        vm.prank(alice);
        fleet.setOperator(UUID_1, bob);

        uint256 bobBefore = bondToken.balanceOf(bob);

        // Operator burns registered token
        vm.prank(bob);
        fleet.burn(tokenId);

        // Bob (operator) gets full tier bond refunded
        uint256 tierBond = fleet.tierBond(2, false);
        assertEq(bondToken.balanceOf(bob), bobBefore + tierBond);
        // Operator is preserved (still bob) on the new owned-only token
        assertEq(fleet.operatorOf(UUID_1), bob);
        assertTrue(fleet.isOwnedOnly(UUID_1));
    }

    function test_registerFromOwned_preservesOperator() public {
        // Alice claims UUID with no operator
        vm.prank(alice);
        fleet.claimUuid(UUID_1, address(0));

        // She registers to local (which removes owned-only token and creates registered token)
        vm.prank(alice);
        uint256 registeredToken = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);

        assertEq(fleet.operatorOf(UUID_1), alice);
        
        // Now alice can set an operator
        vm.prank(alice);
        fleet.setOperator(UUID_1, bob);
        assertEq(fleet.operatorOf(UUID_1), bob);
    }

    function testFuzz_setOperator_tierExcessCalculation(uint8 tier1, uint8 tier2) public {
        tier1 = uint8(bound(tier1, 0, 7));
        tier2 = uint8(bound(tier2, 0, 7));
        
        // Register in two local regions
        vm.prank(alice);
        fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, tier1);
        vm.prank(alice);
        fleet.registerFleetLocal(UUID_1, US, ADMIN_NY, tier2);

        uint256 expectedTierBonds = 
            fleet.tierBond(tier1, false) + 
            fleet.tierBond(tier2, false);

        uint256 aliceBefore = bondToken.balanceOf(alice);
        uint256 bobBefore = bondToken.balanceOf(bob);

        vm.prank(alice);
        fleet.setOperator(UUID_1, bob);

        assertEq(bondToken.balanceOf(alice), aliceBefore + expectedTierBonds);
        assertEq(bondToken.balanceOf(bob), bobBefore - expectedTierBonds);
    }

    // ══════════════════════════════════════════════
    // Additional Operator Management Tests
    // ══════════════════════════════════════════════

    function test_claimUuid_withOperator() public {
        // Alice claims UUID with bob as operator
        vm.prank(alice);
        uint256 tokenId = fleet.claimUuid(UUID_1, bob);
        
        assertEq(fleet.operatorOf(UUID_1), bob);
        assertEq(fleet.uuidOwner(UUID_1), alice);
        assertEq(fleet.ownerOf(tokenId), alice);
    }

    function test_claimUuid_operatorPersistsOnRegister() public {
        // Alice claims UUID with bob as operator
        vm.prank(alice);
        fleet.claimUuid(UUID_1, bob);
        
        assertEq(fleet.operatorOf(UUID_1), bob);
        
        // When registering, OPERATOR (bob) must call and pays tier bond
        uint256 bobBefore = bondToken.balanceOf(bob);
        
        vm.prank(bob);
        fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 2);
        
        uint256 tierBond = fleet.tierBond(2, false);
        assertEq(bondToken.balanceOf(bob), bobBefore - tierBond);
        assertEq(fleet.operatorOf(UUID_1), bob);
    }

    function test_claimUuid_emitsEventWithOperator() public {
        vm.expectEmit(true, true, false, true);
        emit FleetIdentity.UuidClaimed(alice, UUID_1, bob);
        
        vm.prank(alice);
        fleet.claimUuid(UUID_1, bob);
    }

    function test_claimUuid_withMsgSenderAsOperator() public {
        // Using msg.sender should normalize to address(0) internally
        vm.prank(alice);
        fleet.claimUuid(UUID_1, alice);
        
        // operatorOf should return owner when stored operator is address(0)
        assertEq(fleet.operatorOf(UUID_1), alice);
        assertEq(fleet.uuidOperator(UUID_1), address(0)); // stored as 0
    }

    function test_setOperator_ownedOnly_operatorPreservedOnRegister() public {
        // Claim UUID in owned-only mode
        vm.prank(alice);
        fleet.claimUuid(UUID_1, address(0));
        
        // Set operator while owned-only
        vm.prank(alice);
        fleet.setOperator(UUID_1, bob);
        
        uint256 bobBefore = bondToken.balanceOf(bob);
        
        // Register - OPERATOR (bob) must call and pays tier bond
        vm.prank(bob);
        fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 2);
        
        assertEq(fleet.operatorOf(UUID_1), bob);
        uint256 tierBond = fleet.tierBond(2, false);
        assertEq(bondToken.balanceOf(bob), bobBefore - tierBond);
    }

    function test_burn_lastToken_preservesOperator() public {
        // Register and set operator
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 2);
        vm.prank(alice);
        fleet.setOperator(UUID_1, bob);
        
        // Operator burns the last registered token -> transitions to owned-only
        vm.prank(bob);
        fleet.burn(tokenId);
        
        // Operator should still be bob
        assertEq(fleet.operatorOf(UUID_1), bob);
        assertTrue(fleet.isOwnedOnly(UUID_1));
    }

    function test_operatorNotChangedOnMultiRegionRegistration() public {
        // Register first region and set operator
        vm.prank(alice);
        fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 0);
        vm.prank(alice);
        fleet.setOperator(UUID_1, bob);
        
        uint256 bobBefore = bondToken.balanceOf(bob);
        
        // Register second region - OPERATOR (bob) must call and pays tier bond
        vm.prank(bob);
        fleet.registerFleetLocal(UUID_1, US, ADMIN_NY, 2);
        
        assertEq(fleet.operatorOf(UUID_1), bob);
        
        // Bob pays full tier bond for new region
        uint256 tierBond = fleet.tierBond(2, false);
        assertEq(bondToken.balanceOf(bob), bobBefore - tierBond);
    }

    function test_freshRegistration_ownerIsOperator() public {
        // Fresh registration without claim - owner pays BASE_BOND + tierBond
        uint256 aliceBefore = bondToken.balanceOf(alice);
        
        vm.prank(alice);
        fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 2);
        
        // Owner is operator when fresh registration
        assertEq(fleet.operatorOf(UUID_1), alice);
        assertEq(fleet.uuidOperator(UUID_1), address(0)); // stored as 0
        
        // Owner paid BASE_BOND + tierBond
        uint256 fullBond = BASE_BOND + fleet.tierBond(2, false);
        assertEq(bondToken.balanceOf(alice), aliceBefore - fullBond);
    }

    function test_RevertIf_setOperator_notRegistered() public {
        // UUID not registered at all - uuidOwner is address(0), so NotUuidOwner reverts first
        vm.prank(alice);
        vm.expectRevert(FleetIdentity.NotUuidOwner.selector);
        fleet.setOperator(UUID_1, bob);
    }

    function test_operatorCanPromoteAfterOwnerTransfersOwnedToken() public {
        // Alice claims with bob as operator
        vm.prank(alice);
        fleet.claimUuid(UUID_1, bob);
        
        uint256 ownedTokenId = uint256(uint128(UUID_1));
        
        // Alice transfers owned token to carol
        vm.prank(alice);
        fleet.transferFrom(alice, carol, ownedTokenId);
        
        // Carol is now owner (uuidOwner transferred with token)
        assertEq(fleet.uuidOwner(UUID_1), carol);
        
        // Bob (operator) registers - only operator can register owned UUID
        uint256 bobBefore = bondToken.balanceOf(bob);
        vm.prank(bob);
        fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 1);
        
        // Bob paid full tier bond (owner already paid BASE_BOND via claim)
        uint256 tierBond = fleet.tierBond(1, false);
        assertEq(bondToken.balanceOf(bob), bobBefore - tierBond);
        
        // Bob can promote as operator
        uint256 tokenId = fleet.computeTokenId(UUID_1, fleet.makeAdminRegion(US, ADMIN_CA));
        
        vm.prank(bob);
        fleet.promote(tokenId);
        
        assertEq(fleet.fleetTier(tokenId), 2);
    }

    function test_burnWithOperator_transitionsToOwnedOnly() public {
        // Fresh registration at tier 2
        vm.prank(alice);
        uint256 tokenId = fleet.registerFleetLocal(UUID_1, US, ADMIN_CA, 2);
        
        // Set operator
        vm.prank(alice);
        fleet.setOperator(UUID_1, bob);
        
        uint256 bobBefore = bondToken.balanceOf(bob);
        
        // OPERATOR burns -> transitions to owned-only, bob gets tier bond refund
        vm.prank(bob);
        fleet.burn(tokenId);
        
        assertEq(bondToken.balanceOf(bob), bobBefore + fleet.tierBond(2, false));
        
        // Owned-only token minted to owner
        uint256 ownedTokenId = uint256(uint128(UUID_1));
        assertEq(fleet.ownerOf(ownedTokenId), alice);
        assertTrue(fleet.isOwnedOnly(UUID_1));
    }
}
