# ENS Handle Guard Service

A comprehensive service for preventing duplicate social-handle claims for ENS profiles by combining an eventually-consistent indexer with a short-lived Redis reservation system.

## Features

- **Handle Validation & Reservation**: Reserve social handles temporarily while preparing on-chain transactions
- **Conflict Prevention**: Prevent duplicate social handle claims across ENS profiles
- **Eventually Consistent**: Reconcile with GraphQL indexer to ensure data consistency
- **Rate Limited**: Built-in rate limiting to prevent abuse
- **Signature Verification**: EIP-712 signature-based authentication
- **Docker Ready**: Complete Docker setup with Redis

## Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Client App    │───▶│  Handle Guard   │───▶│     Redis       │
│                 │    │     API         │    │  (Reservations) │
└─────────────────┘    └─────────────────┘    └─────────────────┘
                               │
                               ▼
                       ┌─────────────────┐
                       │  GraphQL        │
                       │   Indexer       │
                       │ (Source Truth)  │
                       └─────────────────┘
```

## Handle States

- `available`: Not in indexer, not reserved
- `reserved`: In Redis TTL window (default 5min)
- `pending_onchain`: Reserved + txHash attached (default 15min)
- `taken`: Confirmed by indexer (source of truth)

## API Endpoints

### POST /handles/validate
Validate and reserve a handle for a specific ENS name and owner.

### POST /handles/confirm
Confirm a reservation by providing the transaction hash of the on-chain text record update.

### POST /handles/release
Release a handle reservation, making it available again.

### GET /handles/status
Get the current status of a handle.

### GET /health
Health check endpoint with reconciler status.

## Quick Start

### Using Docker Compose (Recommended)

1. Copy environment template:
```bash
cp .env.template .env
# Edit .env with your configuration
```

2. Start services:
```bash
docker-compose up -d
```

3. Test the API:
```bash
curl http://localhost:8080/health
```

### Manual Setup

1. Install dependencies:
```bash
npm install
```

2. Start Redis:
```bash
redis-server
```

3. Set environment variables (see `.env.template`)

4. Start the service:
```bash
npm run dev
```

## Environment Variables

| Variable             | Description                       | Default                            |
| -------------------- | --------------------------------- | ---------------------------------- |
| `PORT`               | Server port                       | `8080`                             |
| `REDIS_URL`          | Redis connection URL              | `redis://localhost:6379`           |
| `INDEXER_URL`        | GraphQL indexer endpoint          | `https://indexer.nodleprotocol.io` |
| `HANDLE_RESERVE_TTL` | Default reservation TTL (seconds) | `300`                              |
| `HANDLE_CONFIRM_TTL` | Confirmation TTL (seconds)        | `900`                              |
| `RATE_LIMIT_PER_MIN` | Rate limit per minute             | `60`                               |

## Handle Validation Rules

- Minimum 3 characters, maximum 30 characters
- Only letters, numbers, and underscores allowed
- Cannot start or end with underscore
- Cannot contain consecutive underscores
- Case-insensitive (normalized to lowercase)
- Leading `@` symbol is automatically removed

## Signature Authentication

All write operations require EIP-712 signatures to prove ownership. The signature format varies by operation:

### Validate Handle
```javascript
const types = {
  HandleValidation: [
    { name: "handle", type: "string" },
    { name: "ensName", type: "string" },
    { name: "owner", type: "address" },
    { name: "action", type: "string" },
  ],
};

const message = {
  handle: "alice",
  ensName: "alice.eth", 
  owner: "0x742DEA4F5F8Ca120B5c2B6C38C0CCE567e96B352",
  action: "validate_handle",
};
```

### Confirm Handle
```javascript
const types = {
  HandleConfirmation: [
    { name: "handle", type: "string" },
    { name: "txHash", type: "string" },
    { name: "owner", type: "address" },
    { name: "action", type: "string" },
  ],
};
```

### Release Handle
```javascript
const types = {
  HandleRelease: [
    { name: "handle", type: "string" },
    { name: "owner", type: "address" },
    { name: "action", type: "string" },
  ],
};
```

## Background Reconciler

The service includes a background worker that:

- Runs every 30 seconds
- Checks pending reservations against the indexer
- Removes confirmed or failed reservations
- Handles timeout scenarios
- Provides graceful error handling

## Testing

Run the test suite:
```bash
npm test
```

Run specific test files:
```bash
npm test handles.test.ts
npm test handle.utils.test.ts
```

## API Documentation

The complete OpenAPI specification is available in `openapi.json`. You can view it using tools like Swagger UI or Postman.

## Security Considerations

- All write operations require valid EIP-712 signatures
- Rate limiting prevents abuse (60 requests/minute by default)
- Reservations have automatic expiration
- System handles are reserved and cannot be claimed
- Input validation prevents injection attacks

## Monitoring

- Health endpoint provides service and reconciler status
- Comprehensive error logging
- Redis connection monitoring
- Graceful shutdown handling

## Contributing

1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Ensure all tests pass
5. Submit a pull request

## License

BSD-3-Clause

## Support

For issues and questions, please open a GitHub issue or contact the development team.
