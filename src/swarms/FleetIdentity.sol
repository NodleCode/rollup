// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title FleetIdentity
 * @notice ERC-721 with ERC721Enumerable representing ownership of a BLE fleet,
 *         secured by an ERC-20 bond organized into geometric tiers.
 *
 * @dev **Two-level geographic registration**
 *
 *      Fleets register at exactly one level:
 *        - Country    — regionKey = countryCode  (ISO 3166-1 numeric, 1-999)
 *        - Admin Area — regionKey = (countryCode << 10) | adminCode  (>= 1024)
 *
 *      Each regionKey has its **own independent tier namespace** — tier indices
 *      start at 0 for every region. The first fleet in any region always pays
 *      the level-appropriate bond (LOCAL: BASE_BOND, COUNTRY: BASE_BOND * 16).
 *
 *      **Economic Model**
 *
 *      - Tier capacity: 10 members per tier (unified across levels)
 *      - Local bond: BASE_BOND * 2^tier
 *      - Country bond: BASE_BOND * COUNTRY_BOND_MULTIPLIER * 2^tier (16× local)
 *
 *      Country fleets pay 16× more but appear in all admin-area bundles within
 *      their country. This economic difference provides locals a significant
 *      advantage: a local can reach tier 4 for the same cost a country player
 *      pays for tier 0. Bundle slots are filled by simple tier-descent priority:
 *      higher tier first, locals before country within each tier.
 *
 *      EdgeBeaconScanner discovery uses 2-level fallback:
 *        1. Admin area (highest priority)
 *        2. Country (lower priority)
 *
 *      On-chain indexes track which countries and admin areas have active fleets,
 *      enabling EdgeBeaconScanner enumeration without off-chain indexers.
 *
 *      **TokenID Encoding**
 *
 *      TokenID = (regionKey << 128) | uuid
 *        - Bits 0-127:   UUID (bytes16 Proximity UUID)
 *        - Bits 128-159: Region key (32-bit country or admin-area code)
 *
 *      This allows the same UUID to be registered in multiple regions,
 *      each with a distinct token. Region and UUID can be extracted:
 *        - uuid = bytes16(uint128(tokenId))
 *        - region = uint32(tokenId >> 128)
 */
