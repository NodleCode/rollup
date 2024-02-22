# Create network
docker network create zksync-era_zkstack

# Set platform
export DOCKER_DEFAULT_PLATFORM=linux/amd64

# Start zk-sync
docker compose -f docker-compose-custom-chain.yml up -d