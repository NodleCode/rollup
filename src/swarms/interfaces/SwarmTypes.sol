// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity ^0.8.24;

/**
 * @title SwarmTypes
 * @notice Shared type definitions for the Swarm system contracts.
 * @dev Solidity interfaces cannot define enums, so shared enums live here.
 *      Import this file alongside interfaces when type definitions are needed.
 */

// ══════════════════════════════════════════════
// FleetIdentity Types
// ══════════════════════════════════════════════

/// @notice Registration level for a UUID in FleetIdentity.
enum RegistrationLevel {
    None, // 0 - not registered (default)
    Owned, // 1 - owned but not registered in any region
    Local, // 2 - admin area (local) level
    Country // 3 - country level
}

// ══════════════════════════════════════════════
// SwarmRegistry Types
// ══════════════════════════════════════════════

/// @notice Status of a swarm registration.
enum SwarmStatus {
    REGISTERED, // 0 - registered but awaiting provider approval
    ACCEPTED, // 1 - approved by the service provider
    REJECTED // 2 - rejected by the service provider
}

/// @notice Tag type classification for BLE advertisement formats.
/// @dev The UUID field (bytes16) encodes the fleet-level identifier derived from the BLE advertisement.
///      It contains only the fields necessary for edge scanners to register OS-level background scan
///      filters and to scope on-chain swarm lookups. Tag-specific fields (e.g. iBeacon Major/Minor)
///      are excluded from the UUID and used only in tag hash construction for XOR filter membership.
///
///      UUID design trade-offs:
///      - Specificity: A more populated UUID → fewer swarms per UUID → faster service resolution.
///      - Uniqueness: Short/generic UUIDs increase collision risk when claiming fleet ownership.
///      - Privacy: Fewer exposed bytes = more privacy, at the cost of specificity and uniqueness.
///      - Background scanning: UUID must contain enough data for OS-level BLE scan filters.
///
///      Encoding per TagType:
///      - IBEACON_*:     Proximity UUID (16B). AltBeacon uses this same format.
///      - VENDOR_ID:     [Len (1B)] [CompanyID (2B, BE)] [FleetID (≤13B, zero-padded)].
///                       Len = 2 + FleetIdLen (range 2–15).
///      - EDDYSTONE_UID: Namespace (10B) || Instance (6B).
///      - SERVICE_DATA:  128-bit Bluetooth Base UUID expansion of the Service UUID.
///                       16-bit:  0000XXXX-0000-1000-8000-00805F9B34FB
///                       32-bit:  XXXXXXXX-0000-1000-8000-00805F9B34FB
///                       128-bit: stored as-is.
enum TagType {
    IBEACON_PAYLOAD_ONLY, // 0x00: proxUUID || major || minor (also covers AltBeacon)
    IBEACON_INCLUDES_MAC, // 0x01: proxUUID || major || minor || MAC (Normalized)
    VENDOR_ID, // 0x02: len-prefixed companyID || fleetIdentifier
    EDDYSTONE_UID, // 0x03: namespace (10B) || instance (6B)
    SERVICE_DATA // 0x04: expanded 128-bit BLE Service UUID
}

/// @notice Fingerprint size for XOR filter (8-bit or 16-bit only for gas efficiency).
enum FingerprintSize {
    BITS_8, // 8-bit fingerprints (1 byte each)
    BITS_16 // 16-bit fingerprints (2 bytes each)
}
