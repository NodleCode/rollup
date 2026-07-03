#!/bin/bash
set -e

# Script to start graphql-engine and subquery-node-ethereum independently
# This allows starting these services after zkSync has finished indexing
# Uses --no-deps to ignore dependencies and start services independently

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "Starting Ethereum indexer and GraphQL engine independently..."

# Check if services are already running
ETHEREUM_RUNNING=$(docker compose ps -q subquery-node-ethereum 2>/dev/null | wc -l)
GRAPHQL_RUNNING=$(docker compose ps -q graphql-engine 2>/dev/null | wc -l)

if [ "$ETHEREUM_RUNNING" -gt 0 ]; then
    echo "Ethereum indexer is already running"
else
    echo "Starting Ethereum indexer (ignoring dependencies)..."
    docker compose up -d --no-deps subquery-node-ethereum
fi

if [ "$GRAPHQL_RUNNING" -gt 0 ]; then
    echo "GraphQL engine is already running"
else
    echo "Starting GraphQL engine (ignoring dependencies)..."
    docker compose up -d --no-deps graphql-engine
fi

echo ""
echo "Services started. Checking status..."
docker compose ps subquery-node-ethereum graphql-engine

echo ""
echo "To view logs:"
echo "  docker compose logs -f subquery-node-ethereum"
echo "  docker compose logs -f graphql-engine"