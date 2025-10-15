import { randomUUID } from "crypto"
import { handleConfirmTtl, handleReserveTtl, redisClient } from "../setup"
import { getHandleKey, isReservedHandle, normalizeHandle, validateHandle } from "../utils/handle"
import { indexerService } from "./indexer"

export type HandleState = 'available' | 'reserved' | 'pending_onchain' | 'taken'

export interface HandleReservation {
    owner: string
    ensName: string
    idempotencyKey: string
    txHash?: string
    state: 'reserved' | 'pending_onchain'
    createdAt: number
}

export interface HandleStatusResponse {
    status: HandleState
    expiresInSec?: number
    by?: {
        ensName: string
        owner: string
    }
    reservation?: Omit<HandleReservation, 'owner'>
}

export interface ValidateHandleRequest {
    handle: string
    ensName: string
    owner: string
    ttlSec?: number
    idempotencyKey?: string
}

export interface ValidateHandleResponse {
    status: 'reserved'
    expiresInSec: number
    idempotencyKey: string
}

export interface ConfirmHandleRequest {
    handle: string
    txHash: string
    owner: string
    extendTtlSec?: number
}

export interface ConfirmHandleResponse {
    status: 'pending_onchain'
    expiresInSec: number
}

export interface ReleaseHandleRequest {
    handle: string
    owner: string
}

export interface ReleaseHandleResponse {
    status: 'released'
}

export class HandleGuardService {

    /**
     * Validate and reserve a handle
     */
    async validateHandle(request: ValidateHandleRequest): Promise<ValidateHandleResponse> {
        const { handle, ensName, owner, ttlSec = handleReserveTtl, idempotencyKey } = request

        // Normalize and validate handle
        const normalizedHandle = normalizeHandle(handle)
        const validation = validateHandle(normalizedHandle)

        if (!validation.isValid) {
            throw new Error(`Invalid handle: ${validation.error}`)
        }

        if (isReservedHandle(normalizedHandle)) {
            throw new Error('Handle is reserved by the system')
        }

        // Check if handle is already taken in indexer
        const ownership = await indexerService.isHandleTaken(normalizedHandle)
        if (ownership) {
            const error = new Error('Handle is already taken');
            (error as any).status = 'taken';
            (error as any).statusCode = 409
            throw error
        }

        const key = getHandleKey(normalizedHandle)
        const finalIdempotencyKey = idempotencyKey || randomUUID()

        const reservation: HandleReservation = {
            owner,
            ensName,
            idempotencyKey: finalIdempotencyKey,
            state: 'reserved',
            createdAt: Math.floor(Date.now() / 1000)
        }

        // Try to set the reservation with NX (only if key doesn't exist)
        const setResult = await redisClient.setNX(key, JSON.stringify(reservation))

        if (setResult) {
            // Successfully reserved, set TTL
            await redisClient.expire(key, ttlSec)
            return {
                status: 'reserved',
                expiresInSec: ttlSec,
                idempotencyKey: finalIdempotencyKey
            }
        } else {
            // Key already exists, check if it's the same owner/idempotency key
            const existingData = await redisClient.get(key)
            if (!existingData) {
                // Race condition: key was deleted between setNx and get
                throw new Error('Reservation conflict, please try again')
            }

            const existingReservation: HandleReservation = JSON.parse(existingData)
            const ttl = await redisClient.ttl(key)

            if (existingReservation.owner === owner &&
                existingReservation.idempotencyKey === finalIdempotencyKey) {
                // Same owner and idempotency key, return existing reservation
                return {
                    status: 'reserved',
                    expiresInSec: Math.max(0, ttl),
                    idempotencyKey: finalIdempotencyKey
                }
            } else {
                // Different owner, return conflict
                const error = new Error('Handle is already reserved');
                (error as any).status = 'reserved';
                (error as any).statusCode = 409;
                (error as any).expiresInSec = Math.max(0, ttl)
                throw error
            }
        }
    }

