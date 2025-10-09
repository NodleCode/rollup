// Test-specific setup that avoids Firebase initialization
import dotenv from 'dotenv'

// Load test environment first
dotenv.config({ path: '.env.test' })

// Redis key patterns for social claims
export const REDIS_KEYS = {
    PENDING_CLAIM: 'test_pending_claim:',
    ACTIVE_CLAIM: 'test_active_claim:',
    USER_CLAIMS: 'test_user_claims:',
}

// Claim expiration times (in seconds)
export const CLAIM_EXPIRY = {
    PENDING: 300, // 5 minutes for pending verification
    RESERVATION: 3600, // 1 hour for confirmed but not yet on-chain
}
