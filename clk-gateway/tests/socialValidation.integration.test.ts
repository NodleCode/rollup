import { closeRedisConnection, getRedisClient } from '../src/utils/redis'
import { CLAIM_EXPIRY, REDIS_KEYS } from './testSetup'
import { TestSocialValidationService } from './TestSocialValidationService'

describe('SocialValidationService Integration Tests', () => {
    let redisClient: any
    let socialService: TestSocialValidationService

    beforeAll(async () => {
        // Set test environment variables
        process.env.REDIS_HOST = 'localhost'
        process.env.REDIS_PORT = '6379'
        process.env.REDIS_DB = '15' // Use a different DB for testing

        try {
            redisClient = await getRedisClient()
            socialService = new TestSocialValidationService()

            // Test Redis connection
            await redisClient.ping()
            console.log('✅ Redis connection established')
        } catch (error) {
            console.error('❌ Failed to connect to Redis:', error)
            throw error
        }
    })

    afterAll(async () => {
        if (redisClient) {
            await closeRedisConnection()
        }
        if (socialService) {
            await socialService.cleanup()
        }
    })

    beforeEach(async () => {
        // Clean up test data before each test
        const keys = await redisClient.keys('test_*')
        if (keys.length > 0) {
            await redisClient.del(keys)
        }
    })

    describe('isHandleClaimed', () => {
        it('should return false for unclaimed handle', async () => {
            const result = await socialService.isHandleClaimed('com.twitter', 'testuser')

            expect(result.claimed).toBe(false)
            expect(result.ensName).toBeUndefined()
        })

        it('should return true for claimed handle with ENS name', async () => {
            // Set up a claimed handle
            const claimKey = `${REDIS_KEYS.ACTIVE_CLAIM}com.twitter:testuser`
            await redisClient.set(claimKey, 'test.nodl')

            const result = await socialService.isHandleClaimed('com.twitter', 'testuser')

            expect(result.claimed).toBe(true)
            expect(result.ensName).toBe('test.nodl')
        })

        it('should be case-insensitive for handle lookup', async () => {
            const claimKey = `${REDIS_KEYS.ACTIVE_CLAIM}com.twitter:testuser`
            await redisClient.set(claimKey, 'test.nodl')

            const result = await socialService.isHandleClaimed('com.twitter', 'TestUser')

            expect(result.claimed).toBe(true)
            expect(result.ensName).toBe('test.nodl')
        })
    })

    describe('reserveHandle', () => {
        it('should successfully reserve an available handle', async () => {
            const result = await socialService.reserveHandle(
                'com.twitter',
                'testuser',
                'user123'
            )

            expect(result.success).toBe(true)
            expect(result.token).toBeDefined()
            expect(typeof result.token).toBe('string')

            // Verify the reservation is stored in Redis
            const pendingKey = `${REDIS_KEYS.PENDING_CLAIM}${result.token}`
            const storedClaim = await redisClient.get(pendingKey)

            expect(storedClaim).toBeTruthy()
            const claimData = JSON.parse(storedClaim)
            expect(claimData.platform).toBe('com.twitter')
            expect(claimData.handle).toBe('testuser')
            expect(claimData.userId).toBe('user123')
        })

        it('should fail to reserve an already claimed handle', async () => {
            // First, set up a claimed handle
            await socialService.reserveHandle('com.twitter', 'testuser', 'user123')
            const firstResult = await socialService.reserveHandle('com.twitter', 'testuser', 'user123')
            await socialService.confirmClaim(
                firstResult.token!,
                'test.nodl'
            )

            // Try to reserve the same handle
            const result = await socialService.reserveHandle(
                'com.twitter',
                'testuser',
                'user456'
            )

            expect(result.success).toBe(false)
            expect(result.token).toBeUndefined()
        })

        it('should allow multiple users to reserve different handles', async () => {
            const result1 = await socialService.reserveHandle(
                'com.twitter',
                'user1',
                'uid1'
            )

            const result2 = await socialService.reserveHandle(
                'com.twitter',
                'user2',
                'uid2'
            )

            expect(result1.success).toBe(true)
            expect(result2.success).toBe(true)
            expect(result1.token).not.toBe(result2.token)
        })

        it('should handle reservations with expiry', async () => {
            // Reserve a handle
            const result = await socialService.reserveHandle(
                'com.twitter',
                'tempuser',
                'user123'
            )

            // Verify TTL is set correctly
            const pendingKey = `${REDIS_KEYS.PENDING_CLAIM}${result.token}`
            const ttl = await redisClient.ttl(pendingKey)

            expect(ttl).toBeGreaterThan(0)
            expect(ttl).toBeLessThanOrEqual(CLAIM_EXPIRY.PENDING)
        })
    })

    describe('validateReservation', () => {
        it('should validate a valid reservation token', async () => {
            const reserveResult = await socialService.reserveHandle(
                'com.twitter',
                'testuser',
                'user123'
            )

            const isValid = await socialService.validateReservation(
                reserveResult.token!
            )

            expect(isValid.valid).toBe(true)
            expect(isValid.data).toBeDefined()
            expect(isValid.data.platform).toBe('com.twitter')
            expect(isValid.data.handle).toBe('testuser')
            expect(isValid.data.userId).toBe('user123')
        })

        it('should reject invalid reservation token', async () => {
            const isValid = await socialService.validateReservation(
                'invalid_token_123'
            )

            expect(isValid.valid).toBe(false)
            expect(isValid.data).toBeUndefined()
        })

        it('should reject expired reservation token', async () => {
            // Create a reservation
            const reserveResult = await socialService.reserveHandle(
                'com.twitter',
                'testuser',
                'user123'
            )

            // Manually expire the reservation
            const pendingKey = `${REDIS_KEYS.PENDING_CLAIM}${reserveResult.token}`
            await redisClient.del(pendingKey)

            const isValid = await socialService.validateReservation(
                reserveResult.token!
            )

            expect(isValid.valid).toBe(false)
        })

        it('should handle malformed token data gracefully', async () => {
            // Create a malformed pending claim
            const token = 'malformed_token_123'
            const pendingKey = `${REDIS_KEYS.PENDING_CLAIM}${token}`
            await redisClient.setEx(pendingKey, CLAIM_EXPIRY.PENDING, 'invalid_json{')

            const isValid = await socialService.validateReservation(token)

            expect(isValid.valid).toBe(false)
            expect(isValid.data).toBeUndefined()
        })
    })

    describe('confirmClaim', () => {
        it('should successfully confirm a valid reservation', async () => {
            // First reserve a handle
            const reserveResult = await socialService.reserveHandle(
                'com.twitter',
                'testuser',
                'user123'
            )

            // Confirm the claim
            const confirmed = await socialService.confirmClaim(
                reserveResult.token!,
                'test.nodl'
            )

            expect(confirmed).toBe(true)

            // Verify the claim is now active
            const claimResult = await socialService.isHandleClaimed('com.twitter', 'testuser')
            expect(claimResult.claimed).toBe(true)
            expect(claimResult.ensName).toBe('test.nodl:PENDING')

            // Verify pending claim is removed
            const pendingKey = `${REDIS_KEYS.PENDING_CLAIM}${reserveResult.token}`
            const pendingExists = await redisClient.exists(pendingKey)
            expect(pendingExists).toBe(0)
        })

        it('should fail to confirm with invalid token', async () => {
            const confirmed = await socialService.confirmClaim(
                'invalid_token',
                'test.nodl'
            )

            expect(confirmed).toBe(false)
        })

        it('should fail to confirm if handle was claimed by another user', async () => {
            // Reserve handle for first user
            const reserveResult = await socialService.reserveHandle(
                'com.twitter',
                'testuser',
                'user123'
            )

            // Manually set the handle as claimed by someone else
            const claimKey = `${REDIS_KEYS.ACTIVE_CLAIM}com.twitter:testuser`
            await redisClient.set(claimKey, 'other.nodl')

            // Try to confirm original reservation
            const confirmed = await socialService.confirmClaim(
                reserveResult.token!,
                'test.nodl'
            )

            expect(confirmed).toBe(false)

            // Verify pending claim is cleaned up
            const pendingKey = `${REDIS_KEYS.PENDING_CLAIM}${reserveResult.token}`
            const pendingExists = await redisClient.exists(pendingKey)
            expect(pendingExists).toBe(0)
        })

        it('should add claim to user claims list', async () => {
            const reserveResult = await socialService.reserveHandle(
                'com.twitter',
                'testuser',
                'user123'
            )

            await socialService.confirmClaim(reserveResult.token!, 'test.nodl')

            // Check user claims
            const userClaims = await socialService.getUserClaims('user123')
            expect(userClaims).toHaveLength(1)
            expect(userClaims[0].platform).toBe('com.twitter')
            expect(userClaims[0].handle).toBe('testuser')
            expect(userClaims[0].ensName).toBe('test.nodl')
            expect(userClaims[0].status).toBe('PENDING')
        })
    })

    describe('markOnChain', () => {
        it('should successfully mark claim as on-chain', async () => {
            // Set up a confirmed but pending claim
            const claimKey = `${REDIS_KEYS.ACTIVE_CLAIM}com.twitter:testuser`
            await redisClient.setEx(claimKey, CLAIM_EXPIRY.RESERVATION, 'test.nodl:PENDING')

            const result = await socialService.markOnChain(
                'com.twitter',
                'testuser',
                'test.nodl'
            )

            expect(result).toBe(true)

            // Verify claim is now permanent (no expiry)
            const ttl = await redisClient.ttl(claimKey)
            expect(ttl).toBe(-1) // -1 means no expiry

            const claimValue = await redisClient.get(claimKey)
            expect(claimValue).toBe('test.nodl')
        })

        it('should fail for non-existent claim', async () => {
            const result = await socialService.markOnChain(
                'com.twitter',
                'nonexistent',
                'test.nodl'
            )

            expect(result).toBe(false)
        })

        it('should fail for mismatched ENS name', async () => {
            const claimKey = `${REDIS_KEYS.ACTIVE_CLAIM}com.twitter:testuser`
            await redisClient.setEx(claimKey, CLAIM_EXPIRY.RESERVATION, 'other.nodl:PENDING')

            const result = await socialService.markOnChain(
                'com.twitter',
                'testuser',
                'test.nodl'  // Different ENS name
            )

            expect(result).toBe(false)
        })
    })

    describe('getUserClaims', () => {
        it('should return empty array for user with no claims', async () => {
            const claims = await socialService.getUserClaims('user123')
            expect(claims).toEqual([])
        })

        it('should return user claims correctly', async () => {
            // Set up multiple claims for a user
            const userKey = `${REDIS_KEYS.USER_CLAIMS}user123`
            const claim1 = JSON.stringify({
                platform: 'com.twitter',
                handle: 'user1',
                ensName: 'test1.nodl',
                status: 'ACTIVE',
                timestamp: Date.now()
            })
            const claim2 = JSON.stringify({
                platform: 'com.instagram',
                handle: 'user1',
                ensName: 'test1.nodl',
                status: 'PENDING',
                timestamp: Date.now()
            })

            await redisClient.sAdd(userKey, claim1)
            await redisClient.sAdd(userKey, claim2)

            const claims = await socialService.getUserClaims('user123')

            expect(claims).toHaveLength(2)
            expect(claims.some(c => c.platform === 'com.twitter')).toBe(true)
            expect(claims.some(c => c.platform === 'com.instagram')).toBe(true)
        })
    })

    describe('Full Workflow Integration', () => {
        it('should complete full claim workflow successfully', async () => {
            const userId = 'user123'
            const platform = 'com.twitter'
            const handle = 'testuser'
            const ensName = 'test.nodl'

            // Step 1: Check availability
            let availability = await socialService.isHandleClaimed(platform, handle)
            expect(availability.claimed).toBe(false)

            // Step 2: Reserve handle
            const reservation = await socialService.reserveHandle(platform, handle, userId)
            expect(reservation.success).toBe(true)
            expect(reservation.token).toBeDefined()

            // Step 3: Validate reservation
            const validation = await socialService.validateReservation(reservation.token!)
            expect(validation.valid).toBe(true)

            // Step 4: Confirm claim
            const confirmation = await socialService.confirmClaim(reservation.token!, ensName)
            expect(confirmation).toBe(true)

            // Step 5: Verify claim exists with PENDING status
            availability = await socialService.isHandleClaimed(platform, handle)
            expect(availability.claimed).toBe(true)
            expect(availability.ensName).toBe(`${ensName}:PENDING`)

            // Step 6: Mark as on-chain
            const onChain = await socialService.markOnChain(platform, handle, ensName)
            expect(onChain).toBe(true)

            // Step 7: Verify final state
            availability = await socialService.isHandleClaimed(platform, handle)
            expect(availability.claimed).toBe(true)
            expect(availability.ensName).toBe(ensName)

            // Step 8: Check user claims
            const userClaims = await socialService.getUserClaims(userId)
            expect(userClaims).toHaveLength(1)
            expect(userClaims[0].ensName).toBe(ensName)
            expect(userClaims[0].status).toBe('PENDING')
        })

        it('should handle race condition during claim confirmation', async () => {
            const platform = 'com.twitter'
            const handle = 'racecondition'

            // Two users try to reserve the same handle
            const reservation1 = await socialService.reserveHandle(platform, handle, 'user1')
            const reservation2 = await socialService.reserveHandle(platform, handle, 'user2')

            // First reservation should succeed
            expect(reservation1.success).toBe(true)

            // Confirm first claim
            const confirm1 = await socialService.confirmClaim(reservation1.token!, 'user1.nodl')
            expect(confirm1).toBe(true)

            // Second confirmation should fail (handle already claimed)
            const confirm2 = await socialService.confirmClaim(reservation2.token!, 'user2.nodl')
            expect(confirm2).toBe(false)

            // Verify only first claim exists
            const claimResult = await socialService.isHandleClaimed(platform, handle)
            expect(claimResult.claimed).toBe(true)
            expect(claimResult.ensName).toBe('user1.nodl:PENDING')
        })
    })
})
