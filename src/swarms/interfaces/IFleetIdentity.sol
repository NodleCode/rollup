// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RegistrationLevel} from "./SwarmTypes.sol";

/**
 * @title IFleetIdentity
 * @notice Interface for FleetIdentity — an ERC-721 with ERC721Enumerable representing
 *         ownership of a BLE fleet, secured by an ERC-20 bond organized into geometric tiers.
 *
 * @dev This interface defines the public contract surface that all FleetIdentity
 *      implementations must uphold across upgrades (UUPS pattern).
 *
 *      **Two-level geographic registration**
 *
 *      Fleets register at exactly one level:
 *        - Country    — regionKey = countryCode  (ISO 3166-1 numeric, 1-999)
 *        - Admin Area — regionKey = (countryCode << 10) | adminCode  (>= 1024)
 *
 *      Each regionKey has its **own independent tier namespace** — tier indices
 *      start at 0 for every region.
 *
 *      **Economic Model**
 *
 *      - Tier capacity: 10 members per tier (unified across levels)
 *      - Local bond: BASE_BOND * 2^tier
 *      - Country bond: BASE_BOND * COUNTRY_BOND_MULTIPLIER * 2^tier (16× local)
 *
 *      **TokenID Encoding**
 *
 *      TokenID = (regionKey << 128) | uuid
 *        - Bits 0-127:   UUID (bytes16 Proximity UUID)
 *        - Bits 128-159: Region key (32-bit country or admin-area code)
 */
interface IFleetIdentity {
    // ══════════════════════════════════════════════
    // Events
    // ══════════════════════════════════════════════

    /// @notice Emitted when a fleet is registered in a region.
    /// @param owner The address that owns the UUID.
    /// @param uuid The fleet's proximity UUID.
    /// @param tokenId The minted NFT token ID.
    /// @param regionKey The region key (country or admin-area).
    /// @param tierIndex The tier the fleet was registered at.
    /// @param bondAmount The total bond amount paid.
    /// @param operator The operator address for tier management.
    event FleetRegistered(
        address indexed owner,
        bytes16 indexed uuid,
        uint256 indexed tokenId,
        uint32 regionKey,
        uint256 tierIndex,
        uint256 bondAmount,
        address operator
    );

    /// @notice Emitted when an operator is changed for a UUID.
    /// @param uuid The UUID whose operator changed.
    /// @param oldOperator The previous operator address.
    /// @param newOperator The new operator address.
    /// @param tierExcessTransferred The tier bonds transferred between operators.
    event OperatorSet(
        bytes16 indexed uuid, address indexed oldOperator, address indexed newOperator, uint256 tierExcessTransferred
    );

    /// @notice Emitted when a fleet is promoted to a higher tier.
    /// @param tokenId The token ID of the promoted fleet.
    /// @param fromTier The original tier index.
    /// @param toTier The new (higher) tier index.
    /// @param additionalBond The additional bond paid for promotion.
    event FleetPromoted(
        uint256 indexed tokenId, uint256 indexed fromTier, uint256 indexed toTier, uint256 additionalBond
    );

    /// @notice Emitted when a fleet is demoted to a lower tier.
    /// @param tokenId The token ID of the demoted fleet.
    /// @param fromTier The original tier index.
    /// @param toTier The new (lower) tier index.
    /// @param bondRefund The bond amount refunded.
    event FleetDemoted(uint256 indexed tokenId, uint256 indexed fromTier, uint256 indexed toTier, uint256 bondRefund);

    /// @notice Emitted when a fleet NFT is burned.
    /// @param owner The former owner of the token.
    /// @param tokenId The burned token ID.
    /// @param regionKey The region the fleet was registered in.
    /// @param tierIndex The tier the fleet was in.
    /// @param bondRefund The bond amount refunded.
    event FleetBurned(
        address indexed owner, uint256 indexed tokenId, uint32 indexed regionKey, uint256 tierIndex, uint256 bondRefund
    );

    /// @notice Emitted when a UUID is claimed in owned-only mode.
    /// @param owner The address that claimed the UUID.
    /// @param uuid The claimed UUID.
    /// @param operator The operator address assigned.
    event UuidClaimed(address indexed owner, bytes16 indexed uuid, address indexed operator);

    // ══════════════════════════════════════════════
    // Registration Functions
    // ══════════════════════════════════════════════

    /// @notice Register a fleet under a country at a specific tier.
    /// @param uuid The proximity UUID (must be non-zero).
    /// @param countryCode ISO 3166-1 numeric country code (1-999).
    /// @param targetTier The tier to register at.
    /// @return tokenId The minted NFT token ID.
    function registerFleetCountry(bytes16 uuid, uint16 countryCode, uint256 targetTier)
        external
        returns (uint256 tokenId);

