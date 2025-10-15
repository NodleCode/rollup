/**
 * Handle normalization and validation utilities
 */

// Valid characters for handles (alphanumeric and underscore)
const VALID_HANDLE_REGEX = /^[a-zA-Z0-9_]+$/

/**
 * Normalize a handle by removing @, trimming, and converting to lowercase
 */
export function normalizeHandle(handle: string): string {
    return handle.trim().replace(/^@/, '').toLowerCase()
}

/**
 * Validate handle format and character set
 */
export function validateHandle(handle: string): { isValid: boolean; error?: string } {
    if (!handle || typeof handle !== 'string') {
        return { isValid: false, error: 'Handle must be a non-empty string' }
    }

    const normalized = normalizeHandle(handle)

    if (normalized.length === 0) {
        return { isValid: false, error: 'Handle cannot be empty after normalization' }
    }

    if (normalized.length < 3) {
        return { isValid: false, error: 'Handle must be at least 3 characters long' }
    }

    if (normalized.length > 30) {
        return { isValid: false, error: 'Handle must be no more than 30 characters long' }
    }

    if (!VALID_HANDLE_REGEX.test(normalized)) {
        return { isValid: false, error: 'Handle can only contain letters, numbers, and underscores' }
    }

    // Additional restrictions
    if (normalized.startsWith('_') || normalized.endsWith('_')) {
        return { isValid: false, error: 'Handle cannot start or end with underscore' }
    }

    // Prevent consecutive underscores
    if (normalized.includes('__')) {
        return { isValid: false, error: 'Handle cannot contain consecutive underscores' }
    }

    return { isValid: true }
}

/**
 * Generate a Redis key for a handle reservation
 */
export function getHandleKey(handle: string): string {
    const normalized = normalizeHandle(handle)
    return `handle:${normalized}`
}

/**
 * Check if a handle is reserved (internal system handles)
 */
export function isReservedHandle(handle: string): boolean {
    const normalized = normalizeHandle(handle)
    const reserved = [
        'admin', 'root', 'api', 'www', 'mail', 'ftp', 'localhost',
        'support', 'help', 'info', 'contact', 'about', 'terms',
        'privacy', 'security', 'legal', 'billing', 'payments',
        'system', 'internal', 'test', 'staging', 'production',
        'null', 'undefined', 'true', 'false'
    ]

    return reserved.includes(normalized)
}
