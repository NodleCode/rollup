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

        "CREATE INDEX IF NOT EXISTS idx_ens_block_range_owner ON ${SCHEMA_NAME}.e_ns USING gist (_block_range, owner_id)"

        "CREATE INDEX IF NOT EXISTS idx_ens_id_block_range ON ${SCHEMA_NAME}.e_ns USING btree (_id, _block_range)"

        "CREATE INDEX IF NOT EXISTS idx_ens_owner_block_range ON app.e_ns USING GIST (owner_id, _block_range)"

        "CREATE INDEX IF NOT EXISTS idx_ens_block_range_id ON app.e_ns USING GIST (_block_range, _id)"

        "CREATE INDEX IF NOT EXISTS idx_accounts_block_range ON app.accounts USING GIST (_block_range)"

        "CREATE INDEX IF NOT EXISTS idx_users_levels_stats_block_range ON app.users_levels_stats USING GIST (_block_range)"

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

# Function to modify PostgreSQL configuration
modify_postgres_config() {
    echo "Modifying PostgreSQL configuration..."
    
    # Check if configuration already exists
    if ! docker exec -i $CONTAINER_NAME grep -q "shared_preload_libraries" /var/lib/postgresql/data/postgresql.conf; then
        # If it doesn't exist, add the complete line
        docker exec -i $CONTAINER_NAME bash -c 'echo "shared_preload_libraries = '\''pg_stat_statements'\''" >> /var/lib/postgresql/data/postgresql.conf'
    else
        # If it exists, update the existing line
        docker exec -i $CONTAINER_NAME sed -i 's/^shared_preload_libraries.*/shared_preload_libraries = '\''pg_stat_statements'\''/' /var/lib/postgresql/data/postgresql.conf
    fi
    
    echo "Restarting PostgreSQL container..."
    docker restart $CONTAINER_NAME
    
    # Wait until PostgreSQL is available
    while ! docker exec -i $CONTAINER_NAME pg_isready -U postgres > /dev/null 2>&1; do
        echo "Waiting for PostgreSQL to be available..."
        sleep 2
    done
    
    # Wait until container is healthy
    while [ "$(docker inspect --format='{{.State.Health.Status}}' $CONTAINER_NAME)" != "healthy" ]; do
        echo "Waiting for PostgreSQL to be fully healthy..."
        sleep 2
    done
    
    echo "PostgreSQL restarted and ready"
}

