# Integration Tests for Social Validation Service

## Prerequisites

1. **Redis Server**: You need a local Redis server running for the integration tests.

### Installing Redis

#### macOS (using Homebrew):
```bash
brew install redis
brew services start redis
```

#### Ubuntu/Debian:
```bash
sudo apt update
sudo apt install redis-server
sudo systemctl start redis-server
```

#### Windows:
Download and install from [Redis Windows](https://github.com/tporadowski/redis/releases)

#### Docker:
```bash
docker run -d -p 6379:6379 --name redis-test redis:alpine
```

## Running Tests

### All Tests
```bash
yarn test
```

### Integration Tests Only
```bash
yarn test:integration
```

### Unit Tests Only
```bash
yarn test:unit
```

### Watch Mode
```bash
yarn test:watch
```

### With Coverage
```bash
yarn test:coverage
```

## Test Configuration

The tests use the following Redis configuration:
- **Host**: `localhost` (can be overridden with `REDIS_HOST`)
- **Port**: `6379` (can be overridden with `REDIS_PORT`)
- **Password**: None (can be set with `REDIS_PASSWORD`)

### Custom Redis Configuration

Create a `.env.test` file in the project root:
```bash
REDIS_HOST=your-redis-host
REDIS_PORT=your-redis-port
REDIS_PASSWORD=your-redis-password
```

## Test Structure

### Integration Tests (`tests/socialValidation.integration.test.ts`)

Tests the complete Redis integration including:

1. **generateVerificationCode**: Unique code generation
2. **isHandleClaimed**: Handle availability checking
3. **reserveHandle**: Temporary handle reservation with expiration
4. **validateReservation**: Reservation validation
5. **confirmClaim**: Moving from pending to active status
6. **markOnChain**: Finalizing claims on blockchain
7. **getClaimInfo**: Retrieving claim information
8. **cleanupExpiredClaims**: Cleanup operations
9. **End-to-End Flow**: Complete workflow from reservation to on-chain

### Test Features

- **Database Isolation**: Each test runs with a clean Redis database
- **Real Redis Operations**: Tests actual Redis commands and data persistence
- **Expiration Testing**: Verifies TTL and expiration behavior
- **Error Handling**: Tests edge cases and error conditions
- **Case Sensitivity**: Validates handle normalization
- **Concurrency**: Tests claim conflicts and race conditions

## Test Output

Successful test run will show:
```
 PASS  tests/socialValidation.integration.test.ts
  SocialValidationService Integration Tests
    generateVerificationCode
      ✓ should generate unique verification codes
    isHandleClaimed
      ✓ should return false for unclaimed handle
      ✓ should return true for claimed handle
      ✓ should handle case-insensitive handle lookup
    reserveHandle
      ✓ should successfully reserve an unclaimed handle
      ✓ should throw error for already claimed handle
      ✓ should set proper expiration on pending claim
    validateReservation
      ✓ should return true for valid reservation
      ✓ should return false for non-existent reservation
      ✓ should return false for mismatched ENS name
      ✓ should return false for mismatched owner
    confirmClaim
      ✓ should successfully confirm a valid pending claim
      ✓ should return false for non-existent pending claim
      ✓ should return false for mismatched claim details
      ✓ should set proper expiration on active claim
    markOnChain
      ✓ should mark verified claim as on-chain
      ✓ should handle non-existent claim gracefully
    getClaimInfo
      ✓ should return null for non-existent claim
      ✓ should return active claim info
      ✓ should return pending claim info
      ✓ should prioritize active claims over pending claims
    cleanupExpiredClaims
      ✓ should remove claims without expiration
      ✓ should not remove claims with proper expiration
    End-to-End Flow
      ✓ should complete full reservation to on-chain flow

Test Suites: 1 passed, 1 total
Tests:       22 passed, 22 total
```

## Troubleshooting

### Redis Connection Issues
- Ensure Redis server is running: `redis-cli ping` should return `PONG`
- Check Redis logs for connection errors
- Verify Redis is accepting connections on the configured port

### Test Failures
- Check Redis server is running and accessible
- Verify no other processes are using the test Redis database
- Ensure proper environment variables are set in `.env.test`

### Performance Issues
- Redis operations should be fast (<100ms each)
- If tests are slow, check Redis server performance
- Consider using Redis on localhost for fastest tests
