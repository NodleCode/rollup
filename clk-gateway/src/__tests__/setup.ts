// Test environment setup
process.env.NODE_ENV = 'test'
process.env.PORT = '8080'
process.env.REDIS_URL = 'redis://localhost:6380'
process.env.INDEXER_URL = 'https://test-indexer.example.com'
process.env.HANDLE_RESERVE_TTL = '300'
process.env.HANDLE_CONFIRM_TTL = '900'
process.env.RATE_LIMIT_PER_MIN = '60'

// Mock environment variables for existing functionality
process.env.L2_RPC_URL = 'https://test-l2-rpc.example.com'
process.env.L1_RPC_URL = 'https://test-l1-rpc.example.com'
process.env.L2_CHAIN_ID = '324'
process.env.REGISTRAR_PRIVATE_KEY = '0x1234567890123456789012345678901234567890123456789012345678901234'
process.env.DIAMOND_PROXY_ADDR = '0x1234567890123456789012345678901234567890'
process.env.RESOLVER_ADDR = '0x1234567890123456789012345678901234567890'
process.env.CLICK_NS_ADDR = '0x1234567890123456789012345678901234567890'
process.env.NODLE_NS_ADDR = '0x1234567890123456789012345678901234567890'
process.env.CLICK_NS_DOMAIN = 'click'
process.env.NODLE_NS_DOMAIN = 'nodle'
process.env.PARENT_TLD = 'eth'
process.env.SERVICE_ACCOUNT_KEY = '{}'
process.env.SAFE_BATCH_QUERY_OFFSET = '100'
process.env.FEE_TOKEN_ADDR = '0x1234567890123456789012345678901234567890'
process.env.GAS_LIMIT = '1000000'

// Mock global fetch for tests
global.fetch = jest.fn()
