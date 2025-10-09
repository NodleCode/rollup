// Test setup file for Jest
import dotenv from 'dotenv'

// Load test environment variables
dotenv.config({ path: '.env.test' })

// Set default test environment variables
process.env.NODE_ENV = 'test'
process.env.REDIS_HOST = process.env.REDIS_HOST || 'localhost'
process.env.REDIS_PORT = process.env.REDIS_PORT || '6379'
process.env.REDIS_PASSWORD = process.env.REDIS_PASSWORD || ''

// Increase Jest timeout for Redis operations
jest.setTimeout(30000)
