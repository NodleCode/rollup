#!/bin/bash

# Docker container name
CONTAINER_NAME="subquery-postgres-1"  # Your actual PostgreSQL container name

# Database credentials
DB_USER="postgres"
DB_DATABASE="postgres"  # Change this if you are using a different database

# Set the schema name
SCHEMA_NAME="app"

# Define the SQL command to add multiple columns
SQL_COMMAND="
ALTER TABLE $SCHEMA_NAME.e_r_c721_tokens 
ADD COLUMN content_hash VARCHAR(255);"
#ADD COLUMN duration INTEGER,
#ADD COLUMN capture_date BIGINT,
#ADD COLUMN longitude DOUBLE PRECISION,
#ADD COLUMN latitude DOUBLE PRECISION,
#ADD COLUMN location_precision VARCHAR(255);
#"

# Execute the command in the PostgreSQL container
docker exec -it $CONTAINER_NAME psql -U $DB_USER -d $DB_DATABASE -c "$SQL_COMMAND"

# Check if the columns were added successfully and print all columns in the table
echo "Checking the columns in table 'e_r_c721_tokens' in schema '$SCHEMA_NAME'..."
docker exec -it $CONTAINER_NAME psql -U $DB_USER -d $DB_DATABASE -c "SELECT column_name FROM information_schema.columns WHERE table_schema = '$SCHEMA_NAME' AND table_name = 'e_r_c721_tokens';"

echo "New columns added to table 'e_r_c721_tokens' in schema '$SCHEMA_NAME'."

# Define the SQL commands to create indexes
SQL_COMMANDS_INDEXES="
CREATE INDEX idx_content ON $SCHEMA_NAME.e_r_c721_tokens (content);
"

# Execute the commands in the PostgreSQL container
#docker exec -it $CONTAINER_NAME psql -U $DB_USER -d $DB_DATABASE -c "$SQL_COMMANDS_INDEXES"

echo "Indexes added to table 'e_r_c721_tokens' in schema '$SCHEMA_NAME'."