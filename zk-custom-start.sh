# Create network
docker network create zksync-era_zkstack

# create volume for postgres
mkdir -p ./volumes/postgres

# Start PostgreSQL
docker compose -f docker-compose-postgres.yml up -d postgres

# Wait for PostgreSQL to start
sleep 5

# check if the database is ready
docker compose -f docker-compose-postgres.yml exec -T postgres bash -c "while ! pg_isready -h localhost -U postgres; do sleep 1; done"

# # save current directory
HOME_DIR=$(pwd)

# # Go to ZKSync directory
cd $ZKSYNC_HOME

# # Run migrations
zk db setup

# # Go back to the original directory
cd $HOME_DIR

# Start zk-sync
docker compose -f docker-compose-custom-chain.yml up -d