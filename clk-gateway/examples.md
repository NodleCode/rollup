# Handle Guard API Examples

## Prerequisites

1. Start the service with Redis:
```bash
docker-compose up -d
```

2. Set up environment variables (see `.env.template`)

## Example Requests

### 1. Check Handle Status

```bash
curl -X GET "http://localhost:8080/handles/status?handle=alice" \
  -H "Content-Type: application/json"
```

### 2. Validate and Reserve Handle

```bash
curl -X POST "http://localhost:8080/handles/validate" \
  -H "Content-Type: application/json" \
  -d '{
    "handle": "@alice",
    "ensName": "alice.eth",
    "owner": "0x742DEA4F5F8Ca120B5c2B6C38C0CCE567e96B352",
    "signature": "0x...",
    "ttlSec": 300,
    "idempotencyKey": "550e8400-e29b-41d4-a716-446655440000"
  }'
```

### 3. Confirm Handle with Transaction Hash

```bash
curl -X POST "http://localhost:8080/handles/confirm" \
  -H "Content-Type: application/json" \
  -d '{
    "handle": "@alice",
    "txHash": "0x8b4c78e5f8ca120b5c2b6c38c0cce567e96b352742dea4f5f8ca120b5c2b6c38",
    "owner": "0x742DEA4F5F8Ca120B5c2B6C38C0CCE567e96B352",
    "signature": "0x...",
    "extendTtlSec": 600
  }'
```

### 4. Release Handle Reservation

```bash
curl -X POST "http://localhost:8080/handles/release" \
  -H "Content-Type: application/json" \
  -d '{
    "handle": "@alice",
    "owner": "0x742DEA4F5F8Ca120B5c2B6C38C0CCE567e96B352",
    "signature": "0x..."
  }'
```

### 5. Health Check

```bash
curl -X GET "http://localhost:8080/health"
```

## Signature Generation (JavaScript Example)

```javascript
import { Wallet } from 'ethers';

// Create wallet instance
const wallet = new Wallet('your-private-key');

// Build typed data for validation
const domain = {
  name: "Nodle Name Service",
  version: "1",
  chainId: 324, // Your L2 chain ID
};

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
  owner: wallet.address,
  action: "validate_handle",
};

// Sign the typed data
const signature = await wallet.signTypedData(domain, types, message);
console.log("Signature:", signature);
```

## Testing Race Conditions

Run multiple concurrent requests to test the reservation system:

```bash
# Terminal 1
curl -X POST "http://localhost:8080/handles/validate" \
  -H "Content-Type: application/json" \
  -d '{"handle": "racetest", "ensName": "user1.eth", "owner": "0x742DEA4F5F8Ca120B5c2B6C38C0CCE567e96B352", "signature": "0x..."}' &

# Terminal 2 (should get 409 conflict)
curl -X POST "http://localhost:8080/handles/validate" \
  -H "Content-Type: application/json" \
  -d '{"handle": "racetest", "ensName": "user2.eth", "owner": "0x8888888888888888888888888888888888888888", "signature": "0x..."}' &
```

## Expected Responses

### Successful Validation
```json
{
  "status": "reserved",
  "expiresInSec": 300,
  "idempotencyKey": "550e8400-e29b-41d4-a716-446655440000"
}
```

### Handle Already Taken
```json
{
  "error": "Handle is already taken",
  "status": "taken"
}
```

### Handle Already Reserved
```json
{
  "error": "Handle is already reserved",
  "status": "reserved",
  "expiresInSec": 250
}
```

### Handle Status - Available
```json
{
  "status": "available"
}
```

### Handle Status - Taken
```json
{
  "status": "taken",
  "by": {
    "ensName": "alice.eth",
    "owner": "0x742DEA4F5F8Ca120B5c2B6C38C0CCE567e96B352"
  }
}
```
