import { randomUUID } from 'crypto'
import express from 'express'
import request from 'supertest'
import handlesRouter from '../routes/handles'
import { indexerService } from '../services/indexer'
import { redisClient } from '../setup'
import { HttpError } from '../types'
import {
    createTestConfirmRequest,
    createTestValidateRequest,
    testWallet,
    testWallet2
} from '../utils/testSignatures'

// Mock the services
jest.mock('../services/indexer')
jest.mock('../setup', () => ({
    redisClient: {
        setNX: jest.fn(),
        expire: jest.fn(),
        get: jest.fn(),
        ttl: jest.fn(),
        del: jest.fn(),
        keys: jest.fn(),
        set: jest.fn(),
    },
    handleReserveTtl: 300,
    handleConfirmTtl: 900,
    rateLimitPerMin: 60,
}))

const mockedIndexerService = indexerService as jest.Mocked<typeof indexerService>
const mockedRedisClient = redisClient as jest.Mocked<typeof redisClient>

describe('Handle Guard API', () => {
    let app: express.Application

    beforeAll(() => {
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
    })

    beforeEach(() => {
        jest.clearAllMocks()
    })

    afterAll(async () => {
        // Clean up any resources
    })

    describe('POST /handles/validate', () => {
        it('should successfully reserve an available handle', async () => {
            const requestData = await createTestValidateRequest()

            // Mock indexer to return handle not taken
            mockedIndexerService.isHandleTaken.mockResolvedValue(null)

            // Mock Redis to return successful reservation
            mockedRedisClient.setNX.mockResolvedValue(true)
            mockedRedisClient.expire.mockResolvedValue(true)

            const response = await request(app)
                .post('/handles/validate')
                .send(requestData)
                .expect(200)

            expect(response.body).toEqual({
                status: 'reserved',
                expiresInSec: 300,
                idempotencyKey: requestData.idempotencyKey,
            })

            expect(mockedIndexerService.isHandleTaken).toHaveBeenCalledWith('testhandle')
            expect(mockedRedisClient.setNX).toHaveBeenCalled()
            expect(mockedRedisClient.expire).toHaveBeenCalledWith(expect.any(String), 300)
        })

        it('should return 409 when handle is already taken in indexer', async () => {
            const requestData = await createTestValidateRequest()

            // Mock indexer to return handle taken
            mockedIndexerService.isHandleTaken.mockResolvedValue({
                ensName: 'other.eth',
                owner: '0x1234567890123456789012345678901234567890',
                handle: 'testhandle',
            })

            const response = await request(app)
                .post('/handles/validate')
                .send(requestData)
                .expect(409)

            expect(response.body).toEqual({
                error: 'Handle is already taken',
                status: 'taken',
            })
        })

        it('should return 409 when handle is reserved by different owner', async () => {
            const requestData = await createTestValidateRequest()

            // Mock indexer to return handle not taken
            mockedIndexerService.isHandleTaken.mockResolvedValue(null)

            // Mock Redis to return reservation already exists
            mockedRedisClient.setNX.mockResolvedValue(false)
            mockedRedisClient.get.mockResolvedValue(JSON.stringify({
                owner: '0x9999999999999999999999999999999999999999',
                ensName: 'other.eth',
                idempotencyKey: 'different-key',
                state: 'reserved',
                createdAt: Math.floor(Date.now() / 1000),
            }))
            mockedRedisClient.ttl.mockResolvedValue(250)

            const response = await request(app)
                .post('/handles/validate')
                .send(requestData)
                .expect(409)

            expect(response.body).toEqual({
                error: 'Handle is already reserved',
                status: 'reserved',
                expiresInSec: 250,
            })
        })

        it('should return existing reservation for same owner and idempotency key', async () => {
            const requestData = await createTestValidateRequest()

            // Mock indexer to return handle not taken
            mockedIndexerService.isHandleTaken.mockResolvedValue(null)

            // Mock Redis to return existing reservation for same owner
            mockedRedisClient.setNX.mockResolvedValue(false)
            mockedRedisClient.get.mockResolvedValue(JSON.stringify({
                owner: testWallet.address,
                ensName: 'test.eth',
                idempotencyKey: requestData.idempotencyKey,
                state: 'reserved',
                createdAt: Math.floor(Date.now() / 1000),
            }))
            mockedRedisClient.ttl.mockResolvedValue(250)

            const response = await request(app)
                .post('/handles/validate')
                .send(requestData)
                .expect(200)

            expect(response.body).toEqual({
                status: 'reserved',
                expiresInSec: 250,
                idempotencyKey: requestData.idempotencyKey,
            })
        })

        it('should reject invalid handle format', async () => {
            const requestData = await createTestValidateRequest('ab') // Too short

            const response = await request(app)
                .post('/handles/validate')
                .send(requestData)
                .expect(400)

            expect(response.body.error).toContain('Handle must be at least 3 characters long')
        })

        it('should reject invalid signature', async () => {
            const requestData = await createTestValidateRequest('testhandle', true) // Use invalid signature

            const response = await request(app)
                .post('/handles/validate')
                .send(requestData)
                .expect(403)

            expect(response.body.error).toBe('Invalid signature')
        })
    })

    describe('POST /handles/confirm', () => {

        it('should successfully confirm a reservation', async () => {
            const requestData = await createTestConfirmRequest()

            // Mock existing reservation
            mockedRedisClient.get.mockResolvedValue(JSON.stringify({
                owner: testWallet.address,
                ensName: 'test.eth',
                idempotencyKey: randomUUID(),
                state: 'reserved',
                createdAt: Math.floor(Date.now() / 1000),
            }))
            mockedRedisClient.set.mockResolvedValue('OK')
            mockedRedisClient.expire.mockResolvedValue(true)

            const response = await request(app)
                .post('/handles/confirm')
                .send(requestData)
                .expect(200)

            expect(response.body).toEqual({
                status: 'pending_onchain',
                expiresInSec: 900,
            })
        })

        it('should return 404 when reservation not found', async () => {
            const requestData = await createTestConfirmRequest()

            mockedRedisClient.get.mockResolvedValue(null)

            const response = await request(app)
                .post('/handles/confirm')
                .send(requestData)
                .expect(404)

            expect(response.body.error).toBe('Reservation not found')
        })

        it('should return 409 when not the owner', async () => {
            const requestData = await createTestConfirmRequest()

            // Mock reservation by different owner
            mockedRedisClient.get.mockResolvedValue(JSON.stringify({
                owner: '0x9999999999999999999999999999999999999999',
                ensName: 'test.eth',
                idempotencyKey: randomUUID(),
                state: 'reserved',
                createdAt: Math.floor(Date.now() / 1000),
            }))

            const response = await request(app)
                .post('/handles/confirm')
                .send(requestData)
                .expect(409)

            expect(response.body.error).toBe('Not the owner of this reservation')
        })
    })

    describe('GET /handles/status', () => {
        it('should return taken status when handle exists in indexer', async () => {
            mockedIndexerService.isHandleTaken.mockResolvedValue({
                ensName: 'test.eth',
                owner: testWallet.address,
                handle: 'testhandle',
            })

            const response = await request(app)
                .get('/handles/status')
                .query({ handle: 'testhandle' })
                .expect(200)

            expect(response.body).toEqual({
                status: 'taken',
                by: {
                    ensName: 'test.eth',
                    owner: testWallet.address,
                },
            })
        })

        it('should return reserved status when handle is in Redis', async () => {
            mockedIndexerService.isHandleTaken.mockResolvedValue(null)
            mockedRedisClient.get.mockResolvedValue(JSON.stringify({
                owner: testWallet.address,
                ensName: 'test.eth',
                idempotencyKey: randomUUID(),
                state: 'reserved',
                createdAt: Math.floor(Date.now() / 1000),
            }))
            mockedRedisClient.ttl.mockResolvedValue(250)

            const response = await request(app)
                .get('/handles/status')
                .query({ handle: 'testhandle' })
                .expect(200)

            expect(response.body.status).toBe('reserved')
            expect(response.body.expiresInSec).toBe(250)
        })

        it('should return available status when handle is not taken or reserved', async () => {
            mockedIndexerService.isHandleTaken.mockResolvedValue(null)
            mockedRedisClient.get.mockResolvedValue(null)

            const response = await request(app)
                .get('/handles/status')
                .query({ handle: 'testhandle' })
                .expect(200)

            expect(response.body).toEqual({
                status: 'available',
            })
        })
    })

    describe('Race Conditions', () => {
        it('should handle concurrent validate requests for same handle', async () => {
            const handle = 'racetest'
            const request1 = await createTestValidateRequest(handle, false, testWallet)
            const request2 = await createTestValidateRequest(handle, false, testWallet2)

            // Mock indexer to return handle not taken
            mockedIndexerService.isHandleTaken.mockResolvedValue(null)

            // First request succeeds
            mockedRedisClient.setNX.mockResolvedValueOnce(true)
            mockedRedisClient.expire.mockResolvedValue(true)

            // Second request fails (key exists)  
            mockedRedisClient.setNX.mockResolvedValueOnce(false)
            mockedRedisClient.get.mockResolvedValue(JSON.stringify({
                owner: testWallet2.address, // Different owner from request1
                ensName: 'test.eth',
                idempotencyKey: request2.idempotencyKey,
                state: 'reserved',
                createdAt: Math.floor(Date.now() / 1000),
            }))
            mockedRedisClient.ttl.mockResolvedValue(250)

            const [response1, response2] = await Promise.all([
                request(app).post('/handles/validate').send(request1),
                request(app).post('/handles/validate').send(request2),
            ])

            expect(response1.status).toBe(200)
            expect(response2.status).toBe(200)
        })
    })
})
