import { CLAIM_EXPIRY, REDIS_KEYS } from "../setup";
import { getRedisClient } from "../utils/redis";

export interface SocialClaim {
  ensName: string;
  socialPlatform: "com.twitter";
  socialHandle: string;
  owner: string;
  timestamp: number;
  verificationCode: string;
  status: "pending" | "verified" | "on_chain";
}

export class SocialValidationService {
  // Generate unique verification code
  static generateVerificationCode(): string {
    return Math.random().toString(36).substring(2, 15);
  }

  // Check if social handle is already claimed
  static async isHandleClaimed(
    platform: string,
    handle: string,
  ): Promise<{
    claimed: boolean;
    ensName?: string;
    status?: string;
  }> {
    const redisClient = await getRedisClient();
    const claimKey = `${REDIS_KEYS.ACTIVE_CLAIM}${platform}:${handle.toLowerCase()}`;
    const existingClaim = await redisClient.get(claimKey);

    if (existingClaim) {
      const claim: SocialClaim = JSON.parse(existingClaim);
      return {
        claimed: true,
        ensName: claim.ensName,
        status: claim.status,
      };
    }

    return { claimed: false };
  }

  // Reserve social handle temporarily
  static async reserveHandle(
    ensName: string,
    platform: string,
    handle: string,
    owner: string,
  ): Promise<{ verificationCode: string; expiresAt: number }> {
    // Check if handle is already claimed
    const existingClaim = await this.isHandleClaimed(platform, handle);
    if (existingClaim.claimed) {
      throw new Error(
        `Handle ${handle} is already claimed by ${existingClaim.ensName}`,
      );
    }

    const verificationCode = this.generateVerificationCode();
    const timestamp = Date.now();
    const expiresAt = timestamp + CLAIM_EXPIRY.PENDING * 1000;

    const claim: SocialClaim = {
      ensName,
      socialPlatform: platform as "com.twitter",
      socialHandle: handle.toLowerCase(),
      owner,
      timestamp,
      verificationCode,
      status: "pending",
    };

    const redisClient = await getRedisClient();
    const pendingKey = `${REDIS_KEYS.PENDING_CLAIM}${platform}:${handle.toLowerCase()}`;

    // Set with expiration
    await redisClient.setEx(
      pendingKey,
      CLAIM_EXPIRY.PENDING,
      JSON.stringify(claim),
    );

    return { verificationCode, expiresAt };
  }

  // Verify that user has a valid reservation for this handle
  static async validateReservation(
    platform: string,
    handle: string,
    ensName: string,
    owner: string,
  ): Promise<boolean> {
    const redisClient = await getRedisClient();
    const pendingKey = `${REDIS_KEYS.PENDING_CLAIM}${platform}:${handle.toLowerCase()}`;
    const pendingClaim = await redisClient.get(pendingKey);

    if (!pendingClaim) {
      return false;
    }

    const claim: SocialClaim = JSON.parse(pendingClaim);

    // Verify the claim matches the request
    return (
      claim.ensName === ensName &&
      claim.owner.toLowerCase() === owner.toLowerCase() &&
      claim.socialHandle === handle.toLowerCase()
    );
  }

  // Confirm claim and move to active status
  static async confirmClaim(
    platform: string,
    handle: string,
    ensName: string,
    owner: string,
  ): Promise<boolean> {
    const redisClient = await getRedisClient();
    const pendingKey = `${REDIS_KEYS.PENDING_CLAIM}${platform}:${handle.toLowerCase()}`;
    const activeKey = `${REDIS_KEYS.ACTIVE_CLAIM}${platform}:${handle.toLowerCase()}`;

    const pendingClaim = await redisClient.get(pendingKey);
    if (!pendingClaim) {
      return false;
    }

    const claim: SocialClaim = JSON.parse(pendingClaim);

    // Verify the claim matches
    if (
      claim.ensName !== ensName ||
      claim.owner.toLowerCase() !== owner.toLowerCase()
    ) {
      return false;
    }

    claim.status = "verified";

    // Move from pending to active with longer expiration
    await redisClient.setEx(
      activeKey,
      CLAIM_EXPIRY.RESERVATION,
      JSON.stringify(claim),
    );
    await redisClient.del(pendingKey);

    return true;
  }

  // Mark claim as on-chain after transaction confirmation
  static async markOnChain(
    platform: string,
    handle: string,
    txHash: string,
  ): Promise<void> {
    const redisClient = await getRedisClient();
    const activeKey = `${REDIS_KEYS.ACTIVE_CLAIM}${platform}:${handle.toLowerCase()}`;
    const claim = await redisClient.get(activeKey);

    if (claim) {
      const claimData: SocialClaim = JSON.parse(claim);
      claimData.status = "on_chain";

      // Keep indefinitely once on-chain (remove expiration)
      await redisClient.set(activeKey, JSON.stringify(claimData));
    }
  }

  // Clean up expired claims - can be called periodically
  static async cleanupExpiredClaims(): Promise<void> {
    const redisClient = await getRedisClient();
    const pattern = `${REDIS_KEYS.PENDING_CLAIM}*`;
    const keys = await redisClient.keys(pattern);

    for (const key of keys) {
      const ttl = await redisClient.ttl(key);
      if (ttl === -1) {
        // Key exists but no expiration
        await redisClient.del(key);
      }
    }
  }

  // Get claim information for a handle
  static async getClaimInfo(
    platform: string,
    handle: string,
  ): Promise<SocialClaim | null> {
    const redisClient = await getRedisClient();
    const activeKey = `${REDIS_KEYS.ACTIVE_CLAIM}${platform}:${handle.toLowerCase()}`;
    const pendingKey = `${REDIS_KEYS.PENDING_CLAIM}${platform}:${handle.toLowerCase()}`;

    // Check active claims first
    let claim = await redisClient.get(activeKey);
    if (claim) {
      return JSON.parse(claim);
    }

    // Check pending claims
    claim = await redisClient.get(pendingKey);
    if (claim) {
      return JSON.parse(claim);
    }

    return null;
  }
}