    /// @notice Register a fleet under a country + admin area at a specific tier.
    /// @param uuid The proximity UUID (must be non-zero).
    /// @param countryCode ISO 3166-1 numeric country code (1-999).
    /// @param adminCode Admin-area code within the country (1-255).
    /// @param targetTier The tier to register at.
    /// @return tokenId The minted NFT token ID.
    function registerFleetLocal(bytes16 uuid, uint16 countryCode, uint16 adminCode, uint256 targetTier)
        external
        returns (uint256 tokenId);

    /// @notice Claim ownership of a UUID without registering in any region.
    /// @param uuid The proximity UUID (must be non-zero, unclaimed).
    /// @param operator The operator address for future tier management.
    /// @return tokenId The minted NFT token ID (uses UUID as low 128 bits).
    function claimUuid(bytes16 uuid, address operator) external returns (uint256 tokenId);

    // ══════════════════════════════════════════════
    // Tier Management
    // ══════════════════════════════════════════════

    /// @notice Promotes a fleet to the next tier within its region.
    /// @param tokenId The token ID to promote.
    function promote(uint256 tokenId) external;

    /// @notice Moves a fleet to a different tier within its region.
    /// @param tokenId The token ID to reassign.
    /// @param targetTier The target tier (higher = promote, lower = demote).
    function reassignTier(uint256 tokenId, uint256 targetTier) external;

    /// @notice Burns the fleet NFT and refunds the bond.
    /// @param tokenId The token ID to burn.
    function burn(uint256 tokenId) external;

    // ══════════════════════════════════════════════
    // Operator Management
    // ══════════════════════════════════════════════

    /// @notice Sets or changes the operator for a UUID.
    /// @param uuid The UUID to update.
    /// @param newOperator The new operator address.
    function setOperator(bytes16 uuid, address newOperator) external;

    // ══════════════════════════════════════════════
    // View Functions: Bond & Tier Helpers
    // ══════════════════════════════════════════════

    /// @notice Bond required for tier K at current parameters.
    /// @param tier The tier index.
    /// @param isCountry True for country-level, false for local.
    /// @return The bond amount required.
    function tierBond(uint256 tier, bool isCountry) external view returns (uint256);

    /// @notice Returns the cheapest tier for local inclusion.
    /// @param countryCode ISO 3166-1 numeric country code.
    /// @param adminCode Admin-area code within the country.
    /// @return inclusionTier The tier that would be included in bundles.
    /// @return bond The bond required for that tier.
    function localInclusionHint(uint16 countryCode, uint16 adminCode)
        external
        view
        returns (uint256 inclusionTier, uint256 bond);

    /// @notice Returns the cheapest tier for country inclusion.
    /// @param countryCode ISO 3166-1 numeric country code.
    /// @return inclusionTier The tier that would be included in bundles.
    /// @return bond The bond required for that tier.
    function countryInclusionHint(uint16 countryCode) external view returns (uint256 inclusionTier, uint256 bond);

    /// @notice Highest non-empty tier in a region, or 0 if none.
    /// @param regionKey The region to query.
    /// @return The highest active tier index.
    function highestActiveTier(uint32 regionKey) external view returns (uint256);

    /// @notice Number of members in a specific tier of a region.
    /// @param regionKey The region to query.
    /// @param tier The tier index.
    /// @return The member count.
    function tierMemberCount(uint32 regionKey, uint256 tier) external view returns (uint256);

    /// @notice All token IDs in a specific tier of a region.
    /// @param regionKey The region to query.
    /// @param tier The tier index.
    /// @return Array of token IDs.
    function getTierMembers(uint32 regionKey, uint256 tier) external view returns (uint256[] memory);

    /// @notice All UUIDs in a specific tier of a region.
    /// @param regionKey The region to query.
    /// @param tier The tier index.
    /// @return uuids Array of UUIDs.
    function getTierUuids(uint32 regionKey, uint256 tier) external view returns (bytes16[] memory uuids);

    /// @notice Bond amount for a token.
    /// @param tokenId The token to query.
    /// @return The current bond amount.
    function bonds(uint256 tokenId) external view returns (uint256);

    /// @notice Returns true if the UUID is in owned-only state.
    /// @param uuid The UUID to check.
    /// @return True if owned but not registered in any region.
    function isOwnedOnly(bytes16 uuid) external view returns (bool);

    /// @notice Returns the effective operator for a UUID.
    /// @param uuid The UUID to query.
    /// @return operator The operator address (defaults to owner if not set).
    function operatorOf(bytes16 uuid) external view returns (address operator);

    /// @notice Returns the country bond multiplier.
    /// @return The multiplier (e.g., 16 means country bonds are 16× local).
    function countryBondMultiplier() external view returns (uint256);

    // ══════════════════════════════════════════════
    // View Functions: EdgeBeaconScanner Discovery
    // ══════════════════════════════════════════════

    /// @notice Builds a priority-ordered bundle of up to 20 UUIDs.
    /// @param countryCode ISO 3166-1 numeric country code.
    /// @param adminCode Admin-area code within the country.
    /// @return uuids Array of UUIDs ordered by tier (highest first).
    /// @return count Number of UUIDs in the bundle.
    function buildHighestBondedUuidBundle(uint16 countryCode, uint16 adminCode)
        external
        view
        returns (bytes16[] memory uuids, uint256 count);

