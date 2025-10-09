import { RedisClientType } from 'redis'
import { getRedisClient } from '../src/utils/redis'
import { CLAIM_EXPIRY, REDIS_KEYS } from './testSetup'

/**
 * Test-specific SocialValidationService
 * Uses test Redis keys and avoids Firebase dependencies
 */
export class TestSocialValidationService {
    private redisClient: RedisClientType | null = null;

    private async getClient(): Promise<RedisClientType> {
        if (!this.redisClient) {
            this.redisClient = await getRedisClient()
        }
        return this.redisClient
    }

    async isHandleClaimed(platform: string, handle: string): Promise<{ claimed: boolean; ensName?: string }> {
        const redis = await this.getClient()
        const claimKey = `${REDIS_KEYS.ACTIVE_CLAIM}${platform}:${handle.toLowerCase()}`
        const ensName = await redis.get(claimKey)

        return {
            claimed: ensName !== null,
            ensName: ensName || undefined
        }
    }

    async reserveHandle(platform: string, handle: string, userId: string): Promise<{ success: boolean; token?: string }> {
        const redis = await this.getClient()

        // Check if handle is already claimed
        const { claimed } = await this.isHandleClaimed(platform, handle)
        if (claimed) {
            return { success: false }
        }

        // Generate reservation token
        const token = `${userId}_${platform}_${handle}_${Date.now()}`
        const pendingKey = `${REDIS_KEYS.PENDING_CLAIM}${token}`

        // Store pending claim (normalize handle to lowercase)
        const claimData = JSON.stringify({ platform, handle: handle.toLowerCase(), userId, timestamp: Date.now() })
        await redis.setEx(pendingKey, CLAIM_EXPIRY.PENDING, claimData)

        return { success: true, token }
    }

    async validateReservation(token: string): Promise<{ valid: boolean; data?: any }> {
        const redis = await this.getClient()
        const pendingKey = `${REDIS_KEYS.PENDING_CLAIM}${token}`

        const claimData = await redis.get(pendingKey)
        if (!claimData) {
            return { valid: false }
        }

        try {
            const data = JSON.parse(claimData)
            return { valid: true, data }
        } catch (error) {
            return { valid: false }
        }
    }

    async confirmClaim(token: string, ensName: string): Promise<boolean> {
        const redis = await this.getClient()
        const pendingKey = `${REDIS_KEYS.PENDING_CLAIM}${token}`

        // Get and validate pending claim
        const { valid, data } = await this.validateReservation(token)
        if (!valid || !data) {
            return false
        }

        const { platform, handle, userId } = data

        // Check if handle is still available
        const { claimed } = await this.isHandleClaimed(platform, handle)
        if (claimed) {
            // Clean up pending claim
            await redis.del(pendingKey)
            return false
        }

        // Create confirmed claim (with temporary reservation)
        const claimKey = `${REDIS_KEYS.ACTIVE_CLAIM}${platform}:${handle.toLowerCase()}`
        await redis.setEx(claimKey, CLAIM_EXPIRY.RESERVATION, `${ensName}:PENDING`)

        // Add to user's claims list
        const userKey = `${REDIS_KEYS.USER_CLAIMS}${userId}`
        const userClaim = JSON.stringify({ platform, handle, ensName, status: 'PENDING', timestamp: Date.now() })
        await redis.sAdd(userKey, userClaim)

        // Clean up pending claim
        await redis.del(pendingKey)

        return true
    }

    async markOnChain(platform: string, handle: string, ensName: string): Promise<boolean> {
        const redis = await this.getClient()
        const claimKey = `${REDIS_KEYS.ACTIVE_CLAIM}${platform}:${handle.toLowerCase()}`

        const currentClaim = await redis.get(claimKey)
        if (!currentClaim || !currentClaim.startsWith(`${ensName}:`)) {
            return false
        }

        // Make claim permanent (remove expiration)
        await redis.set(claimKey, ensName)

        return true
    }

    async getUserClaims(userId: string): Promise<Array<{ platform: string; handle: string; ensName: string; status: string; timestamp: number }>> {
        const redis = await this.getClient()
        const userKey = `${REDIS_KEYS.USER_CLAIMS}${userId}`

        const claims = await redis.sMembers(userKey)
        return claims.map((claim: string) => JSON.parse(claim))
    }

    async cleanup(): Promise<void> {
        if (this.redisClient && this.redisClient.isOpen) {
            await this.redisClient.quit()
            this.redisClient = null
        }
    }
}
