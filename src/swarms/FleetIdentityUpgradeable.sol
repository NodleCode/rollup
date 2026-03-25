// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.24;

import {ERC721EnumerableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";

import {RegistrationLevel} from "./interfaces/SwarmTypes.sol";
import {IBondTreasury} from "./interfaces/IBondTreasury.sol";

/**
 * @title FleetIdentityUpgradeable
 * @notice UUPS-upgradeable ERC-721 with ERC721Enumerable representing ownership of a BLE fleet,
 *         secured by an ERC-20 bond organized into geometric tiers.
 *
 * @dev **Upgrade Pattern:**
 *      - Uses OpenZeppelin UUPS proxy pattern for upgradeability.
 *      - Only the contract owner can authorize upgrades.
 *      - Storage layout must be preserved across upgrades (append-only).
 *
 *      **Storage Migration Example (V1 → V2):**
 *      ```solidity
 *      function initializeV2(uint256 newParam) external reinitializer(2) {
 *          _newParamIntroducedInV2 = newParam;
 *      }
 *      ```
 *
 *      **Two-level geographic registration**
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
 *      **TokenID Encoding**
 *
 *      TokenID = (regionKey << 128) | uuid
 *        - Bits 0-127:   UUID (bytes16 Proximity UUID)
 *        - Bits 128-159: Region key (32-bit country or admin-area code)
 */
contract FleetIdentityUpgradeable is
    Initializable,
    ERC721EnumerableUpgradeable,
    Ownable2StepUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard
{
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
    error InvalidBaseBond();
    error InvalidMultiplier();
    error InvalidBondToken();

    // ──────────────────────────────────────────────
    // Constants
    // ──────────────────────────────────────────────

    /// @notice Unified tier capacity for all levels.
    uint256 public constant TIER_CAPACITY = 10;

    /// @notice Default country bond multiplier when not explicitly set (16× local).
    uint256 public constant DEFAULT_COUNTRY_BOND_MULTIPLIER = 16;

    /// @notice Default base bond for tier 0.
    uint256 public constant DEFAULT_BASE_BOND = 1e18;

    /// @notice Hard cap on tier count per region.
    uint256 public constant MAX_TIERS = 24;

    /// @notice Maximum UUIDs returned by buildHighestBondedUuidBundle.
    uint256 public constant MAX_BONDED_UUID_BUNDLE_SIZE = 20;

    /// @notice ISO 3166-1 numeric upper bound for country codes.
    uint16 internal constant MAX_COUNTRY_CODE = 999;

    /// @notice Upper bound for admin-area codes within a country.
    uint16 internal constant MAX_ADMIN_CODE = 255;

    /// @dev Bit shift for packing countryCode into an admin-area region key.
    uint256 private constant ADMIN_SHIFT = 10;
    /// @dev Bitmask for extracting adminCode from an admin-area region key.
    uint32 private constant ADMIN_CODE_MASK = 0x3FF;

    /// @notice Region key for owned-only UUIDs (not registered in any region).
    uint32 public constant OWNED_REGION_KEY = 0;

    // ──────────────────────────────────────────────
    // Storage (V1) - Order matters for upgrades!
    // ──────────────────────────────────────────────

    /// @notice The ERC-20 token used for bonds (e.g. NODL).
    /// @dev In non-upgradeable version this was immutable. Now stored in proxy storage.
    IERC20 private _bondToken;

    /// @notice Base bond for tier 0 in any region. Tier K requires BASE_BOND * 2^K.
    /// @dev In non-upgradeable version this was immutable. Now stored in proxy storage.
    uint256 private _baseBond;

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
    mapping(bytes16 => address) public uuidOwner;

    /// @notice UUID -> count of active tokens for this UUID (across all regions).
    mapping(bytes16 => uint256) public uuidTokenCount;

    /// @notice UUID -> registration level.
    mapping(bytes16 => RegistrationLevel) public uuidLevel;

    /// @notice UUID -> operator address for tier maintenance.
    mapping(bytes16 => address) public uuidOperator;

    /// @notice UUID -> total tier bonds across all registered regions.
    mapping(bytes16 => uint256) public uuidTotalTierBonds;

    // ──────────────────────────────────────────────
    // Bond Snapshots (for safe parameter reconfiguration)
    // ──────────────────────────────────────────────

    /// @notice Configurable country bond multiplier. 0 = use DEFAULT_COUNTRY_BOND_MULTIPLIER (16).
    /// @dev Can be updated by owner via setCountryBondMultiplier().
    uint256 private _countryBondMultiplier;

    /// @notice tokenId -> tier-0 equivalent bond paid at registration.
    /// @dev Stores baseBond (for local) or baseBond*multiplier (for country).
    ///      Actual tier K bond = tokenTier0Bond[tokenId] << K.
    mapping(uint256 => uint256) public tokenTier0Bond;

    /// @notice UUID -> ownership bond paid at claim/first-registration.
    /// @dev Refunded when owned-only token is burned.
    mapping(bytes16 => uint256) public uuidOwnershipBondPaid;

    // ──────────────────────────────────────────────
    // On-chain region indexes
    // ──────────────────────────────────────────────

    /// @dev Set of country codes with at least one active fleet.
    uint16[] internal _activeCountries;
    mapping(uint16 => uint256) internal _activeCountryIndex;

    /// @dev Country → list of admin-area region keys with at least one active fleet.
    mapping(uint16 => uint32[]) internal _countryAdminAreas;
    mapping(uint32 => uint256) internal _countryAdminAreaIndex;

    // ──────────────────────────────────────────────
    // Storage Gap (for future upgrades)
    // ──────────────────────────────────────────────

    /// @dev Reserved storage slots for future upgrades.
    ///      When adding new storage in V2+, reduce this gap accordingly.
    // solhint-disable-next-line var-name-mixedcase
    uint256[50] private __gap;

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
        bytes16 indexed uuid, address indexed oldOperator, address indexed newOperator, uint256 tierExcessTransferred
    );
    event FleetPromoted(
        uint256 indexed tokenId, uint256 indexed fromTier, uint256 indexed toTier, uint256 additionalBond
    );
    event FleetDemoted(uint256 indexed tokenId, uint256 indexed fromTier, uint256 indexed toTier, uint256 bondRefund);
    event FleetBurned(
        address indexed owner, uint256 indexed tokenId, uint32 indexed regionKey, uint256 tierIndex, uint256 bondRefund
    );
    event UuidClaimed(address indexed owner, bytes16 indexed uuid, address indexed operator);
    event BaseBondUpdated(uint256 indexed oldBaseBond, uint256 indexed newBaseBond);
    event CountryMultiplierUpdated(uint256 indexed oldMultiplier, uint256 indexed newMultiplier);

    // ──────────────────────────────────────────────
    // Constructor (disables initializers on implementation)
    // ──────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ──────────────────────────────────────────────
    // Initializer (replaces constructor)
    // ──────────────────────────────────────────────

    /// @notice Initializes the contract. Must be called once via proxy.
    /// @param owner_ The address that will own this contract and can authorize upgrades.
    /// @param bondToken_ Address of the ERC-20 token used for bonds (required).
    /// @param baseBond_ Base bond for tier 0 (0 = DEFAULT_BASE_BOND = 1M NODL).
    /// @param countryMultiplier_ Country bond multiplier (0 = DEFAULT_COUNTRY_BOND_MULTIPLIER = 16).
    function initialize(address owner_, address bondToken_, uint256 baseBond_, uint256 countryMultiplier_)
        external
        initializer
    {
        if (bondToken_ == address(0)) revert InvalidBondToken();

        __ERC721_init("Swarm Fleet Identity", "SFID");
        __ERC721Enumerable_init();
        __Ownable_init(owner_);
        __Ownable2Step_init();

        _bondToken = IERC20(bondToken_);
        _baseBond = baseBond_ == 0 ? DEFAULT_BASE_BOND : baseBond_;
        _countryBondMultiplier = countryMultiplier_ == 0 ? DEFAULT_COUNTRY_BOND_MULTIPLIER : countryMultiplier_;
    }

    // ──────────────────────────────────────────────
    // Admin Functions
    // ──────────────────────────────────────────────

    /// @notice Updates the base bond amount for future registrations.
    /// @dev Existing tokens use their stored snapshots for refunds.
    ///      **IMPORTANT**: Verify contract solvency before increasing.
    /// @param newBaseBond The new base bond amount (must be non-zero).
    function setBaseBond(uint256 newBaseBond) external onlyOwner {
        if (newBaseBond == 0) revert InvalidBaseBond();
        uint256 oldBaseBond = _baseBond;
        _baseBond = newBaseBond;
        emit BaseBondUpdated(oldBaseBond, newBaseBond);
    }

    /// @notice Updates the country bond multiplier for future registrations.
    /// @dev Existing tokens use their stored snapshots for refunds.
    ///      **IMPORTANT**: Verify contract solvency before increasing.
    /// @param newMultiplier The new multiplier (must be non-zero).
    function setCountryBondMultiplier(uint256 newMultiplier) external onlyOwner {
        if (newMultiplier == 0) revert InvalidMultiplier();
        uint256 oldMultiplier = countryBondMultiplier();
        _countryBondMultiplier = newMultiplier;
        emit CountryMultiplierUpdated(oldMultiplier, newMultiplier);
    }

    /// @notice Updates both bond parameters atomically for future registrations.
    /// @dev Existing tokens use their stored snapshots for refunds.
    ///      **IMPORTANT**: Verify contract solvency before increasing.
    /// @param newBaseBond The new base bond amount (must be non-zero).
    /// @param newMultiplier The new country multiplier (must be non-zero).
    function setBondParameters(uint256 newBaseBond, uint256 newMultiplier) external onlyOwner {
        if (newBaseBond == 0) revert InvalidBaseBond();
        if (newMultiplier == 0) revert InvalidMultiplier();

        uint256 oldBaseBond = _baseBond;
        uint256 oldMultiplier = countryBondMultiplier();

        _baseBond = newBaseBond;
        _countryBondMultiplier = newMultiplier;

        emit BaseBondUpdated(oldBaseBond, newBaseBond);
        emit CountryMultiplierUpdated(oldMultiplier, newMultiplier);
    }

    // ──────────────────────────────────────────────
    // Public Getters for former immutables
    // ──────────────────────────────────────────────

    /// @notice Returns the bond token address.
    function BOND_TOKEN() external view returns (IERC20) {
        return _bondToken;
    }

    /// @notice Returns the base bond amount.
    function BASE_BOND() external view returns (uint256) {
        return _baseBond;
    }

    /// @notice Returns the country bond multiplier.
    function countryBondMultiplier() public view returns (uint256) {
        return _countryBondMultiplier;
    }

    // ══════════════════════════════════════════════
    // Registration: Country (operator-only with tier)
    // ══════════════════════════════════════════════

    /// @notice Register a fleet under a country at a specific tier.
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
    function promote(uint256 tokenId) external nonReentrant {
        _promote(tokenId, fleetTier[tokenId] + 1);
    }

    /// @notice Moves a fleet to a different tier within its region.
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
    function setOperator(bytes16 uuid, address newOperator) external nonReentrant {
        if (uuidOwner[uuid] != msg.sender) revert NotUuidOwner();
        if (uuidLevel[uuid] == RegistrationLevel.None) {
            revert UuidNotOwned();
        }

        address oldOperator = operatorOf(uuid);
        address storedOperator = (newOperator == msg.sender) ? address(0) : newOperator;
        address effectiveNewOperator = (storedOperator == address(0)) ? msg.sender : storedOperator;

        uint256 tierBonds = uuidTotalTierBonds[uuid];

        uuidOperator[uuid] = storedOperator;

        if (tierBonds > 0 && oldOperator != effectiveNewOperator) {
            _pullBond(effectiveNewOperator, tierBonds);
            _refundBond(oldOperator, tierBonds);
        }

        emit OperatorSet(uuid, oldOperator, effectiveNewOperator, tierBonds);
    }

    // ══════════════════════════════════════════════
    // Burn
    // ══════════════════════════════════════════════

    /// @notice Burns the fleet NFT and refunds the bond.
    function burn(uint256 tokenId) external nonReentrant {
        address tokenHolder = ownerOf(tokenId);

        uint32 region = tokenRegion(tokenId);
        bytes16 uuid = tokenUuid(tokenId);
        address owner = uuidOwner[uuid];
        address operator = operatorOf(uuid);
        bool isLastToken = uuidTokenCount[uuid] == 1;

        if (region == OWNED_REGION_KEY) {
            if (tokenHolder != msg.sender) revert NotTokenOwner();

            // Use snapshot for accurate refund
            uint256 ownershipBond = uuidOwnershipBondPaid[uuid];

            _burn(tokenId);
            _clearUuidOwnership(uuid);
            _refundBond(owner, ownershipBond);

            emit FleetBurned(tokenHolder, tokenId, region, 0, ownershipBond);
        } else {
            if (msg.sender != operator) {
                revert NotOperator();
            }

            uint256 tier = fleetTier[tokenId];
            // Use snapshot for accurate refund
            uint256 tierBondAmount = _tokenTierBond(tokenId, tier);

            uuidTotalTierBonds[uuid] -= tierBondAmount;

            _cleanupFleetFromTier(tokenId, region, tier);
            delete tokenTier0Bond[tokenId];
            _burn(tokenId);

            if (isLastToken) {
                uuidLevel[uuid] = RegistrationLevel.Owned;
                uint256 ownedTokenId = uint256(uint128(uuid));
                _mint(owner, ownedTokenId);
            } else {
                uuidTokenCount[uuid]--;
            }

            _refundBond(operator, tierBondAmount);

            emit FleetBurned(tokenHolder, tokenId, region, tier, tierBondAmount);
        }
    }

    // ══════════════════════════════════════════════
    // UUID Ownership (Owned-Only Mode)
    // ══════════════════════════════════════════════

    /// @notice Claim ownership of a UUID without registering in any region.
    function claimUuid(bytes16 uuid, address operator) external nonReentrant returns (uint256 tokenId) {
        if (uuid == bytes16(0)) revert InvalidUUID();
        if (uuidOwner[uuid] != address(0)) revert UuidAlreadyOwned();

        uuidOwner[uuid] = msg.sender;
        uuidLevel[uuid] = RegistrationLevel.Owned;
        uuidTokenCount[uuid] = 1;
        uuidOperator[uuid] = (operator == address(0) || operator == msg.sender) ? address(0) : operator;

        tokenId = uint256(uint128(uuid));
        _mint(msg.sender, tokenId);

        uuidOwnershipBondPaid[uuid] = _baseBond;
        _pullBond(msg.sender, _baseBond);

        emit UuidClaimed(msg.sender, uuid, operatorOf(uuid));
    }

    /// @notice Claim a UUID with the bond paid by a caller-specified treasury.
    /// @dev The treasury's `consumeSponsoredBond` validates msg.sender (whitelist, quota, etc.),
    ///      then FleetIdentity pulls the bond from the treasury via `transferFrom` on the
    ///      **trusted bond token**. Security does not depend on the treasury implementation:
    ///      - Bond payment is enforced by the immutable `_bondToken` contract, not the treasury.
    ///      - Reentrancy is blocked by `nonReentrant`.
    ///      - Beneficiary is always `msg.sender` — no third-party can set a different owner.
    ///      Different treasuries with different policies (whitelist, quota, geographic) can
    ///      coexist; FleetIdentity only cares that the bond is paid.
    /// @param uuid The UUID to claim.
    /// @param operator The operator for tier management (address(0) or msg.sender = self-operate).
    /// @param treasury The bond treasury that will fund this claim. Must implement IBondTreasury
    ///        and have approved this contract to spend its bond tokens.
    /// @return tokenId The newly minted token ID.
    function claimUuidSponsored(bytes16 uuid, address operator, address treasury)
        external
        nonReentrant
        returns (uint256 tokenId)
    {
        if (uuid == bytes16(0)) revert InvalidUUID();
        if (uuidOwner[uuid] != address(0)) revert UuidAlreadyOwned();

        // Treasury validates msg.sender's eligibility and consumes quota.
        // If treasury is an EOA or no-op contract, this succeeds but the
        // bond is still enforced by _pullBond below.
        IBondTreasury(treasury).consumeSponsoredBond(msg.sender, _baseBond);

        uuidOwner[uuid] = msg.sender;
        uuidLevel[uuid] = RegistrationLevel.Owned;
        uuidTokenCount[uuid] = 1;
        uuidOperator[uuid] = (operator == address(0) || operator == msg.sender) ? address(0) : operator;

        tokenId = uint256(uint128(uuid));
        uuidOwnershipBondPaid[uuid] = _baseBond;
        _mint(msg.sender, tokenId);

        // Bond transfer uses the trusted _bondToken — cannot be faked by the treasury.
        _pullBond(treasury, _baseBond);

        emit UuidClaimed(msg.sender, uuid, operatorOf(uuid));
    }

    // ══════════════════════════════════════════════
    // Views: Bond & tier helpers
    // ══════════════════════════════════════════════

    /// @notice Bond required for tier K at current parameters.
    /// @dev Use _tokenTierBond for refund calculations on existing tokens.
    function tierBond(uint256 tier, bool isCountry) public view returns (uint256) {
        uint256 base = _baseBond << tier;
        return isCountry ? base * countryBondMultiplier() : base;
    }

    /// @notice Bond for a token at a given tier based on registration-time parameters.
    /// @dev Uses tier-0 bond stored at registration; returns 0 for non-existent tokens.
    function _tokenTierBond(uint256 tokenId, uint256 tier) internal view returns (uint256) {
        return tokenTier0Bond[tokenId] << tier;
    }

    /// @notice Returns the cheapest tier for local inclusion.
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

    /// @notice Returns the cheapest tier for country inclusion.
    function countryInclusionHint(uint16 countryCode) external view returns (uint256 inclusionTier, uint256 bond) {
        if (countryCode == 0 || countryCode > MAX_COUNTRY_CODE) revert InvalidCountryCode();

        inclusionTier = _findCheapestInclusionTier(countryCode, 0, true);

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

    /// @notice UUID for a token ID.
    function tokenUuid(uint256 tokenId) public pure returns (bytes16) {
        return bytes16(uint128(tokenId));
    }

    /// @notice Region key encoded in a token ID.
    function tokenRegion(uint256 tokenId) public pure returns (uint32) {
        return uint32(tokenId >> 128);
    }

    /// @notice Computes the deterministic token ID for a uuid+region pair.
    function computeTokenId(bytes16 uuid, uint32 regionKey) public pure returns (uint256) {
        return (uint256(regionKey) << 128) | uint256(uint128(uuid));
    }

    /// @notice Bond amount for a token.
    function bonds(uint256 tokenId) external view returns (uint256) {
        if (_ownerOf(tokenId) == address(0)) return 0;
        uint32 region = tokenRegion(tokenId);
        if (region == OWNED_REGION_KEY) return _baseBond;
        return tierBond(fleetTier[tokenId], _isCountryRegion(region));
    }

    /// @notice Returns true if the UUID is in owned-only state.
    function isOwnedOnly(bytes16 uuid) external view returns (bool) {
        return uuidLevel[uuid] == RegistrationLevel.Owned;
    }

    /// @notice Returns the effective operator for a UUID.
    function operatorOf(bytes16 uuid) public view returns (address operator) {
        operator = uuidOperator[uuid];
        if (operator == address(0)) {
            operator = uuidOwner[uuid];
        }
    }

    // ══════════════════════════════════════════════
    // Views: EdgeBeaconScanner discovery
    // ══════════════════════════════════════════════

    /// @notice Builds a priority-ordered bundle of up to 20 UUIDs.
    function buildHighestBondedUuidBundle(uint16 countryCode, uint16 adminCode)
        external
        view
        returns (bytes16[] memory uuids, uint256 count)
    {
        if (countryCode == 0 || countryCode > MAX_COUNTRY_CODE) revert InvalidCountryCode();
        if (adminCode == 0 || adminCode > MAX_ADMIN_CODE) revert AdminAreaRequired();

        uint32 countryKey = uint32(countryCode);
        uint32 adminKey = makeAdminRegion(countryCode, adminCode);

        (uuids, count,,) = _buildHighestBondedUuidBundle(countryKey, adminKey);
    }

    /// @notice Builds a bundle containing ONLY country-level fleets.
    function buildCountryOnlyBundle(uint16 countryCode)
        external
        view
        returns (bytes16[] memory uuids, uint256 count)
    {
        if (countryCode == 0 || countryCode > MAX_COUNTRY_CODE) revert InvalidCountryCode();

        uint32 countryKey = uint32(countryCode);
        uint32 adminKey = makeAdminRegion(countryCode, 0);

        (uuids, count,,) = _buildHighestBondedUuidBundle(countryKey, adminKey);
    }

    // ══════════════════════════════════════════════
    // Views: Region indexes
    // ══════════════════════════════════════════════

    /// @notice Returns all country codes that have at least one active fleet.
    /// @return Array of ISO 3166-1 numeric country codes.
    function getActiveCountries() external view returns (uint16[] memory) {
        return _activeCountries;
    }

    /// @notice Returns all admin-area region keys across all countries.
    /// @return Array of encoded region keys (countryCode << 10 | adminCode).
    function getActiveAdminAreas() external view returns (uint32[] memory) {
        uint256 total = 0;
        uint256 countryCount = _activeCountries.length;
        for (uint256 i = 0; i < countryCount; ++i) {
            total += _countryAdminAreas[_activeCountries[i]].length;
        }

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

    /// @notice Returns all active admin-area region keys for a specific country.
    /// @param countryCode ISO 3166-1 numeric country code.
    /// @return Array of encoded region keys for that country.
    function getCountryAdminAreas(uint16 countryCode) external view returns (uint32[] memory) {
        return _countryAdminAreas[countryCode];
    }

    /// @notice Encodes a country code and admin code into a region key.
    /// @param countryCode ISO 3166-1 numeric country code (1-999).
    /// @param adminCode Admin-area code within the country (1-255).
    /// @return Encoded region key: (countryCode << 10) | adminCode.
    function makeAdminRegion(uint16 countryCode, uint16 adminCode) public pure returns (uint32) {
        return (uint32(countryCode) << uint32(ADMIN_SHIFT)) | uint32(adminCode);
    }

    // ══════════════════════════════════════════════
    // UUPS Authorization
    // ══════════════════════════════════════════════

    /// @dev Only the owner can authorize an upgrade.
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // ══════════════════════════════════════════════
    // Internal Functions
    // ══════════════════════════════════════════════

    function _countryFromRegion(uint32 adminRegion) internal pure returns (uint16) {
        return uint16(adminRegion >> uint32(ADMIN_SHIFT));
    }

    function _adminFromRegion(uint32 adminRegion) internal pure returns (uint16) {
        return uint16(adminRegion & ADMIN_CODE_MASK);
    }

    function _isCountryRegion(uint32 regionKey) internal pure returns (bool) {
        return regionKey > 0 && regionKey <= MAX_COUNTRY_CODE;
    }

    function _pullBond(address from, uint256 amount) internal {
        if (amount > 0) {
            _bondToken.safeTransferFrom(from, address(this), amount);
        }
    }

    function _refundBond(address to, uint256 amount) internal {
        if (amount > 0) {
            _bondToken.safeTransfer(to, amount);
        }
    }

    function _clearUuidOwnership(bytes16 uuid) internal {
        delete uuidOwner[uuid];
        delete uuidTokenCount[uuid];
        delete uuidLevel[uuid];
        delete uuidOperator[uuid];
        delete uuidTotalTierBonds[uuid];
        delete uuidOwnershipBondPaid[uuid];
    }

    function _decrementUuidCount(bytes16 uuid) internal returns (uint256 newCount) {
        newCount = uuidTokenCount[uuid] - 1;
        if (newCount == 0) {
            _clearUuidOwnership(uuid);
        } else {
            uuidTokenCount[uuid] = newCount;
        }
    }

    function _cleanupFleetFromTier(uint256 tokenId, uint32 region, uint256 tier) internal {
        _removeFromTier(tokenId, region, tier);
        delete fleetTier[tokenId];
        delete _indexInTier[tokenId];
        _trimTierCount(region);
        _removeFromRegionIndex(region);
    }

    function _mintFleetToken(bytes16 uuid, uint32 region, uint256 tier) internal returns (uint256 tokenId) {
        tokenId = computeTokenId(uuid, region);
        fleetTier[tokenId] = tier;
        _addToTier(tokenId, region, tier);
        _addToRegionIndex(region);
        _mint(msg.sender, tokenId);
    }

    function _mintFleetTokenTo(address to, bytes16 uuid, uint32 region, uint256 tier)
        internal
        returns (uint256 tokenId)
    {
        tokenId = computeTokenId(uuid, region);
        fleetTier[tokenId] = tier;
        _addToTier(tokenId, region, tier);
        _addToRegionIndex(region);
        _mint(to, tokenId);
    }

    function _register(bytes16 uuid, uint32 region, uint256 targetTier) internal returns (uint256 tokenId) {
        RegistrationLevel existingLevel = uuidLevel[uuid];
        bool isCountry = _isCountryRegion(region);
        RegistrationLevel targetLevel = isCountry ? RegistrationLevel.Country : RegistrationLevel.Local;
        uint256 targetTierBond = tierBond(targetTier, isCountry);

        // Store tier-0 equivalent bond for accurate refunds when parameters change
        uint256 tier0Bond = isCountry ? _baseBond * countryBondMultiplier() : _baseBond;

        if (existingLevel == RegistrationLevel.Owned) {
            address operator = operatorOf(uuid);
            if (operator != msg.sender) revert NotOperator();
            address owner_ = uuidOwner[uuid];

            _burn(uint256(uint128(uuid)));
            uuidLevel[uuid] = targetLevel;
            uuidTotalTierBonds[uuid] = targetTierBond;

            tokenId = _mintFleetTokenTo(owner_, uuid, region, targetTier);
            tokenTier0Bond[tokenId] = tier0Bond;

            _pullBond(operator, targetTierBond);

            emit FleetRegistered(owner_, uuid, tokenId, region, targetTier, targetTierBond, operator);
        } else if (existingLevel == RegistrationLevel.None) {
            uuidOwner[uuid] = msg.sender;
            uuidLevel[uuid] = targetLevel;
            uuidTokenCount[uuid] = 1;
            uuidTotalTierBonds[uuid] = targetTierBond;

            tokenId = _mintFleetToken(uuid, region, targetTier);
            tokenTier0Bond[tokenId] = tier0Bond;
            uuidOwnershipBondPaid[uuid] = _baseBond;

            _pullBond(msg.sender, _baseBond + targetTierBond);

            emit FleetRegistered(msg.sender, uuid, tokenId, region, targetTier, _baseBond + targetTierBond, msg.sender);
        } else {
            address operator = operatorOf(uuid);
            if (operator != msg.sender) revert NotOperator();
            if (existingLevel != targetLevel) revert UuidLevelMismatch();
            address owner_ = uuidOwner[uuid];

            uuidTokenCount[uuid]++;
            uuidTotalTierBonds[uuid] += targetTierBond;

            tokenId = _mintFleetTokenTo(owner_, uuid, region, targetTier);
            tokenTier0Bond[tokenId] = tier0Bond;

            _pullBond(operator, targetTierBond);

            emit FleetRegistered(owner_, uuid, tokenId, region, targetTier, targetTierBond, operator);
        }
    }

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
        // Use stored tier-0 bond for current, current rate for target
        uint256 currentBond = _tokenTierBond(tokenId, currentTier);
        uint256 targetBond = tierBond(targetTier, isCountry);
        uint256 additionalBond = targetBond - currentBond;

        // Update tier-0 bond to current parameters since they're paying at current rates
        tokenTier0Bond[tokenId] = isCountry ? _baseBond * countryBondMultiplier() : _baseBond;

        uuidTotalTierBonds[uuid] += additionalBond;
        _removeFromTier(tokenId, region, currentTier);
        fleetTier[tokenId] = targetTier;
        _addToTier(tokenId, region, targetTier);

        _pullBond(operator, additionalBond);

        emit FleetPromoted(tokenId, currentTier, targetTier, additionalBond);
    }

    function _demote(uint256 tokenId, uint256 targetTier) internal {
        bytes16 uuid = tokenUuid(tokenId);
        address operator = operatorOf(uuid);
        if (operator != msg.sender) revert NotOperator();

        uint32 region = tokenRegion(tokenId);
        uint256 currentTier = fleetTier[tokenId];
        if (targetTier >= currentTier) revert TargetTierNotLower();
        if (_regionTierMembers[region][targetTier].length >= TIER_CAPACITY) revert TierFull();

        // Use snapshot for accurate refund based on what was paid
        uint256 currentBond = _tokenTierBond(tokenId, currentTier);
        uint256 targetBond = _tokenTierBond(tokenId, targetTier);
        uint256 refund = currentBond - targetBond;

        uuidTotalTierBonds[uuid] -= refund;
        _removeFromTier(tokenId, region, currentTier);
        fleetTier[tokenId] = targetTier;
        _addToTier(tokenId, region, targetTier);
        _trimTierCount(region);

        _refundBond(operator, refund);

        emit FleetDemoted(tokenId, currentTier, targetTier, refund);
    }

    function _validateExplicitTier(uint32 region, uint256 targetTier) internal view {
        if (targetTier >= MAX_TIERS) revert MaxTiersReached();
        if (_regionTierMembers[region][targetTier].length >= TIER_CAPACITY) revert TierFull();
    }

    function _buildHighestBondedUuidBundle(uint32 countryKey, uint32 adminKey)
        internal
        view
        returns (bytes16[] memory uuids, uint256 count, uint256 highestTier, uint256 lowestTier)
    {
        highestTier = _findMaxTierIndex(countryKey, adminKey);

        uuids = new bytes16[](MAX_BONDED_UUID_BUNDLE_SIZE);

        for (lowestTier = highestTier + 1; lowestTier > 0 && count < MAX_BONDED_UUID_BUNDLE_SIZE;) {
            unchecked {
                --lowestTier;
            }

            count = _appendTierUuids(adminKey, lowestTier, uuids, count);
            count = _appendTierUuids(countryKey, lowestTier, uuids, count);
        }

        assembly {
            mstore(uuids, count)
        }
    }

    function _appendTierUuids(uint32 regionKey, uint256 tier, bytes16[] memory uuids, uint256 count)
        internal
        view
        returns (uint256)
    {
        uint256[] storage members = _regionTierMembers[regionKey][tier];
        uint256 len = members.length;
        uint256 room = MAX_BONDED_UUID_BUNDLE_SIZE - count;
        uint256 toInclude = len < room ? len : room;

        for (uint256 i = 0; i < toInclude; ++i) {
            uuids[count] = tokenUuid(members[i]);
            unchecked {
                ++count;
            }
        }
        return count;
    }

    function _findMaxTierIndex(uint32 countryKey, uint32 adminKey) internal view returns (uint256 maxTierIndex) {
        uint256 adminTiers = regionTierCount[adminKey];
        uint256 countryTiers = regionTierCount[countryKey];

        uint256 maxTier = adminTiers > 0 ? adminTiers - 1 : 0;
        if (countryTiers > 0 && countryTiers - 1 > maxTier) maxTier = countryTiers - 1;
        return maxTier;
    }

    function _findCheapestInclusionTier(uint16 countryCode, uint16 adminCode, bool isCountry)
        internal
        view
        returns (uint256)
    {
        uint32 countryKey = uint32(countryCode);
        uint32 adminKey = makeAdminRegion(countryCode, adminCode);
        uint32 candidateRegion = isCountry ? countryKey : adminKey;

        (, uint256 count, uint256 highestTier, uint256 lowestTier) =
            _buildHighestBondedUuidBundle(countryKey, adminKey);

        for (uint256 tier = lowestTier; tier <= highestTier; ++tier) {
            bool tierHasCapacity = _regionTierMembers[candidateRegion][tier].length < TIER_CAPACITY;
            bool bundleHasRoom = count < MAX_BONDED_UUID_BUNDLE_SIZE;

            if (tierHasCapacity && bundleHasRoom) {
                return tier;
            }

            uint256 adminMembers = _regionTierMembers[adminKey][tier].length;
            uint256 countryMembers = _regionTierMembers[countryKey][tier].length;
            uint256 tierTotal = adminMembers + countryMembers;
            count = tierTotal > count ? 0 : count - tierTotal;
        }

        if (highestTier < MAX_TIERS - 1) {
            return highestTier + 1;
        }

        revert MaxTiersReached();
    }

    function _addToTier(uint256 tokenId, uint32 region, uint256 tier) internal {
        _regionTierMembers[region][tier].push(tokenId);
        _indexInTier[tokenId] = _regionTierMembers[region][tier].length - 1;

        if (tier >= regionTierCount[region]) {
            regionTierCount[region] = tier + 1;
        }
    }

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

    function _trimTierCount(uint32 region) internal {
        uint256 tierCount_ = regionTierCount[region];
        while (tierCount_ > 0 && _regionTierMembers[region][tierCount_ - 1].length == 0) {
            tierCount_--;
        }
        regionTierCount[region] = tierCount_;
    }

    function _addToRegionIndex(uint32 region) internal {
        if (_isCountryRegion(region)) {
            uint16 cc = uint16(region);
            if (_activeCountryIndex[cc] == 0) {
                _activeCountries.push(cc);
                _activeCountryIndex[cc] = _activeCountries.length;
            }
        } else {
            if (_countryAdminAreaIndex[region] == 0) {
                uint16 cc = _countryFromRegion(region);
                if (_activeCountryIndex[cc] == 0) {
                    _activeCountries.push(cc);
                    _activeCountryIndex[cc] = _activeCountries.length;
                }
                _countryAdminAreas[cc].push(region);
                _countryAdminAreaIndex[region] = _countryAdminAreas[cc].length;
            }
        }
    }

    function _removeFromRegionIndex(uint32 region) internal {
        if (regionTierCount[region] > 0) return;

        if (_isCountryRegion(region)) {
            uint16 cc = uint16(region);
            uint256 oneIdx = _activeCountryIndex[cc];
            if (oneIdx > 0) {
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

    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721EnumerableUpgradeable)
        returns (address)
    {
        address from = super._update(to, tokenId, auth);

        uint32 region = tokenRegion(tokenId);
        if (region == OWNED_REGION_KEY && from != address(0) && to != address(0)) {
            uuidOwner[tokenUuid(tokenId)] = to;
        }

        return from;
    }

    function _increaseBalance(address account, uint128 value) internal override(ERC721EnumerableUpgradeable) {
        super._increaseBalance(account, value);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721EnumerableUpgradeable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
