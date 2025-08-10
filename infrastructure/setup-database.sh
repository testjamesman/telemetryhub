#!/bin/bash

# This script ensures the necessary database and table exist for local testing.
# It reads connection details from the standard DB_* environment variables.

set -e # Exit immediately if a command exits with a non-zero status.

# --- Validation ---
if ! command -v psql &> /dev/null; then
    echo "Error: psql command-line tool is not installed or not in your PATH."
    echo "Please install PostgreSQL client tools."
    exit 1
fi

if [ -z "$DB_HOST" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASSWORD" ] || [ -z "$DB_NAME" ]; then
  echo "Error: DB_HOST, DB_USER, DB_PASSWORD, and DB_NAME environment variables must be set."
  exit 1
fi

# Export the password for psql to use it automatically
export PGPASSWORD=$DB_PASSWORD

# --- Database Creation ---
echo "--- Ensuring database '$DB_NAME' exists ---"
# Check if the database exists. If the command returns '1', it exists.
#     psql -h <hostname> -p <port_number> -d <database_name> -U <username>
DB_EXISTS=$(psql -h "$DB_HOST" -U "$DB_USER" -d postgres -t -c "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME';" | xargs)

if [ "$DB_EXISTS" == "1" ]; then
    echo "✅ Database '$DB_NAME' already exists."
else
    echo "Database not found. Creating..."
    psql -h "$DB_HOST" -U "$DB_USER" -d postgres -c "CREATE DATABASE $DB_NAME;"
    echo "✅ Database '$DB_NAME' created."
fi

# --- Table Creation ---
echo "--- Ensuring table 'processed_messages' exists in '$DB_NAME' ---"
TABLE_SQL="CREATE TABLE IF NOT EXISTS processed_messages (id SERIAL PRIMARY KEY, message_id VARCHAR(255) NOT NULL, content VARCHAR(255), processed_at TIMESTAMP WITH TIME ZONE DEFAULT NOW());"
psql  -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -c "$TABLE_SQL"

echo "✅ Table 'processed_messages' is ready."
echo "--- Database setup complete. ---"
