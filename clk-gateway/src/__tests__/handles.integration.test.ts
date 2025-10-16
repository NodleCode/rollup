// Mock Firebase before any imports that might use it
jest.mock('firebase-admin/app', () => ({
    initializeApp: jest.fn()
}))

jest.mock('firebase-admin', () => ({
    initializeApp: jest.fn(),
    credential: {
        cert: jest.fn()
    },
    auth: jest.fn(() => ({
        verifyIdToken: jest.fn(),
        getUserByEmail: jest.fn()
    }))
}))

// Mock the entire setup module to prevent automatic Redis connection
jest.mock('../setup', () => {
    const { createClient } = jest.requireActual('redis')
    const testRedisUrl = process.env.REDIS_URL || "redis://localhost:6380"
    const testRedisClient = createClient({
        url: testRedisUrl,
    })

    // Mock the client without auto-connection
    testRedisClient.on = jest.fn()

    return {
        redisClient: testRedisClient,
        handleReserveTtl: 300,
        handleConfirmTtl: 900,
        rateLimitPerMin: 60,
        // Mock other exports to prevent errors
        l2Provider: {},
        l2Wallet: {},
        l1Provider: {},
        diamondAddress: '0x0000000000000000000000000000000000000000',
        diamondContract: {},
        nameServiceAddresses: { clk: '0x0', nodl: '0x0' },
        port: 8080,
    }
})

import express from 'express'
import request from 'supertest'
import handlesRouter from '../routes/handles'
import { redisClient } from '../setup'
import { HttpError } from '../types'
import { createTestValidateRequest, testWallet } from '../utils/testSignatures'

describe('Handle Guard API - Integration Tests', () => {
    let app: express.Application
    const testHandle = 'integrationtest'

    beforeAll(async () => {
        // Connect to mocked Redis client
        if (!redisClient.isOpen) {
            await redisClient.connect()
        }

        app = express()
        app.use(express.json())
        app.use('/handles', handlesRouter)

        // Add error handling middleware (same as in main app)
        app.use((err: Error, req: express.Request, res: express.Response, next: express.NextFunction): void => {
            if (err instanceof HttpError) {
                res.status(err.statusCode).json({ error: err.message })
                return
            }

            const message = err instanceof Error ? err.message : String(err)
            res.status(500).json({ error: message })
        })
    }, 30000)

    afterAll(async () => {
        // Simple cleanup and disconnect
        try {
            if (redisClient.isOpen) {
                const keys = await redisClient.keys(`handle:${testHandle}*`)
                for (const key of keys) {
                    await redisClient.del(key)
                }
                await redisClient.disconnect()
            }
        } catch (error) {
            console.warn('Cleanup error:', error)
        }
    }, 30000)

    beforeEach(async () => {
        // Clean up any existing test data in Redis
        try {
            if (redisClient.isOpen) {
                const keys = await redisClient.keys(`handle:${testHandle}*`)
                for (const key of keys) {
                    await redisClient.del(key)
                }
            }
        } catch (error) {
            console.warn('beforeEach cleanup error:', error)
        }
    }, 10000)

    afterEach(async () => {
        // Clean up test data after each test
        try {
            if (redisClient.isOpen) {
                const keys = await redisClient.keys(`handle:${testHandle}*`)
                for (const key of keys) {
                    await redisClient.del(key)
                }
            }
        } catch (error) {
            console.warn('afterEach cleanup error:', error)
        }
    }, 10000)

    describe('POST /handles/validate - Redis Integration', () => {
        it.only('should successfully reserve an available handle with real Redis and indexer', async () => {
            const requestData = await createTestValidateRequest(testHandle)

            // Note: This will make a real API call to the indexer service
            const response = await request(app)
                .post('/handles/validate')
                .send(requestData)

            // The response could be 200 (reserved) or 409 (already taken) depending on indexer state
            if (response.status === 200) {
                expect(response.body).toEqual({
                    status: 'reserved',
                    expiresInSec: 300,
                    idempotencyKey: requestData.idempotencyKey,
                })

                // Verify that the handle was actually stored in Redis
                const redisKey = `handle:${testHandle}`
                const storedData = await redisClient.get(redisKey)
                expect(storedData).toBeTruthy()

                const parsedData = JSON.parse(storedData!)
                expect(parsedData).toMatchObject({
                    owner: testWallet.address,
                    ensName: 'test.eth',
                    idempotencyKey: requestData.idempotencyKey,
                    state: 'reserved',
                })

                
                // Verify TTL was set
                const ttl = await redisClient.ttl(redisKey)
                expect(ttl).toBeGreaterThan(0)
                expect(ttl).toBeLessThanOrEqual(300)
            } else if (response.status === 409) {
                expect(response.body).toEqual({
                    error: 'Handle is already taken',
                    status: 'taken',
                })
            } else {
                throw new Error(`Unexpected response status: ${response.status}`)
            }
        }, 30000) // 30 second timeout for integration test
    })
})
