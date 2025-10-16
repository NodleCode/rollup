#!/bin/bash

# Start Redis test container
echo "Starting Redis test container..."
docker compose -f docker-compose.test.yml up -d redis-test

# Wait for Redis to be ready
echo "Waiting for Redis to be ready..."
until docker compose -f docker-compose.test.yml exec -T redis-test redis-cli ping | grep -q "PONG"; do
    sleep 1
done

echo "Redis is ready!"

# Run integration tests with test Redis URL
echo "Running integration tests..."
REDIS_URL="redis://localhost:6380" yarn test handles.integration.test.ts

# Store test exit code
TEST_EXIT_CODE=$?

# Clean up
echo "Cleaning up..."
docker compose -f docker-compose.test.yml down

# Exit with the same code as the tests
exit $TEST_EXIT_CODE
