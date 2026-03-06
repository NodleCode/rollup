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

/// @notice Tag type classification for BLE beacons.
enum TagType {
    IBEACON_PAYLOAD_ONLY, // 0x00: proxUUID || major || minor
    IBEACON_INCLUDES_MAC, // 0x01: proxUUID || major || minor || MAC (Normalized)
    VENDOR_ID, // 0x02: companyID || hash(vendorBytes)
    GENERIC // 0x03: generic tag type
}

/// @notice Fingerprint size for XOR filter (8-bit or 16-bit only for gas efficiency).
enum FingerprintSize {
    BITS_8, // 8-bit fingerprints (1 byte each)
    BITS_16 // 16-bit fingerprints (2 bytes each)
}