    /**
     * Confirm a handle reservation with transaction hash
     */
    async confirmHandle(request: ConfirmHandleRequest): Promise<ConfirmHandleResponse> {
        const { handle, txHash, owner, extendTtlSec = handleConfirmTtl } = request

        const normalizedHandle = normalizeHandle(handle)
        const key = getHandleKey(normalizedHandle)

        const existingData = await redisClient.get(key)
        if (!existingData) {
            const error = new Error('Reservation not found');
            (error as any).statusCode = 404
            throw error
        }

        const reservation: HandleReservation = JSON.parse(existingData)

        if (reservation.owner !== owner) {
            const error = new Error('Not the owner of this reservation');
            (error as any).statusCode = 409
            throw error
        }

        // Update reservation with txHash and new state
        const updatedReservation: HandleReservation = {
            ...reservation,
            txHash,
            state: 'pending_onchain'
        }

        await redisClient.set(key, JSON.stringify(updatedReservation))
        await redisClient.expire(key, extendTtlSec)

        return {
            status: 'pending_onchain',
            expiresInSec: extendTtlSec
        }
    }

    /**
     * Release a handle reservation
     */
    async releaseHandle(request: ReleaseHandleRequest): Promise<ReleaseHandleResponse> {
        const { handle, owner } = request

        const normalizedHandle = normalizeHandle(handle)
        const key = getHandleKey(normalizedHandle)

        const existingData = await redisClient.get(key)
        if (existingData) {
            const reservation: HandleReservation = JSON.parse(existingData)

            if (reservation.owner !== owner) {
                const error = new Error('Not the owner of this reservation');
                (error as any).statusCode = 409
                throw error
            }

            await redisClient.del(key)
        }

        return { status: 'released' }
    }

    /**
     * Get the status of a handle
     */
    async getHandleStatus(handle: string): Promise<HandleStatusResponse> {
        const normalizedHandle = normalizeHandle(handle)

        // First check if handle is taken in indexer
        const ownership = await indexerService.isHandleTaken(normalizedHandle)
        if (ownership) {
            return {
                status: 'taken',
                by: {
                    ensName: ownership.ensName,
                    owner: ownership.owner
                }
            }
        }

        // Check if handle is reserved in Redis
        const key = getHandleKey(normalizedHandle)
        const existingData = await redisClient.get(key)

        if (existingData) {
            const reservation: HandleReservation = JSON.parse(existingData)
            const ttl = await redisClient.ttl(key)

            return {
                status: reservation.state,
                expiresInSec: Math.max(0, ttl),
                reservation: {
                    ensName: reservation.ensName,
                    idempotencyKey: reservation.idempotencyKey,
                    txHash: reservation.txHash,
                    state: reservation.state,
                    createdAt: reservation.createdAt
                }
            }
        }

        return { status: 'available' }
    }

    /**
     * Get all pending reservations for reconciliation
     */
    async getPendingReservations(): Promise<Array<{ key: string; reservation: HandleReservation }>> {
        const pattern = 'handle:*'
        const keys = await redisClient.keys(pattern)
        const results: Array<{ key: string; reservation: HandleReservation }> = []

        for (const key of keys) {
            const data = await redisClient.get(key)
            if (data) {
                const reservation: HandleReservation = JSON.parse(data)
                if (reservation.state === 'pending_onchain' && reservation.txHash) {
                    results.push({ key, reservation })
                }
            }
        }

        return results
    }

    /**
     * Remove a reservation (for reconciliation)
     */
    async removeReservation(key: string): Promise<void> {
        await redisClient.del(key)
    }

    /**
     * Update reservation TTL (for reconciliation)
     */
    async updateReservationTtl(key: string, ttlSec: number): Promise<void> {
        await redisClient.expire(key, ttlSec)
    }
}

export const handleGuardService = new HandleGuardService()
