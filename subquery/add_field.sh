#!/bin/bash

# Configuration variables
CONTAINER_NAME=${CONTAINER_NAME:-"subquery-postgres-1"}
DB_USER=${DB_USER:-"postgres"}
DB_DATABASE=${DB_DATABASE:-"postgres"}
SCHEMA_NAME=${SCHEMA_NAME:-"app"}

# Colors for messages
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to check if Docker is running
check_docker() {
    if ! docker info >/dev/null 2>&1; then
        echo -e "${RED}Error: Docker is not running${NC}"
        echo "Please start Docker and try again"
        exit 1
    fi
}

# Function to check Subquery containers status
check_subquery_containers() {
    # Only check critical containers for database operations
    local critical_containers=("subquery-postgres-1" "subquery-subquery-node-1")
    local all_healthy=true

    for container in "${critical_containers[@]}"; do
        if ! docker ps -q -f name="^/${container}$" > /dev/null; then
            echo -e "${RED}Error: Critical container $container is not running${NC}"
            all_healthy=false
        else
            local health=$(docker inspect --format='{{.State.Health.Status}}' $container 2>/dev/null)
            if [ "$health" != "healthy" ]; then
                echo -e "${RED}Error: Critical container $container is not healthy${NC}"
                all_healthy=false
            fi
        fi
    done

    # Check GraphQL engine but only show warning
    if docker ps -q -f name="^/subquery-graphql-engine-1$" > /dev/null; then
        local graphql_health=$(docker inspect --format='{{.State.Health.Status}}' subquery-graphql-engine-1 2>/dev/null)
        if [ "$graphql_health" != "healthy" ]; then
            echo -e "${YELLOW}Warning: GraphQL engine is not healthy, but this won't affect database operations${NC}"
        fi
    fi

    if [ "$all_healthy" = false ]; then
        echo -e "${YELLOW}Current container status:${NC}"
        docker ps -a --filter "name=subquery"
        exit 1
    fi
}

# Function to execute SQL commands with error handling
execute_sql() {
    check_docker
    check_subquery_containers
    
    echo -e "${YELLOW}Executing: $1${NC}"
    if ! docker exec -i $CONTAINER_NAME psql -U $DB_USER -d $DB_DATABASE -c "$1"; then
        echo -e "${RED}Error executing SQL command${NC}"
        return 1
    fi
    echo -e "${GREEN}Command executed successfully${NC}"
}

# Function to create optimized indexes
create_indexes() {
    echo "Creating optimized indexes..."
    
    declare -a indexes=(
        # Main composite index for sorting and filtering
        "CREATE INDEX IF NOT EXISTS idx_erc20_transfers_composite ON ${SCHEMA_NAME}.e_r_c20_transfers (timestamp DESC, _id ASC, from_id, to_id)"
        
        # BRIN index for block ranges (more efficient for sequential data)
        "CREATE INDEX IF NOT EXISTS idx_erc20_transfers_block_range ON ${SCHEMA_NAME}.e_r_c20_transfers USING brin(_block_range)"
        
        # Case-insensitive search indexes
        "CREATE INDEX IF NOT EXISTS idx_erc20_transfers_from_lower ON ${SCHEMA_NAME}.e_r_c20_transfers (lower(from_id))"
        "CREATE INDEX IF NOT EXISTS idx_erc20_transfers_to_lower ON ${SCHEMA_NAME}.e_r_c20_transfers (lower(to_id))"
        
        # Simple timestamp index
        "CREATE INDEX IF NOT EXISTS idx_erc20_transfers_timestamp ON ${SCHEMA_NAME}.e_r_c20_transfers (timestamp DESC)"
    )

    for index in "${indexes[@]}"; do
        execute_sql "$index" || return 1
    done
}

# Function to analyze and maintain tables
analyze_tables() {
    echo "Analyzing tables..."
    execute_sql "ANALYZE VERBOSE ${SCHEMA_NAME}.e_r_c20_transfers;" || return 1
    execute_sql "VACUUM ANALYZE ${SCHEMA_NAME}.e_r_c20_transfers;" || return 1

    execute_sql "ANALYZE VERBOSE ${SCHEMA_NAME}.e_r_c721_tokens;" || return 1
    execute_sql "VACUUM ANALYZE ${SCHEMA_NAME}.e_r_c721_tokens;" || return 1
    
    execute_sql "ANALYZE VERBOSE ${SCHEMA_NAME}.e_r_c721_transfers;" || return 1
    execute_sql "VACUUM ANALYZE ${SCHEMA_NAME}.e_r_c721_transfers;" || return 1
}

# Function to enable required extensions
enable_extensions() {
    echo "Enabling required extensions..."
    execute_sql "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;" || return 1
}

# Function to show slow queries
show_slow_queries() {
    echo "Checking pg_stat_statements extension..."
    
    local has_extension=$(docker exec -i $CONTAINER_NAME psql -U $DB_USER -d $DB_DATABASE -tAc "SELECT COUNT(*) FROM pg_extension WHERE extname = 'pg_stat_statements';")
    
    if [ "$has_extension" = "0" ]; then
        echo -e "${YELLOW}pg_stat_statements extension is not enabled. Attempting to enable it...${NC}"
        enable_extensions
    fi
    
    echo "Showing slow queries..."
    execute_sql "
        SELECT 
            substring(query, 1, 100) as query_preview,
            calls,
            round(total_exec_time::numeric, 2) as total_exec_time_ms,
            round(mean_exec_time::numeric, 2) as mean_exec_time_ms,
            round((100 * total_exec_time / sum(total_exec_time) over ())::numeric, 2) as percentage
        FROM pg_stat_statements
        WHERE total_exec_time > 1000
        ORDER BY total_exec_time DESC
        LIMIT 10;
    "
}

# Function to show current indexes
show_indexes() {
    echo "Showing existing indexes..."
    execute_sql "
        SELECT 
            schemaname as schema,
            tablename as table,
            indexname as index,
            indexdef as definition
        FROM pg_indexes
        WHERE schemaname = '${SCHEMA_NAME}'
        ORDER BY tablename, indexname;
    "
}

# Main menu
main() {
    local command=$1
    
    if [ -z "$command" ]; then
        echo -e "${RED}Error: Command required${NC}"
        echo "Usage: $0 {create-indexes|analyze|show-slow-queries|show-indexes|all}"
        exit 1
    fi

    case "$command" in
        "create-indexes")
            create_indexes
            ;;
        "analyze")
            analyze_tables
            ;;
        "show-slow-queries")
            show_slow_queries
            ;;
        "show-indexes")
            show_indexes
            ;;
        "all")
            create_indexes && \
            analyze_tables && \
            show_slow_queries && \
            show_indexes
            ;;
        *)
            echo -e "${RED}Invalid command: $command${NC}"
            echo "Usage: $0 {create-indexes|analyze|show-slow-queries|show-indexes|all}"
            exit 1
            ;;
    esac
}

# Execute the script
main "$@"