contract FleetIdentity is ERC721Enumerable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────
    error InvalidUUID();
    error NotTokenOwner();
    error MaxTiersReached();
    error TierFull();
    error TargetTierNotHigher();
    error TargetTierNotLower();
    error TargetTierSameAsCurrent();
    error InvalidCountryCode();
    error InvalidAdminCode();
    error AdminAreaRequired();
    error UuidLevelMismatch();
    error UuidAlreadyOwned();
    error UuidNotOwned();
    error NotUuidOwner();
    error NotOperator();
    error NotOwnerOrOperator();

    // ──────────────────────────────────────────────
    // Enums
    // ──────────────────────────────────────────────

    /// @notice Registration level for a UUID.
    enum RegistrationLevel {
        None,    // 0 - not registered (default)
        Owned,   // 1 - owned but not registered in any region
        Local,   // 2 - admin area (local) level
        Country  // 3 - country level
    }

    // ──────────────────────────────────────────────
    // Constants & Immutables
    // ──────────────────────────────────────────────

    /// @notice Unified tier capacity for all levels.
    uint256 public constant TIER_CAPACITY = 10;

    /// @notice Bond multiplier for country-level registration (16× local).
    uint256 public constant COUNTRY_BOND_MULTIPLIER = 16;

    /// @notice Hard cap on tier count per region.
    /// @dev Derived from anti-spam analysis: with a bond doubling per tier
    ///      and capacity 4, a spammer spending half the total token supply
    ///      against a BASE_BOND set 10 000× too low fills ~20 tiers.
    ///      24 provides comfortable headroom.
    uint256 public constant MAX_TIERS = 24;

    /// @notice Maximum UUIDs returned by buildHighestBondedUuidBundle.
    uint256 public constant MAX_BONDED_UUID_BUNDLE_SIZE = 20;

    /// @notice ISO 3166-1 numeric upper bound for country codes.
    uint16 internal constant MAX_COUNTRY_CODE = 999;

    /// @notice Upper bound for admin-area codes within a country.
    /// @dev Set to 255 to cover all real-world countries (UK has ~172, the highest).
    ///      Dense indices from ISO 3166-2 mappings range 0-254, stored as adminCode 1-255.
    uint16 internal constant MAX_ADMIN_CODE = 255;

    /// @dev Bit shift for packing countryCode into an admin-area region key.
    uint256 private constant ADMIN_SHIFT = 10;
    /// @dev Bitmask for extracting adminCode from an admin-area region key.
    uint32 private constant ADMIN_CODE_MASK = 0x3FF;

    /// @notice Region key for owned-only UUIDs (not registered in any region).
    uint32 public constant OWNED_REGION_KEY = 0;

    /// @notice The ERC-20 token used for bonds (immutable, e.g. NODL).
    IERC20 public immutable BOND_TOKEN;

    /// @notice Base bond for tier 0 in any region. Tier K requires BASE_BOND * 2^K.
    uint256 public immutable BASE_BOND;

    // ──────────────────────────────────────────────
    // Region-namespaced tier data
    // ──────────────────────────────────────────────

    /// @notice regionKey -> number of tiers opened in that region.
    mapping(uint32 => uint256) public regionTierCount;

    /// @notice regionKey -> tierIndex -> list of token IDs.
    mapping(uint32 => mapping(uint256 => uint256[])) internal _regionTierMembers;

    /// @notice Token ID -> index within its tier's member array (for O(1) removal).
    mapping(uint256 => uint256) internal _indexInTier;

    // ──────────────────────────────────────────────
    // Fleet data
    // ──────────────────────────────────────────────

    /// @notice Token ID -> tier index (within its region) the fleet belongs to.
    mapping(uint256 => uint256) public fleetTier;

    // ──────────────────────────────────────────────
    // UUID ownership tracking
    // ──────────────────────────────────────────────

    /// @notice UUID -> address that first registered a token for this UUID.
    ///         All subsequent registrations for the same UUID must come from this address.
    mapping(bytes16 => address) public uuidOwner;

    /// @notice UUID -> count of active tokens for this UUID (across all regions).
    ///         When this reaches 0, uuidOwner is cleared.
    mapping(bytes16 => uint256) public uuidTokenCount;

    /// @notice UUID -> registration level.
    ///         All tokens for a UUID must be at the same level.
    mapping(bytes16 => RegistrationLevel) public uuidLevel;

    /// @notice UUID -> operator address for tier maintenance.
    ///         If address(0), the uuidOwner acts as operator.
    ///         Operator can only be set for registered UUIDs (Local or Country level).
    ///         The operator pays/receives tier bond differentials; owner pays BASE_BOND.
    mapping(bytes16 => address) public uuidOperator;

    /// @notice UUID -> total tier bonds across all registered regions.
    ///         Tracked incrementally to allow O(1) lookup for setOperator.
    ///         Updated on registration, burn, promote, and demote.
    mapping(bytes16 => uint256) public uuidTotalTierBonds;

    // ──────────────────────────────────────────────
    // On-chain region indexes
    // ──────────────────────────────────────────────

    /// @dev Set of country codes with at least one active fleet (country-level or admin-area).
    uint16[] internal _activeCountries;
    mapping(uint16 => uint256) internal _activeCountryIndex; // value = index+1 (0 = not present)

    /// @dev Country → list of admin-area region keys with at least one active fleet.
    ///      Enables bounded iteration in countryInclusionHint (max 255 per country).
    mapping(uint16 => uint32[]) internal _countryAdminAreas;
    mapping(uint32 => uint256) internal _countryAdminAreaIndex; // adminKey → index+1 in country's array

    // ──────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────

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
    event UuidClaimed(address indexed owner, bytes16 indexed uuid, address indexed operator);

    // ──────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────

    /// @param _bondToken Address of the ERC-20 token used for bonds.
    /// @param _baseBond  Base bond for tier 0 in any region.
    constructor(address _bondToken, uint256 _baseBond) ERC721("Swarm Fleet Identity", "SFID") {
        BOND_TOKEN = IERC20(_bondToken);
        BASE_BOND = _baseBond;
    }

    // ══════════════════════════════════════════════
    // Registration: Country  (operator-only with tier)
    // ══════════════════════════════════════════════

    /// @notice Register a fleet under a country at a specific tier.
    /// @dev    Only callable by the operator (or by caller for fresh UUIDs, who becomes owner+operator).
    ///         For owned UUIDs: operator pays tier bond, token mints to owner.
    ///         For fresh UUIDs: caller becomes owner+operator, pays BASE_BOND + tier bond.
    /// @param uuid The Proximity UUID to register.
    /// @param countryCode ISO 3166-1 numeric country code (1-999).
    /// @param targetTier The tier to register at (use countryInclusionHint for guidance).
    function registerFleetCountry(bytes16 uuid, uint16 countryCode, uint256 targetTier)
        external
        nonReentrant
        returns (uint256 tokenId)
    {
        if (uuid == bytes16(0)) revert InvalidUUID();
        if (countryCode == 0 || countryCode > MAX_COUNTRY_CODE) revert InvalidCountryCode();
        uint32 regionKey = uint32(countryCode);
        _validateExplicitTier(regionKey, targetTier);
        tokenId = _register(uuid, regionKey, targetTier);
    }

    // ══════════════════════════════════════════════
    // Registration: Admin Area (local, operator-only with tier)
    // ══════════════════════════════════════════════

    /// @notice Register a fleet under a country + admin area at a specific tier.
    /// @dev    Only callable by the operator (or by caller for fresh UUIDs, who becomes owner+operator).
    ///         For owned UUIDs: operator pays tier bond, token mints to owner.
    ///         For fresh UUIDs: caller becomes owner+operator, pays BASE_BOND + tier bond.
    /// @param uuid The Proximity UUID to register.
    /// @param countryCode ISO 3166-1 numeric country code (1-999).
    /// @param adminCode Admin area code within the country (1-255).
    /// @param targetTier The tier to register at (use localInclusionHint for guidance).
    function registerFleetLocal(bytes16 uuid, uint16 countryCode, uint16 adminCode, uint256 targetTier)
        external
        nonReentrant
        returns (uint256 tokenId)
    {
        if (uuid == bytes16(0)) revert InvalidUUID();
        if (countryCode == 0 || countryCode > MAX_COUNTRY_CODE) revert InvalidCountryCode();
        if (adminCode == 0 || adminCode > MAX_ADMIN_CODE) revert InvalidAdminCode();
        uint32 regionKey = makeAdminRegion(countryCode, adminCode);
        _validateExplicitTier(regionKey, targetTier);
        tokenId = _register(uuid, regionKey, targetTier);
    }

    // ══════════════════════════════════════════════
    // Promote / Demote (region-aware)
    // ══════════════════════════════════════════════

    /// @notice Promotes a fleet to the next tier within its region.
    ///         Only callable by the effective operator (or owner if no operator set).
    function promote(uint256 tokenId) external nonReentrant {
        _promote(tokenId, fleetTier[tokenId] + 1);
    }

    /// @notice Moves a fleet to a different tier within its region.
    ///         If targetTier > current tier, promotes (pulls additional bond from operator).
    ///         If targetTier < current tier, demotes (refunds bond difference to operator).
    ///         Only callable by the effective operator (or owner if no operator set).
    function reassignTier(uint256 tokenId, uint256 targetTier) external nonReentrant {
        uint256 currentTier = fleetTier[tokenId];
        if (targetTier == currentTier) revert TargetTierSameAsCurrent();
        if (targetTier > currentTier) {
            _promote(tokenId, targetTier);
        } else {
            _demote(tokenId, targetTier);
        }
    }

    // ══════════════════════════════════════════════
    // Operator Management
    // ══════════════════════════════════════════════

    /// @notice Sets or changes the operator for a UUID.
    ///         The operator is responsible for tier maintenance (promote/demote) and registration.
    ///         When changing operators, the new operator must pay the old operator
    ///         for all accumulated tier bonds across all registered regions.
    /// @dev    Only the UUID owner can call this. Can be called for any owned UUID (including owned-only).
    ///         Setting operator to owner address or address(0) clears the explicit operator.
    /// @param uuid The UUID to set the operator for.
    /// @param newOperator The new operator address. Use address(0) or owner to clear.
    function setOperator(bytes16 uuid, address newOperator) external nonReentrant {
        // Only owner can set operator
        if (uuidOwner[uuid] != msg.sender) revert NotUuidOwner();
        
        // Cannot set operator for unowned UUIDs
        if (uuidLevel[uuid] == RegistrationLevel.None) {
            revert UuidNotOwned();
        }
        
        address oldOperator = operatorOf(uuid);
        
        // Normalize: if newOperator is owner, store as address(0)
        address storedOperator = (newOperator == msg.sender) ? address(0) : newOperator;
        address effectiveNewOperator = (storedOperator == address(0)) ? msg.sender : storedOperator;
        
        // O(1) lookup of total tier bonds from storage
        uint256 tierBonds = uuidTotalTierBonds[uuid];
        
        // Effects: Update operator
        uuidOperator[uuid] = storedOperator;
        
        // Interactions: Transfer tier bonds from new operator to old operator
        if (tierBonds > 0 && oldOperator != effectiveNewOperator) {
            // Pull from new operator
            _pullBond(effectiveNewOperator, tierBonds);
            // Refund to old operator
            _refundBond(oldOperator, tierBonds);
        }
        
        emit OperatorSet(uuid, oldOperator, effectiveNewOperator, tierBonds);
    }

    // ══════════════════════════════════════════════
    // Burn
    // ══════════════════════════════════════════════

    /// @notice Burns the fleet NFT and refunds the bond.
    ///
    ///         **Owned-only tokens (region=0):**
    ///         - Only the token owner can burn.
    ///         - Refunds BASE_BOND to owner. Clears UUID ownership completely.
    ///
    ///         **Registered tokens (region>0):**
    ///         - Owner OR operator can burn.
    ///         - Refunds tier bond to operator.
    ///         - If this is the LAST registered token for the UUID:
    ///           transitions to owned-only mode (mints owned-only token to owner).
    ///         - If other tokens remain: just decrements count.
    ///
    ///         This function subsumes the former `unregisterToOwned` (operator burns
    ///         last registered token) and `releaseUuid` (owner burns owned-only token).
    function burn(uint256 tokenId) external nonReentrant {
        address tokenHolder = ownerOf(tokenId);

        uint32 region = tokenRegion(tokenId);
        bytes16 uuid = tokenUuid(tokenId);
        address owner = uuidOwner[uuid];
        address operator = operatorOf(uuid);
        bool isLastToken = uuidTokenCount[uuid] == 1;

        if (region == OWNED_REGION_KEY) {
            // Owned-only token: only owner can burn
            if (tokenHolder != msg.sender) revert NotTokenOwner();
            
            _burn(tokenId);
            _clearUuidOwnership(uuid);
            _refundBond(owner, BASE_BOND);

            emit FleetBurned(tokenHolder, tokenId, region, 0, BASE_BOND);
        } else {
            // Registered fleet: only operator can burn
            if (msg.sender != operator) {
                revert NotOperator();
            }

            uint256 tier = fleetTier[tokenId];
            uint256 tierBondAmount = tierBond(tier, _isCountryRegion(region));
            
            // Update tracked tier bonds before cleanup
            uuidTotalTierBonds[uuid] -= tierBondAmount;
            
            _cleanupFleetFromTier(tokenId, region, tier);
            _burn(tokenId);
            
            if (isLastToken) {
                // Transition to owned-only: mint owned-only token to owner
                uuidLevel[uuid] = RegistrationLevel.Owned;
                uint256 ownedTokenId = uint256(uint128(uuid));
                _mint(owner, ownedTokenId);
                // Note: uuidTokenCount stays 1, operator is preserved
            } else {
                // Just decrement count
                uuidTokenCount[uuid]--;
            }
            
            // Refund tier bond to operator
            _refundBond(operator, tierBondAmount);

            emit FleetBurned(tokenHolder, tokenId, region, tier, tierBondAmount);
        }
    }

    // ══════════════════════════════════════════════
    // UUID Ownership (Owned-Only Mode)
    // ══════════════════════════════════════════════

    /// @notice Claim ownership of a UUID without registering in any region.
    ///         Costs BASE_BOND. The UUID can later be registered via registerFleetLocal/Country.
    /// @param uuid The Proximity UUID to claim.
    /// @param operator Optional operator address for future tier management. Use address(0) for owner as operator.
    /// @return tokenId The token ID for the owned-only UUID (region=0).
    function claimUuid(bytes16 uuid, address operator) external nonReentrant returns (uint256 tokenId) {
        if (uuid == bytes16(0)) revert InvalidUUID();
        if (uuidOwner[uuid] != address(0)) revert UuidAlreadyOwned();

        // Set ownership
        uuidOwner[uuid] = msg.sender;
        uuidLevel[uuid] = RegistrationLevel.Owned;
        uuidTokenCount[uuid] = 1;
        // Normalize operator: address(0) or msg.sender means owner is operator
        uuidOperator[uuid] = (operator == address(0) || operator == msg.sender) ? address(0) : operator;

        // Mint token with region=0
        tokenId = uint256(uint128(uuid));
        _mint(msg.sender, tokenId);

        _pullBond(msg.sender, BASE_BOND);

        emit UuidClaimed(msg.sender, uuid, operatorOf(uuid));
    }

    // ══════════════════════════════════════════════
    // Views: Bond & tier helpers
    // ══════════════════════════════════════════════

    /// @notice Bond required for tier K.
    ///         Local (admin area): BASE_BOND * 2^K
    ///         Country: BASE_BOND * COUNTRY_BOND_MULTIPLIER * 2^K (16× local)
    function tierBond(uint256 tier, bool isCountry) public view returns (uint256) {
        uint256 base = BASE_BOND << tier;
        return isCountry ? base * COUNTRY_BOND_MULTIPLIER : base;
    }

    /// @notice Returns the cheapest tier that guarantees a **local** fleet
    ///         appears in `buildHighestBondedUuidBundle` for (countryCode, adminCode).
    ///         Bounded: O(MAX_TIERS).
    function localInclusionHint(uint16 countryCode, uint16 adminCode)
        external
        view
        returns (uint256 inclusionTier, uint256 bond)
    {
        if (countryCode == 0 || countryCode > MAX_COUNTRY_CODE) revert InvalidCountryCode();
        if (adminCode == 0 || adminCode > MAX_ADMIN_CODE) revert InvalidAdminCode();
        inclusionTier = _findCheapestInclusionTier(countryCode, adminCode, false);
        bond = tierBond(inclusionTier, false);
    }

    /// @notice Returns the cheapest tier that guarantees a **country** fleet
    ///         appears in every `buildHighestBondedUuidBundle` query within
    ///         the country (across all active admin areas).
    /// @dev    Bounded view — iterates only over active admin areas in the
    ///         specific country (max 255). Safe for RPC calls.
    function countryInclusionHint(uint16 countryCode) external view returns (uint256 inclusionTier, uint256 bond) {
        if (countryCode == 0 || countryCode > MAX_COUNTRY_CODE) revert InvalidCountryCode();

        // Check the country-only location (no admin area active).
        inclusionTier = _findCheapestInclusionTier(countryCode, 0, true);

        // Scan only admin areas belonging to this specific country (bounded by MAX_ADMIN_CODE=255).
        uint32[] storage countryAreas = _countryAdminAreas[countryCode];
        uint256 len = countryAreas.length;
        for (uint256 i = 0; i < len; ++i) {
            uint16 admin = _adminFromRegion(countryAreas[i]);
            uint256 t = _findCheapestInclusionTier(countryCode, admin, true);
            if (t > inclusionTier) inclusionTier = t;
        }
        bond = tierBond(inclusionTier, true);
    }

    /// @notice Highest non-empty tier in a region, or 0 if none.
    function highestActiveTier(uint32 regionKey) external view returns (uint256) {
        uint256 tierCount = regionTierCount[regionKey];
        if (tierCount == 0) return 0;
        return tierCount - 1;
    }

    /// @notice Number of members in a specific tier of a region.
    function tierMemberCount(uint32 regionKey, uint256 tier) external view returns (uint256) {
        return _regionTierMembers[regionKey][tier].length;
    }

    /// @notice All token IDs in a specific tier of a region.
    function getTierMembers(uint32 regionKey, uint256 tier) external view returns (uint256[] memory) {
        return _regionTierMembers[regionKey][tier];
    }

    /// @notice All UUIDs in a specific tier of a region.
    function getTierUuids(uint32 regionKey, uint256 tier) external view returns (bytes16[] memory uuids) {
        uint256[] storage members = _regionTierMembers[regionKey][tier];
        uuids = new bytes16[](members.length);
        for (uint256 i = 0; i < members.length; ++i) {
            uuids[i] = tokenUuid(members[i]);
        }
    }

    /// @notice UUID for a token ID (extracts lower 128 bits).
    function tokenUuid(uint256 tokenId) public pure returns (bytes16) {
        return bytes16(uint128(tokenId));
    }

    /// @notice Region key encoded in a token ID (extracts bits 128-159).
    function tokenRegion(uint256 tokenId) public pure returns (uint32) {
        return uint32(tokenId >> 128);
    }

    /// @notice Computes the deterministic token ID for a uuid+region pair.
    function computeTokenId(bytes16 uuid, uint32 regionKey) public pure returns (uint256) {
        return (uint256(regionKey) << 128) | uint256(uint128(uuid));
    }

    /// @notice Bond amount for a token. Returns 0 for nonexistent tokens.
    function bonds(uint256 tokenId) external view returns (uint256) {
        if (_ownerOf(tokenId) == address(0)) return 0;
        uint32 region = tokenRegion(tokenId);
        if (region == OWNED_REGION_KEY) return BASE_BOND;
        return tierBond(fleetTier[tokenId], _isCountryRegion(region));
    }

    /// @notice Returns true if the UUID is in owned-only state (claimed but not registered).
    function isOwnedOnly(bytes16 uuid) external view returns (bool) {
        return uuidLevel[uuid] == RegistrationLevel.Owned;
    }

    /// @notice Returns the effective operator for a UUID.
    ///         If no explicit operator is set, returns the uuidOwner (owner acts as operator).
    ///         Returns address(0) if UUID is not registered.
    /// @param uuid The UUID to query.
    /// @return operator The effective operator address responsible for tier maintenance.
    function operatorOf(bytes16 uuid) public view returns (address operator) {
        operator = uuidOperator[uuid];
        if (operator == address(0)) {
            operator = uuidOwner[uuid];
        }
    }

    // ══════════════════════════════════════════════
    // Views: EdgeBeaconScanner discovery
    // ══════════════════════════════════════════════

    /// @notice Builds a priority-ordered bundle of up to 20 UUIDs for an EdgeBeaconScanner,
    ///         merging the highest-bonded tiers across admin-area and country levels.
    ///
    /// @dev    **Priority Rules:**
    ///         1. Higher bond tier always beats lower bond tier
    ///         2. Within same tier: local (admin area) beats country
    ///         3. Within same tier + level: earlier registration wins
    ///
    ///         **Economic Fairness:** Country fleets pay 16× more (COUNTRY_BOND_MULTIPLIER)
    ///         than local fleets at the same tier. This means a local can reach tier 4
    ///         for the same cost a country player pays for tier 0, giving locals a
    ///         significant economic advantage when competing for bundle slots.
    ///
    /// @param countryCode EdgeBeaconScanner country (must be > 0).
    /// @param adminCode   EdgeBeaconScanner admin area (must be > 0).
    /// @return uuids      The merged UUID bundle (up to 20).
    /// @return count      Actual number of UUIDs returned.
    function buildHighestBondedUuidBundle(uint16 countryCode, uint16 adminCode)
        external
        view
        returns (bytes16[] memory uuids, uint256 count)
    {
        if (countryCode == 0) revert InvalidCountryCode();
        if (adminCode == 0) revert AdminAreaRequired();

        uint32 countryKey = uint32(countryCode);
        uint32 adminKey = makeAdminRegion(countryCode, adminCode);

        (uuids, count, , ) = _buildHighestBondedUuidBundle(countryKey, adminKey);
    }

    /// @notice Builds a bundle containing ONLY country-level fleets for a country.
    ///         Use this when no admin areas are active to verify country fleet positions.
    ///
    /// @dev    When no admin areas exist in a country, EdgeBeaconScanners are not yet
    ///         active there. This function lets country fleet owners inspect their
    ///         competitive position before scanners come online.
    ///
    ///         The returned bundle represents the country-only contribution to any
    ///         future admin-area bundle. Local fleets (when they appear) will have
    ///         priority over country fleets at the same tier.
    ///
    /// @param countryCode ISO 3166-1 numeric country code (1-999).
    /// @return uuids      The country-only UUID bundle (up to 20).
    /// @return count      Actual number of UUIDs returned.
    function buildCountryOnlyBundle(uint16 countryCode)
        external
        view
        returns (bytes16[] memory uuids, uint256 count)
    {
        if (countryCode == 0 || countryCode > MAX_COUNTRY_CODE) revert InvalidCountryCode();

        uint32 countryKey = uint32(countryCode);
        // Use a virtual admin region with no members (adminCode=0)
        uint32 adminKey = makeAdminRegion(countryCode, 0);

        (uuids, count, , ) = _buildHighestBondedUuidBundle(countryKey, adminKey);
    }

    /// @dev Internal bundle builder that returns additional state for `_findCheapestInclusionTier`.
    ///
    ///      Builds a priority-ordered bundle by descending from highestTier to tier 0,
    ///      including admin-area members before country members at each tier.
    ///
    /// @return uuids       The UUIDs included in the bundle (trimmed to actual count).
    /// @return count       Number of UUIDs in the bundle.
    /// @return highestTier The highest tier with any registered members.
    /// @return lowestTier  The lowest tier processed (may be > 0 if bundle filled early).
    function _buildHighestBondedUuidBundle(uint32 countryKey, uint32 adminKey)
        internal
        view
        returns (bytes16[] memory uuids, uint256 count, uint256 highestTier, uint256 lowestTier)
    {
        highestTier = _findMaxTierIndex(countryKey, adminKey);

        uuids = new bytes16[](MAX_BONDED_UUID_BUNDLE_SIZE);

        // Simple tier-descent: at each tier, locals first, then country
        for (lowestTier = highestTier + 1; lowestTier > 0 && count < MAX_BONDED_UUID_BUNDLE_SIZE;) {
            unchecked { --lowestTier; }

            // Include local (admin area) members first
            count = _appendTierUuids(adminKey, lowestTier, uuids, count);

            // Include country members
            count = _appendTierUuids(countryKey, lowestTier, uuids, count);
        }

        // Trim array to actual size
        assembly {
            mstore(uuids, count)
        }
    }

    /// @dev Appends UUIDs from a region's tier to the bundle array.
    ///      If the tier has no members (empty region or tier beyond regionTierCount),
    ///      this is a no-op. Returns the updated count.
    function _appendTierUuids(
        uint32 regionKey,
        uint256 tier,
        bytes16[] memory uuids,
        uint256 count
    ) internal view returns (uint256) {
        uint256[] storage members = _regionTierMembers[regionKey][tier];
        uint256 len = members.length;
        uint256 room = MAX_BONDED_UUID_BUNDLE_SIZE - count;
        uint256 toInclude = len < room ? len : room;

        for (uint256 i = 0; i < toInclude; ++i) {
            uuids[count] = tokenUuid(members[i]);
            unchecked { ++count; }
        }
        return count;
    }

    // ══════════════════════════════════════════════
    // Views: Region indexes
    // ══════════════════════════════════════════════

    /// @notice Returns all country codes with at least one active fleet.
    function getActiveCountries() external view returns (uint16[] memory) {
        return _activeCountries;
    }

    /// @notice Returns all admin-area region keys with at least one active fleet.
    /// @dev    Computed by iterating active countries. O(countries × avg_admins).
    function getActiveAdminAreas() external view returns (uint32[] memory) {
        // Count total admin areas across all countries
        uint256 total = 0;
        uint256 countryCount = _activeCountries.length;
        for (uint256 i = 0; i < countryCount; ++i) {
            total += _countryAdminAreas[_activeCountries[i]].length;
        }

        // Build result array
        uint32[] memory result = new uint32[](total);
        uint256 idx = 0;
        for (uint256 i = 0; i < countryCount; ++i) {
            uint32[] storage areas = _countryAdminAreas[_activeCountries[i]];
            uint256 areaCount = areas.length;
            for (uint256 j = 0; j < areaCount; ++j) {
                result[idx++] = areas[j];
            }
        }
        return result;
    }

    /// @notice Returns the admin areas active in a specific country.
    /// @dev    Useful for off-chain enumeration without full index scan.
    function getCountryAdminAreas(uint16 countryCode) external view returns (uint32[] memory) {
        return _countryAdminAreas[countryCode];
    }

    /// @notice Builds an admin-area region key from country + admin codes.
    /// @dev Country region key is simply uint32(countryCode) - no helper needed.
    function makeAdminRegion(uint16 countryCode, uint16 adminCode) public pure returns (uint32) {
        return (uint32(countryCode) << uint32(ADMIN_SHIFT)) | uint32(adminCode);
    }

    // ══════════════════════════════════════════════
    // Internals
    // ══════════════════════════════════════════════

    // -- Region key encoding --

    /// @dev Extracts the country code from an admin-area region key.
    function _countryFromRegion(uint32 adminRegion) internal pure returns (uint16) {
        return uint16(adminRegion >> uint32(ADMIN_SHIFT));
    }

    /// @dev Extracts the admin code from an admin-area region key.
    function _adminFromRegion(uint32 adminRegion) internal pure returns (uint16) {
        return uint16(adminRegion & ADMIN_CODE_MASK);
    }

    /// @dev Returns true if the region key represents a country-level registration.
    ///      Region 0 (owned-only) is not a country region.
    function _isCountryRegion(uint32 regionKey) internal pure returns (bool) {
        return regionKey > 0 && regionKey <= MAX_COUNTRY_CODE;
    }

    // -- Bond transfer helpers --

    /// @dev Pulls bond tokens from an address (CEI: call after state changes).
    function _pullBond(address from, uint256 amount) internal {
        if (amount > 0) {
            BOND_TOKEN.safeTransferFrom(from, address(this), amount);
        }
    }

    /// @dev Refunds bond tokens to an address (CEI: call after state changes).
    function _refundBond(address to, uint256 amount) internal {
        if (amount > 0) {
            BOND_TOKEN.safeTransfer(to, amount);
        }
    }

    // -- UUID ownership helpers --

    /// @dev Clears all UUID ownership state. Used when last token for a UUID is burned.
    function _clearUuidOwnership(bytes16 uuid) internal {
        delete uuidOwner[uuid];
        delete uuidTokenCount[uuid];
        delete uuidLevel[uuid];
        delete uuidOperator[uuid];
        delete uuidTotalTierBonds[uuid];
    }

    /// @dev Decrements UUID token count. Clears ownership if count reaches zero.
    /// @return newCount The new token count after decrement.
    function _decrementUuidCount(bytes16 uuid) internal returns (uint256 newCount) {
        newCount = uuidTokenCount[uuid] - 1;
        if (newCount == 0) {
            _clearUuidOwnership(uuid);
        } else {
            uuidTokenCount[uuid] = newCount;
        }
    }

    // -- Tier cleanup helpers --

    /// @dev Removes a fleet from its tier and cleans up associated state.
    ///      Does NOT burn the token - caller must handle that.
    function _cleanupFleetFromTier(uint256 tokenId, uint32 region, uint256 tier) internal {
        _removeFromTier(tokenId, region, tier);
        delete fleetTier[tokenId];
        delete _indexInTier[tokenId];
        _trimTierCount(region);
        _removeFromRegionIndex(region);
    }

    // -- Registration helpers --

    /// @dev Mints a fleet token to msg.sender. Used for fresh registrations.
    /// @return tokenId The newly minted token ID.
    function _mintFleetToken(bytes16 uuid, uint32 region, uint256 tier) internal returns (uint256 tokenId) {
        tokenId = computeTokenId(uuid, region);
        fleetTier[tokenId] = tier;
        _addToTier(tokenId, region, tier);
        _addToRegionIndex(region);
        _mint(msg.sender, tokenId);
    }

    /// @dev Mints a fleet token to a specific owner. Used when operator registers for an owner.
    /// @return tokenId The newly minted token ID.
    function _mintFleetTokenTo(address to, bytes16 uuid, uint32 region, uint256 tier) internal returns (uint256 tokenId) {
        tokenId = computeTokenId(uuid, region);
        fleetTier[tokenId] = tier;
        _addToTier(tokenId, region, tier);
        _addToRegionIndex(region);
        _mint(to, tokenId);
    }

    /// @dev Shared registration logic. Handles fresh, Owned → Registered, and multi-region registrations.
    ///      Only operator can register. Operator pays tier bond; owner pays BASE_BOND.
    ///      For fresh UUIDs, caller becomes both owner and operator.
    /// @param uuid The Proximity UUID to register.
    /// @param region The region key (country or admin area).
    /// @param targetTier The tier to register at.
    function _register(bytes16 uuid, uint32 region, uint256 targetTier) internal returns (uint256 tokenId) {
        RegistrationLevel existingLevel = uuidLevel[uuid];
        bool isCountry = _isCountryRegion(region);
        RegistrationLevel targetLevel = isCountry ? RegistrationLevel.Country : RegistrationLevel.Local;
        uint256 targetTierBond = tierBond(targetTier, isCountry);

        if (existingLevel == RegistrationLevel.Owned) {
            // Owned → Registered transition: only operator can register
            address operator = operatorOf(uuid);
            if (operator != msg.sender) revert NotOperator();
            address owner = uuidOwner[uuid];
            
            _burn(uint256(uint128(uuid))); // Burn owned-only token
            uuidLevel[uuid] = targetLevel;
            uuidTotalTierBonds[uuid] = targetTierBond;
            
            tokenId = _mintFleetTokenTo(owner, uuid, region, targetTier);
            
            // Operator pays full tier bond (owner already paid BASE_BOND via claimUuid)
            _pullBond(operator, targetTierBond);
            
            emit FleetRegistered(owner, uuid, tokenId, region, targetTier, targetTierBond, operator);
        } else if (existingLevel == RegistrationLevel.None) {
            // Fresh registration: caller becomes owner+operator, pays BASE_BOND + tier bond
            uuidOwner[uuid] = msg.sender;
            uuidLevel[uuid] = targetLevel;
            uuidTokenCount[uuid] = 1;
            uuidTotalTierBonds[uuid] = targetTierBond;
            // uuidOperator stays address(0) - caller acts as operator via operatorOf()
            
            tokenId = _mintFleetToken(uuid, region, targetTier);
            
            // Caller pays BASE_BOND (ownership) + tier bond (registration)
            _pullBond(msg.sender, BASE_BOND + targetTierBond);
            
            emit FleetRegistered(msg.sender, uuid, tokenId, region, targetTier, BASE_BOND + targetTierBond, msg.sender);
        } else {
            // Multi-region registration: only operator can register additional regions
            address operator = operatorOf(uuid);
            if (operator != msg.sender) revert NotOperator();
            if (existingLevel != targetLevel) revert UuidLevelMismatch();
            address owner = uuidOwner[uuid];
            
            uuidTokenCount[uuid]++;
            uuidTotalTierBonds[uuid] += targetTierBond;
            
            tokenId = _mintFleetTokenTo(owner, uuid, region, targetTier);
            
            // Operator pays tier bond
            _pullBond(operator, targetTierBond);
            
            emit FleetRegistered(owner, uuid, tokenId, region, targetTier, targetTierBond, operator);
        }
    }

    /// @dev Shared promotion logic. Only operator can call.
    function _promote(uint256 tokenId, uint256 targetTier) internal {
        bytes16 uuid = tokenUuid(tokenId);
        address operator = operatorOf(uuid);
        if (operator != msg.sender) revert NotOperator();

        uint32 region = tokenRegion(tokenId);
        uint256 currentTier = fleetTier[tokenId];
        if (targetTier <= currentTier) revert TargetTierNotHigher();
        if (targetTier >= MAX_TIERS) revert MaxTiersReached();
        if (_regionTierMembers[region][targetTier].length >= TIER_CAPACITY) revert TierFull();

        bool isCountry = _isCountryRegion(region);
        uint256 currentBond = tierBond(currentTier, isCountry);
        uint256 targetBond = tierBond(targetTier, isCountry);
        uint256 additionalBond = targetBond - currentBond;

        // Effects
        uuidTotalTierBonds[uuid] += additionalBond;
        _removeFromTier(tokenId, region, currentTier);
        fleetTier[tokenId] = targetTier;
        _addToTier(tokenId, region, targetTier);

        // Interaction: pull from operator
        _pullBond(operator, additionalBond);

        emit FleetPromoted(tokenId, currentTier, targetTier, additionalBond);
    }

    /// @dev Shared demotion logic. Refunds bond difference to operator.
    function _demote(uint256 tokenId, uint256 targetTier) internal {
        bytes16 uuid = tokenUuid(tokenId);
        address operator = operatorOf(uuid);
        if (operator != msg.sender) revert NotOperator();

        uint32 region = tokenRegion(tokenId);
        uint256 currentTier = fleetTier[tokenId];
        if (targetTier >= currentTier) revert TargetTierNotLower();
        if (_regionTierMembers[region][targetTier].length >= TIER_CAPACITY) revert TierFull();

        bool isCountry = _isCountryRegion(region);
        uint256 currentBond = tierBond(currentTier, isCountry);
        uint256 targetBond = tierBond(targetTier, isCountry);
        uint256 refund = currentBond - targetBond;

        // Effects
        uuidTotalTierBonds[uuid] -= refund;
        _removeFromTier(tokenId, region, currentTier);
        fleetTier[tokenId] = targetTier;
        _addToTier(tokenId, region, targetTier);
        _trimTierCount(region);

        // Interaction: refund to operator
        _refundBond(operator, refund);

        emit FleetDemoted(tokenId, currentTier, targetTier, refund);
    }

    /// @dev Validates that a tier is available for registration (pure validation, no state changes).
    function _validateExplicitTier(uint32 region, uint256 targetTier) internal view {
        if (targetTier >= MAX_TIERS) revert MaxTiersReached();
        if (_regionTierMembers[region][targetTier].length >= TIER_CAPACITY) revert TierFull();
    }

    // -- Bundle-level helpers (shared by buildHighestBondedUuidBundle & inclusion hints) --

    /// @dev Finds the highest active tier index across both bundle levels.
    function _findMaxTierIndex(uint32 countryKey, uint32 adminKey)
        internal
        view
        returns (uint256 maxTierIndex)
    {
        uint256 adminTiers = regionTierCount[adminKey];
        uint256 countryTiers = regionTierCount[countryKey];

        uint256 maxTier = adminTiers > 0 ? adminTiers - 1 : 0;
        if (countryTiers > 0 && countryTiers - 1 > maxTier) maxTier = countryTiers - 1;
        return maxTier;
    }

    // -- Inclusion-tier logic --

    /// @dev Uses `_buildHighestBondedUuidBundle` to determine the cheapest tier at
    ///      `candidateRegion` that guarantees bundle inclusion. Bounded: O(MAX_TIERS).
    ///
    ///      Walks from the bundle's lowestTier upward, "unwinding" the bundle count
    ///      by subtracting both regions' contributions at each tier. Returns the first
    ///      tier where:
    ///      (a) The tier has capacity (< TIER_CAPACITY members).
    ///      (b) The unwound count shows room in the bundle (< MAX_BONDED_UUID_BUNDLE_SIZE).
    ///
    ///      If no existing tier qualifies and highestTier + 1 < MAX_TIERS, returns
    ///      highestTier + 1 (joining above current max guarantees inclusion).
    ///
    /// @param countryCode The country code for the bundle location.
    /// @param adminCode   The admin area code (0 for country-only bundles).
    /// @param isCountry   True if candidate is joining country region, false for admin.
    function _findCheapestInclusionTier(uint16 countryCode, uint16 adminCode, bool isCountry)
        internal
        view
        returns (uint256)
    {
        uint32 countryKey = uint32(countryCode);
        uint32 adminKey = makeAdminRegion(countryCode, adminCode);
        uint32 candidateRegion = isCountry ? countryKey : adminKey;

        (, uint256 count, uint256 highestTier, uint256 lowestTier) = _buildHighestBondedUuidBundle(countryKey, adminKey);

        // Walk from lowestTier upward, unwinding the bundle count at each tier.
        // Subtracting both regions' contributions simulates "what if we built the
        // bundle stopping at this tier instead".
        for (uint256 tier = lowestTier; tier <= highestTier; ++tier) {
            bool tierHasCapacity = _regionTierMembers[candidateRegion][tier].length < TIER_CAPACITY;
            bool bundleHasRoom = count < MAX_BONDED_UUID_BUNDLE_SIZE;

            if (tierHasCapacity && bundleHasRoom) {
                return tier;
            }

            // Unwind: subtract both regions' contributions at this tier.
            // Use saturating subtraction to handle edge cases gracefully.
            uint256 adminMembers = _regionTierMembers[adminKey][tier].length;
            uint256 countryMembers = _regionTierMembers[countryKey][tier].length;
            uint256 tierTotal = adminMembers + countryMembers;
            count = tierTotal > count ? 0 : count - tierTotal;
        }

        // No fit in existing tiers — try joining above current max.
        if (highestTier < MAX_TIERS - 1) {
            return highestTier + 1;
        }

        revert MaxTiersReached();
    }

    /// @dev Appends a token to a region's tier member array and records its index.
    ///      Updates regionTierCount if this opens a new highest tier.
    function _addToTier(uint256 tokenId, uint32 region, uint256 tier) internal {
        _regionTierMembers[region][tier].push(tokenId);
        _indexInTier[tokenId] = _regionTierMembers[region][tier].length - 1;

        // Update tier count if we're opening a new tier
        if (tier >= regionTierCount[region]) {
            regionTierCount[region] = tier + 1;
        }
    }

    /// @dev Swap-and-pop removal from a region's tier member array.
    function _removeFromTier(uint256 tokenId, uint32 region, uint256 tier) internal {
        uint256[] storage members = _regionTierMembers[region][tier];
        uint256 idx = _indexInTier[tokenId];
        uint256 lastIdx = members.length - 1;

        if (idx != lastIdx) {
            uint256 lastTokenId = members[lastIdx];
            members[idx] = lastTokenId;
            _indexInTier[lastTokenId] = idx;
        }
        members.pop();
    }

    /// @dev Shrinks regionTierCount so the top tier is always non-empty.
    function _trimTierCount(uint32 region) internal {
        uint256 tierCount = regionTierCount[region];
        while (tierCount > 0 && _regionTierMembers[region][tierCount - 1].length == 0) {
            tierCount--;
        }
        regionTierCount[region] = tierCount;
    }

    // -- Region index maintenance --

    /// @dev Adds a region to the appropriate index set if not already present.
    function _addToRegionIndex(uint32 region) internal {
        if (_isCountryRegion(region)) {
            // Country
            uint16 cc = uint16(region);
            if (_activeCountryIndex[cc] == 0) {
                _activeCountries.push(cc);
                _activeCountryIndex[cc] = _activeCountries.length; // 1-indexed
            }
        } else {
            // Admin area: add to country's list
            if (_countryAdminAreaIndex[region] == 0) {
                uint16 cc = _countryFromRegion(region);
                // Ensure country is in active list (for getActiveAdminAreas iteration)
                if (_activeCountryIndex[cc] == 0) {
                    _activeCountries.push(cc);
                    _activeCountryIndex[cc] = _activeCountries.length;
                }
                _countryAdminAreas[cc].push(region);
                _countryAdminAreaIndex[region] = _countryAdminAreas[cc].length;
            }
        }
    }

    /// @dev Removes a region from the index set if the region is now completely empty.
    function _removeFromRegionIndex(uint32 region) internal {
        if (regionTierCount[region] > 0) return; // still has fleets

        if (_isCountryRegion(region)) {
            uint16 cc = uint16(region);
            uint256 oneIdx = _activeCountryIndex[cc];
            if (oneIdx > 0) {
                // Only remove country if it has no admin areas
                if (_countryAdminAreas[cc].length > 0) return;

                uint256 lastIdx = _activeCountries.length - 1;
                uint256 removeIdx = oneIdx - 1;
                if (removeIdx != lastIdx) {
                    uint16 lastCountryCode = _activeCountries[lastIdx];
                    _activeCountries[removeIdx] = lastCountryCode;
                    _activeCountryIndex[lastCountryCode] = oneIdx;
                }
                _activeCountries.pop();
                delete _activeCountryIndex[cc];
            }
        } else {
            // Admin area: remove from country's list
            uint256 oneIdx = _countryAdminAreaIndex[region];
            if (oneIdx > 0) {
                uint16 cc = _countryFromRegion(region);
                uint32[] storage countryAreas = _countryAdminAreas[cc];
                uint256 lastIdx = countryAreas.length - 1;
                uint256 removeIdx = oneIdx - 1;
                if (removeIdx != lastIdx) {
                    uint32 lastArea = countryAreas[lastIdx];
                    countryAreas[removeIdx] = lastArea;
                    _countryAdminAreaIndex[lastArea] = oneIdx;
                }
                countryAreas.pop();
                delete _countryAdminAreaIndex[region];

                // Remove country from active list if no more admin areas AND no country fleets
                if (countryAreas.length == 0 && regionTierCount[uint32(cc)] == 0) {
                    uint256 countryOneIdx = _activeCountryIndex[cc];
                    if (countryOneIdx > 0) {
                        uint256 countryLastIdx = _activeCountries.length - 1;
                        uint256 countryRemoveIdx = countryOneIdx - 1;
                        if (countryRemoveIdx != countryLastIdx) {
                            uint16 lastCountryCode = _activeCountries[countryLastIdx];
                            _activeCountries[countryRemoveIdx] = lastCountryCode;
                            _activeCountryIndex[lastCountryCode] = countryOneIdx;
                        }
                        _activeCountries.pop();
                        delete _activeCountryIndex[cc];
                    }
                }
            }
        }
    }

    // ──────────────────────────────────────────────
    // Overrides required by ERC721Enumerable
    // ──────────────────────────────────────────────

    function _update(address to, uint256 tokenId, address auth) internal override(ERC721Enumerable) returns (address) {
        address from = super._update(to, tokenId, auth);
        
        // For owned-only tokens, transfer uuidOwner when the token is transferred
        // This allows marketplace trading of owned-only UUIDs
        uint32 region = tokenRegion(tokenId);
        if (region == OWNED_REGION_KEY && from != address(0) && to != address(0)) {
            uuidOwner[tokenUuid(tokenId)] = to;
        }
        
        return from;
    }

    function _increaseBalance(address account, uint128 value) internal override(ERC721Enumerable) {
        super._increaseBalance(account, value);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721Enumerable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