    /// @notice Builds a bundle containing ONLY country-level fleets.
    /// @param countryCode ISO 3166-1 numeric country code.
    /// @return uuids Array of country-level UUIDs.
    /// @return count Number of UUIDs in the bundle.
    function buildCountryOnlyBundle(uint16 countryCode) external view returns (bytes16[] memory uuids, uint256 count);

    // ══════════════════════════════════════════════
    // View Functions: Region Indexes
    // ══════════════════════════════════════════════

    /// @notice Returns all country codes that have at least one active fleet.
    /// @return Array of ISO 3166-1 numeric country codes.
    function getActiveCountries() external view returns (uint16[] memory);

    /// @notice Returns all admin-area region keys across all countries.
    /// @return Array of encoded region keys (countryCode << 10 | adminCode).
    function getActiveAdminAreas() external view returns (uint32[] memory);

    /// @notice Returns all active admin-area region keys for a specific country.
    /// @param countryCode ISO 3166-1 numeric country code.
    /// @return Array of encoded region keys for that country.
    function getCountryAdminAreas(uint16 countryCode) external view returns (uint32[] memory);

    // ══════════════════════════════════════════════
    // Pure Functions: Token & Region Helpers
    // ══════════════════════════════════════════════

    /// @notice UUID for a token ID.
    /// @param tokenId The token ID to decode.
    /// @return The UUID (low 128 bits).
    function tokenUuid(uint256 tokenId) external pure returns (bytes16);

    /// @notice Region key encoded in a token ID.
    /// @param tokenId The token ID to decode.
    /// @return The region key (bits 128-159).
    function tokenRegion(uint256 tokenId) external pure returns (uint32);

    /// @notice Computes the deterministic token ID for a uuid+region pair.
    /// @param uuid The proximity UUID.
    /// @param regionKey The region key.
    /// @return The computed token ID.
    function computeTokenId(bytes16 uuid, uint32 regionKey) external pure returns (uint256);

    /// @notice Encodes a country code and admin code into a region key.
    /// @param countryCode ISO 3166-1 numeric country code (1-999).
    /// @param adminCode Admin-area code within the country (1-255).
    /// @return Encoded region key: (countryCode << 10) | adminCode.
    function makeAdminRegion(uint16 countryCode, uint16 adminCode) external pure returns (uint32);

    // ══════════════════════════════════════════════
    // Public Getters
    // ══════════════════════════════════════════════

    /// @notice Returns the bond token address.
    function BOND_TOKEN() external view returns (IERC20);

    /// @notice Returns the base bond amount.
    function BASE_BOND() external view returns (uint256);

    /// @notice UUID -> address that first registered a token for this UUID.
    function uuidOwner(bytes16 uuid) external view returns (address);

    /// @notice UUID -> count of active tokens for this UUID (across all regions).
    function uuidTokenCount(bytes16 uuid) external view returns (uint256);

    /// @notice UUID -> registration level.
    function uuidLevel(bytes16 uuid) external view returns (RegistrationLevel);

    /// @notice UUID -> operator address for tier maintenance.
    function uuidOperator(bytes16 uuid) external view returns (address);

    /// @notice UUID -> total tier bonds across all registered regions.
    function uuidTotalTierBonds(bytes16 uuid) external view returns (uint256);

    /// @notice regionKey -> number of tiers opened in that region.
    function regionTierCount(uint32 regionKey) external view returns (uint256);

    /// @notice Token ID -> tier index (within its region) the fleet belongs to.
    function fleetTier(uint256 tokenId) external view returns (uint256);

    /// @notice tokenId -> tier-0 equivalent bond paid at registration.
    function tokenTier0Bond(uint256 tokenId) external view returns (uint256);

    /// @notice UUID -> ownership bond paid at claim/first-registration.
    function uuidOwnershipBondPaid(bytes16 uuid) external view returns (uint256);

    // ══════════════════════════════════════════════
    // Constants
    // ══════════════════════════════════════════════

    /// @notice Unified tier capacity for all levels.
    function TIER_CAPACITY() external view returns (uint256);

    /// @notice Default country bond multiplier when not explicitly set (16× local).
    function DEFAULT_COUNTRY_BOND_MULTIPLIER() external view returns (uint256);

    /// @notice Default base bond for tier 0.
    function DEFAULT_BASE_BOND() external view returns (uint256);

    /// @notice Hard cap on tier count per region.
    function MAX_TIERS() external view returns (uint256);

    /// @notice Maximum UUIDs returned by buildHighestBondedUuidBundle.
    function MAX_BONDED_UUID_BUNDLE_SIZE() external view returns (uint256);

    /// @notice Region key for owned-only UUIDs (not registered in any region).
    function OWNED_REGION_KEY() external view returns (uint32);
}
