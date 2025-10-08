#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Configuration from environment variables
SCALEWAY_BUCKET="${SCALEWAY_BUCKET:-lucca-analytics}"
SCALEWAY_REGION="${SCALEWAY_REGION:-fr-par}"
SCALEWAY_ENDPOINT="https://s3.${SCALEWAY_REGION}.scw.cloud"

# Store the script directory path
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Get today's date for filename pattern
TODAY_DATE=$(date '+%Y-%m-%d')
BACKUP_PATTERN="stats-backup-file-${TODAY_DATE}"

echo "Starting Scaleway S3 to MySQL sync..."

# Install packages from Aptfile if it exists
APTFILE="${SCRIPT_DIR}/../Aptfile"
if [ -f "$APTFILE" ]; then
    echo "Installing packages from Aptfile..."
    while IFS= read -r package || [ -n "$package" ]; do
        # Skip empty lines and comments
        [[ -z "$package" || "$package" =~ ^#.*$ ]] && continue
        echo "Installing $package..."
        apt-get update -qq && apt-get install -y -qq "$package" 2>/dev/null || echo "Warning: Failed to install $package"
    done < "$APTFILE"
    echo "Package installation complete"
fi

echo "Looking for backup files matching: ${BACKUP_PATTERN}*.tar.gz"

# Verify required commands are available
if ! command -v aws >/dev/null 2>&1; then
    echo "Error: AWS CLI not found. Installation may have failed."
    exit 1
fi
echo "AWS CLI ready"

if ! command -v mysql >/dev/null 2>&1; then
    echo "Error: MySQL client not found. Please ensure mysql-client is installed (via Aptfile on Scalingo)."
    exit 1
fi

# Check required environment variables
if [ -z "$SCALEWAY_ACCESS_KEY" ] || [ -z "$SCALEWAY_SECRET_KEY" ] || [ -z "$DATABASE_URL" ]; then
    echo "Error: Missing required environment variables"
    echo "Required: SCALEWAY_ACCESS_KEY, SCALEWAY_SECRET_KEY, DATABASE_URL (mysql://user:password@host:port/database)"
    echo "Optional: SCALEWAY_BUCKET (default: lucca-analytics), SCALEWAY_REGION (default: fr-par)"
    exit 1
fi

# Create temporary directory for download
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

echo "Created temporary directory: $TEMP_DIR"

# Configure AWS CLI for Scaleway S3
export AWS_ACCESS_KEY_ID=$SCALEWAY_ACCESS_KEY
export AWS_SECRET_ACCESS_KEY=$SCALEWAY_SECRET_KEY
export AWS_DEFAULT_REGION=$SCALEWAY_REGION

# Find the most recent backup file matching today's date
echo "Searching for backup files matching pattern..."
MATCHING_FILES=$(aws s3 ls "s3://${SCALEWAY_BUCKET}/" --endpoint-url=$SCALEWAY_ENDPOINT | grep "${BACKUP_PATTERN}" | grep "\.tar\.gz$" | sort -k4 -r)

if [ -z "$MATCHING_FILES" ]; then
    echo "Error: No backup files found matching pattern ${BACKUP_PATTERN}*.tar.gz"
    echo "Available backup files:"
    aws s3 ls "s3://${SCALEWAY_BUCKET}/" --endpoint-url=$SCALEWAY_ENDPOINT | grep "stats-backup-file"
    exit 1
fi

# Get the most recent file (first line after sorting by date descending)
BACKUP_FILENAME=$(echo "$MATCHING_FILES" | head -n1 | awk '{print $4}')
echo "Found most recent backup: ${BACKUP_FILENAME}"

# Download the backup file from Scaleway S3
echo "Downloading backup from Scaleway S3..."
if ! aws s3 cp "s3://${SCALEWAY_BUCKET}/${BACKUP_FILENAME}" "${TEMP_DIR}/${BACKUP_FILENAME}" --endpoint-url=$SCALEWAY_ENDPOINT; then
    echo "Error: Failed to download backup file ${BACKUP_FILENAME}"
    exit 1
fi

echo "Successfully downloaded: ${BACKUP_FILENAME}"

# Extract the tar.gz file
echo "Extracting backup file..."
cd $TEMP_DIR
tar -xzf $BACKUP_FILENAME

# Find the MySQL dump file (assuming it's the main .sql file in the archive)
MYSQL_DUMP_FILE=$(find . -name "*.sql" -type f | head -n1)

if [ -z "$MYSQL_DUMP_FILE" ]; then
    echo "Error: No MySQL dump file found in the backup archive"
    exit 1
fi

echo "Found MySQL dump file: $MYSQL_DUMP_FILE"

# Parse DATABASE_URL for MySQL connection
# Format: mysql://user:password@host:port/database?params
if [[ $DATABASE_URL =~ mysql://([^:]+):([^@]+)@([^:]+):([0-9]+)/([^?]+) ]]; then
    MYSQL_USER="${BASH_REMATCH[1]}"
    MYSQL_PASSWORD="${BASH_REMATCH[2]}"
    MYSQL_HOST="${BASH_REMATCH[3]}"
    MYSQL_PORT="${BASH_REMATCH[4]}"
    MYSQL_DATABASE="${BASH_REMATCH[5]}"

    echo "Cleaning MySQL dump for limited privileges..."
    CLEANED_DUMP_FILE="${TEMP_DIR}/cleaned_dump.sql"

    # Remove problematic statements that require SUPER privileges
    # More comprehensive cleaning for MySQL dumps
    sed -e 's/DEFINER=[^*]*\*/\*/g' \
        -e 's/DEFINER=[^[:space:]]*//g' \
        -e '/^SET @OLD_CHARACTER_SET_CLIENT/d' \
        -e '/^SET @OLD_CHARACTER_SET_RESULTS/d' \
        -e '/^SET @OLD_COLLATION_CONNECTION/d' \
        -e '/^SET character_set_client/d' \
        -e '/^SET @OLD_UNIQUE_CHECKS/d' \
        -e '/^SET @OLD_FOREIGN_KEY_CHECKS/d' \
        -e '/^SET @OLD_SQL_MODE/d' \
        -e '/^SET SQL_MODE/d' \
        -e '/^SET @OLD_TIME_ZONE/d' \
        -e '/^SET TIME_ZONE/d' \
        -e '/^SET @@session\./d' \
        -e '/^SET @@global\./d' \
        -e '/^SET GLOBAL /d' \
        -e '/^SET SESSION /d' \
        -e '/^SET sql_require_primary_key/d' \
        -e '/GTID_MODE/d' \
        -e '/MASTER_AUTO_POSITION/d' \
        -e '/SERVER_UUID/d' \
        -e '/GTID_PURGED/d' \
        -e '/GTID_EXECUTED/d' \
        -e '/^-- GTID state/d' \
        "$MYSQL_DUMP_FILE" > "$CLEANED_DUMP_FILE"

    # Test MySQL connection first
    echo "Testing MySQL connection..."
    if ! mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" -e "SELECT 1;" >/dev/null 2>&1; then
        echo "Error: Cannot connect to MySQL database"
        exit 1
    fi
    echo "MySQL connection successful"

    # Check size of cleaned dump
    DUMP_SIZE=$(wc -l < "$CLEANED_DUMP_FILE")
    echo "Cleaned dump has $DUMP_SIZE lines"

    echo "Cleaning existing database..."
    # Get list of all tables and drop them
    TABLES=$(mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" -N -e "SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE();")

    if [ -n "$TABLES" ]; then
        echo "Dropping existing tables..."
        mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" <<EOSQL
SET FOREIGN_KEY_CHECKS = 0;
$(echo "$TABLES" | while read -r table; do echo "DROP TABLE IF EXISTS \`$table\`;"; done)
SET FOREIGN_KEY_CHECKS = 1;
EOSQL
        echo "Existing database cleaned"
    else
        echo "No existing tables to drop"
    fi

    echo "Loading cleaned MySQL dump into database...: $CLEANED_DUMP_FILE"

    if mysql --connect-timeout=30 --max_allowed_packet=1073741824 -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" < "$CLEANED_DUMP_FILE" 2>/dev/null; then
        echo "✓ Database restoration completed successfully"
    else
        echo "Error: Database restoration failed"
        echo "Checking what might have caused the error..."
        # Try a smaller test to see what's wrong
        head -20 "$CLEANED_DUMP_FILE" > "${TEMP_DIR}/test_dump.sql"
        echo "Testing first 20 lines of dump..."
        mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p "$MYSQL_PASSWORD" "$MYSQL_DATABASE" < "${TEMP_DIR}/test_dump.sql" 2>&1 | head -5
        exit 1
    fi
else
    echo "Error: Invalid DATABASE_URL format. Expected: mysql://user:password@host:port/database"
    exit 1
fi

echo "Sync completed successfully!"
echo "Cleaned up temporary files"