# Function to show slow queries
show_slow_queries() {
    echo "Checking pg_stat_statements configuration..."
    
    local has_config=$(docker exec -i $CONTAINER_NAME grep -c "shared_preload_libraries.*pg_stat_statements" /var/lib/postgresql/data/postgresql.conf || echo "0")
    
    if [ "$has_config" = "0" ]; then
        echo -e "${YELLOW}pg_stat_statements is not configured in shared_preload_libraries. Configuring...${NC}"
        modify_postgres_config
        enable_extensions 
    fi
    
    enable_extensions
    
    echo "Showing slow queries..."
    execute_sql "
        SELECT 
            substring(query, 1, 500) as query_preview,
            calls,
            round(total_exec_time::numeric, 2) as total_exec_time_ms,
            round(mean_exec_time::numeric, 2) as mean_exec_time_ms,
            round((100 * total_exec_time / sum(total_exec_time) over ())::numeric, 2) as percentage,
            round(rows/calls::numeric, 2) as avg_rows,
            round(shared_blks_hit/calls::numeric, 2) as avg_cache_hits,
            round(shared_blks_read/calls::numeric, 2) as avg_disk_reads,
            round((shared_blks_hit::numeric / NULLIF(shared_blks_hit + shared_blks_read, 0)) * 100, 2) as cache_hit_ratio
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

# Function to validate PostgreSQL configuration
validate_postgres_config() {
    echo "Validating PostgreSQL configuration..."
    
    # Check system resources
    echo -e "\nSystem Resources:"
    echo "--------------------------------"
    echo "CPU Usage:"
    docker stats --no-stream $CONTAINER_NAME --format "CPU: {{.CPUPerc}}"
    echo "Memory Usage:"
    docker stats --no-stream $CONTAINER_NAME --format "Memory: {{.MemPerc}} ({{.MemUsage}})"
    
    # Array of important settings to check with expected values
    declare -A settings=(
        ["shared_buffers"]="1GB"
        ["work_mem"]="32MB"
        ["maintenance_work_mem"]="64MB"
        ["effective_cache_size"]="2GB"
        ["max_connections"]="30"
        ["max_worker_processes"]="2"
        ["max_parallel_workers_per_gather"]="1"
        ["max_parallel_workers"]="2"
        ["autovacuum"]="on"
        ["autovacuum_naptime"]="60s"
        ["checkpoint_timeout"]="15min"
        ["shared_preload_libraries"]="pg_stat_statements"
        ["jit"]="off"
        ["track_activities"]="off"
        ["track_counts"]="off"
        ["track_io_timing"]="off"
    )
    
    echo -e "\nPostgreSQL Settings:"
    echo "--------------------------------"
    
    local all_correct=true
    
    for setting in "${!settings[@]}"; do
        local expected="${settings[$setting]}"
        local current=$(docker exec -i $CONTAINER_NAME psql -U $DB_USER -d $DB_DATABASE -t -c "SHOW $setting;" | tr -d ' ')
        local config_value=$(docker exec -i $CONTAINER_NAME grep "^$setting" /var/lib/postgresql/data/postgresql.conf | cut -d'=' -f2- | tr -d ' ' || echo "not_set")
        
        echo -e "\n${YELLOW}$setting:${NC}"
        echo -e "  Expected value : ${GREEN}$expected${NC}"
        echo -e "  Current value  : ${GREEN}$current${NC}"
        echo -e "  Config file    : ${YELLOW}$config_value${NC}"
        
        if [[ "$current" != "$expected" ]]; then
            echo -e "  ${RED}⚠ Value mismatch${NC}"
            all_correct=false
        else
            echo -e "  ${GREEN}✓ Correct${NC}"
        fi
    done
    
    # Check active connections
    echo -e "\nConnection Status:"
    echo "--------------------------------"
    execute_sql "
        SELECT datname as database, 
               usename as user, 
               application_name,
               client_addr,
               state,
               count(*) as count
        FROM pg_stat_activity 
        GROUP BY 1,2,3,4,5
        ORDER BY count DESC;
    "
    
    # Check pg_stat_statements status
    echo -e "\npg_stat_statements Status:"
    echo "--------------------------------"
    if docker exec -i $CONTAINER_NAME psql -U $DB_USER -d $DB_DATABASE -c "SELECT count(*) FROM pg_stat_statements LIMIT 1;" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ pg_stat_statements is accessible${NC}"
        
        # Show pg_stat_statements statistics
        echo -e "\nStatement Statistics:"
        execute_sql "
            SELECT 
                round(total_exec_time::numeric, 2) as total_time_ms,
                calls,
                round(mean_exec_time::numeric, 2) as avg_time_ms,
                round((100 * total_exec_time / sum(total_exec_time) over ())::numeric, 2) as time_percent
            FROM pg_stat_statements 
            ORDER BY total_exec_time DESC 
            LIMIT 5;
        "
    else
        echo -e "${RED}✗ Cannot access pg_stat_statements${NC}"
        all_correct=false
    fi
    
    # Final status
    echo -e "\nOverall Status:"
    echo "--------------------------------"
    if [ "$all_correct" = true ]; then
        echo -e "${GREEN}✓ All configurations match expected values${NC}"
    else
        echo -e "${RED}⚠ Some configurations need attention${NC}"
    fi
}

# Main menu
main() {
    local command=$1
    
    if [ -z "$command" ]; then
        echo -e "${RED}Error: Command required${NC}"
        echo "Usage: $0 {create-indexes|analyze|show-slow-queries|show-indexes|validate-config|all}"
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
        "validate-config")
            validate_postgres_config
            ;;
        "all")
            create_indexes && \
            analyze_tables && \
            show_slow_queries && \
            show_indexes && \
            validate_postgres_config
            ;;
        *)
            echo -e "${RED}Invalid command: $command${NC}"
            echo "Usage: $0 {create-indexes|analyze|show-slow-queries|show-indexes|validate-config|all}"
            exit 1
            ;;
    esac
}

# Execute the script
main "$@"