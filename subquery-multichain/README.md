# NODL Bridge Multi-Chain Indexer

SubQuery multi-chain project for indexing NODL token bridge events between Ethereum L1 and zkSync Era L2.

## Overview

This project indexes bridge events from both networks into a single database, allowing you to query bridge activity across both chains from a single GraphQL endpoint.

### Indexed Events

**Ethereum L1:**
- `DepositInitiated` - When a deposit is initiated on L1
- `WithdrawalFinalized` - When a withdrawal from L2 is finalized on L1
- `ClaimedFailedDeposit` - When a failed deposit is claimed back

**zkSync Era L2:**
- `DepositFinalized` - When a deposit from L1 is finalized on L2
- `WithdrawalInitiated` - When a withdrawal is initiated on L2

## Prerequisites

- Node.js (v16 or higher)
- Docker and Docker Compose
- SubQuery CLI: `npm install -g @subql/cli`

## Setup

1. **Install dependencies:**
   ```bash
   npm install
   ```

2. **Create `.env` file:**
   ```bash
   cp .env.example .env
   ```
   Then edit `.env` and add your RPC endpoints:
   ```
   ETHEREUM_MAINNET_RPC=your_ethereum_rpc_url
   ZKSYNC_MAINNET_RPC=your_zksync_rpc_url
   ```

3. **Generate types:**
   ```bash
   npm run codegen
   ```

4. **Build the project:**
   ```bash
   npm run build
   ```

## Running the Project

Start all services (PostgreSQL, two indexers, and GraphQL engine):

```bash
npm run dev
```

Or manually:

```bash
docker-compose up
```

The GraphQL playground will be available at [http://localhost:3000](http://localhost:3000)

## Project Structure

- `schema.graphql` - GraphQL schema defining BridgeDeposit and BridgeWithdrawal entities
- `project-ethereum.ts` - L1 (Ethereum) project manifest
- `project-zksync.ts` - L2 (zkSync) project manifest
- `subquery-multichain.yaml` - Multi-chain manifest listing both projects
- `src/mappings/bridge.ts` - Bridge event handlers with ID consistency logic
- `abis/` - Contract ABIs for both bridges

## Multi-Chain Configuration

This project uses SubQuery's multi-chain feature:
- Two separate indexer nodes (one per chain)
- Shared database schema: `bridge-multichain`
- Both indexers write to the same PostgreSQL database
- Single GraphQL endpoint queries data from both chains

## Querying Bridge Data

Example GraphQL queries:

```graphql
# Get all bridge deposits
{
  bridgeDeposits(first: 10, orderBy: TIMESTAMP_DESC) {
    nodes {
      id
      l1Sender {
        id
      }
      l2Receiver {
        id
      }
      amount
      network
      timestamp
      l2DepositTxHash
    }
  }
}

# Get all bridge withdrawals
{
  bridgeWithdrawals(first: 10, orderBy: TIMESTAMP_DESC) {
    nodes {
      id
      l2Sender {
        id
      }
      l1Receiver {
        id
      }
      amount
      finalized
      finalizedAt
      network
      l2BatchNumber
      l2MessageIndex
    }
  }
}

# Filter by network
{
  bridgeDeposits(filter: { network: { equalTo: "ethereum" } }) {
    nodes {
      id
      amount
      network
    }
  }
}
```

## ID Consistency

The project implements ID consistency across chains:
- **Deposits**: Use `deposit-{l2DepositTxHash}` as common ID
- **Withdrawals**: Use `withdrawal-{batchNumber}-{messageIndex}` as common ID

This ensures that deposits and withdrawals are properly linked between L1 and L2 events.

## Contract Addresses

- **L1 Bridge (Ethereum)**: `0x2d02b651ea9630351719c8c55210e042e940d69a`
- **L2 Bridge (zkSync)**: `0x2c1B65dA72d5Cf19b41dE6eDcCFB7DD83d1B529E`

## Start Blocks

- **Ethereum L1**: Block 23635846
- **zkSync L2**: Block 65260492

## Development

- `npm run codegen` - Generate TypeScript types from schema and ABIs
- `npm run build` - Build the project
- `npm run dev` - Run codegen, build, and start Docker services
- `npm run test` - Run tests

## Publishing

To publish to SubQuery Network:

```bash
npm run publish
```

This will publish both project manifests to IPFS as a single multi-chain project.

