#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Enhanced logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
}

# Configuration from environment variables
SCALEWAY_BUCKET="${SCALEWAY_BUCKET:-lucca-analytics}"
SCALEWAY_REGION="${SCALEWAY_REGION:-fr-par}"
SCALEWAY_ENDPOINT="https://s3.${SCALEWAY_REGION}.scw.cloud"

# Store the script directory path
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Get today's date for filename pattern
TODAY_DATE=$(date '+%Y-%m-%d')
BACKUP_PATTERN="stats-backup-file-${TODAY_DATE}"

log "=========================================="
log "Starting Scaleway S3 to MySQL sync"
log "=========================================="
log "Bucket: ${SCALEWAY_BUCKET}"
log "Region: ${SCALEWAY_REGION}"
log "Endpoint: ${SCALEWAY_ENDPOINT}"
log "Date pattern: ${BACKUP_PATTERN}"
log "Current working directory: $(pwd)"
log "Script directory: ${SCRIPT_DIR}"

# Verify required commands are available
log "Checking for required tools..."

log "Checking PATH: $PATH"

if ! command -v aws >/dev/null 2>&1; then
    log_error "AWS CLI is not available"
    log_error "AWS CLI should be installed via the dedicated buildpack"
    log_error "Verify that .buildpacks includes: https://github.com/studoverse/scalingo-buildpack-awscli.git"
    log_error "If you just added the buildpack, you need to redeploy the app"
    log_error "Run: git push scalingo main"
    exit 1
fi

AWS_CLI_VERSION=$(aws --version 2>&1)
log "AWS CLI ready: ${AWS_CLI_VERSION}"

if ! command -v mysql >/dev/null 2>&1; then
    log_error "MySQL client not found"
    log_error "Verify that Aptfile includes: mysql-client"
    log_error "If you just added it, you need to redeploy the app"
    log_error "Run: git push scalingo main"
    exit 1
fi

MYSQL_VERSION=$(mysql --version 2>&1)
log "MySQL client ready: ${MYSQL_VERSION}"

log "Looking for backup files matching: ${BACKUP_PATTERN}*.tar.gz"

# Check required environment variables
log "Checking required environment variables..."
if [ -z "$SCALEWAY_ACCESS_KEY" ]; then
    log_error "SCALEWAY_ACCESS_KEY is not set"
    exit 1
fi
if [ -z "$SCALEWAY_SECRET_KEY" ]; then
    log_error "SCALEWAY_SECRET_KEY is not set"
    exit 1
fi
if [ -z "$DATABASE_URL" ]; then
    log_error "DATABASE_URL is not set"
    log_error "Expected format: mysql://user:password@host:port/database"
    exit 1
fi
log "All required environment variables are set"

# Create temporary directory for download
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

log "Created temporary directory: $TEMP_DIR"

# Configure AWS CLI for Scaleway S3
log "Configuring AWS CLI for Scaleway S3..."
export AWS_ACCESS_KEY_ID=$SCALEWAY_ACCESS_KEY
export AWS_SECRET_ACCESS_KEY=$SCALEWAY_SECRET_KEY
export AWS_DEFAULT_REGION=$SCALEWAY_REGION
log "AWS CLI configured"

# Find the most recent backup file matching today's date
log "Searching for backup files matching pattern: ${BACKUP_PATTERN}*.tar.gz"
log "Connecting to S3 bucket: s3://${SCALEWAY_BUCKET}/"

MATCHING_FILES=$(aws s3 ls "s3://${SCALEWAY_BUCKET}/" --endpoint-url=$SCALEWAY_ENDPOINT 2>&1 | grep "${BACKUP_PATTERN}" | grep "\.tar\.gz$" | sort -k4 -r)

if [ -z "$MATCHING_FILES" ]; then
    log_error "No backup files found matching pattern ${BACKUP_PATTERN}*.tar.gz"
    log "Available backup files in bucket:"
    aws s3 ls "s3://${SCALEWAY_BUCKET}/" --endpoint-url=$SCALEWAY_ENDPOINT 2>&1 | grep "stats-backup-file" | head -10
    exit 1
fi

# Get the most recent file (first line after sorting by date descending)
BACKUP_FILENAME=$(echo "$MATCHING_FILES" | head -n1 | awk '{print $4}')
log "Found most recent backup: ${BACKUP_FILENAME}"

# Show file size from S3 listing
FILE_SIZE=$(echo "$MATCHING_FILES" | head -n1 | awk '{print $3}')
log "Backup file size: ${FILE_SIZE} bytes"

# Download the backup file from Scaleway S3
log "Downloading backup from Scaleway S3: ${BACKUP_FILENAME}"
log "Download destination: ${TEMP_DIR}/${BACKUP_FILENAME}"

if ! aws s3 cp "s3://${SCALEWAY_BUCKET}/${BACKUP_FILENAME}" "${TEMP_DIR}/${BACKUP_FILENAME}" --endpoint-url=$SCALEWAY_ENDPOINT 2>&1; then
    log_error "Failed to download backup file ${BACKUP_FILENAME}"
    exit 1
fi

# Verify downloaded file
DOWNLOADED_SIZE=$(ls -lh "${TEMP_DIR}/${BACKUP_FILENAME}" | awk '{print $5}')
log "Successfully downloaded: ${BACKUP_FILENAME} (${DOWNLOADED_SIZE})"

# Extract the tar.gz file
log "Extracting backup file..."
cd $TEMP_DIR
if ! tar -xzf $BACKUP_FILENAME 2>&1; then
    log_error "Failed to extract backup file"
    exit 1
fi
log "Extraction completed"

# Find the MySQL dump file (assuming it's the main .sql file in the archive)
log "Looking for MySQL dump file in extracted archive..."
MYSQL_DUMP_FILE=$(find . -name "*.sql" -type f | head -n1)

if [ -z "$MYSQL_DUMP_FILE" ]; then
    log_error "No MySQL dump file found in the backup archive"
    log "Contents of extracted archive:"
    ls -la
    exit 1
fi

DUMP_FILE_SIZE=$(ls -lh "$MYSQL_DUMP_FILE" | awk '{print $5}')
log "Found MySQL dump file: $MYSQL_DUMP_FILE (${DUMP_FILE_SIZE})"

# Parse DATABASE_URL for MySQL connection
# Format: mysql://user:password@host:port/database?params
log "Parsing DATABASE_URL..."
if [[ $DATABASE_URL =~ mysql://([^:]+):([^@]+)@([^:]+):([0-9]+)/([^?]+) ]]; then
    MYSQL_USER="${BASH_REMATCH[1]}"
    MYSQL_PASSWORD="${BASH_REMATCH[2]}"
    MYSQL_HOST="${BASH_REMATCH[3]}"
    MYSQL_PORT="${BASH_REMATCH[4]}"
    MYSQL_DATABASE="${BASH_REMATCH[5]}"

    log "MySQL connection details:"
    log "  Host: ${MYSQL_HOST}"
    log "  Port: ${MYSQL_PORT}"
    log "  Database: ${MYSQL_DATABASE}"
    log "  User: ${MYSQL_USER}"

    log "Cleaning MySQL dump for limited privileges..."
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

    # Check size of cleaned dump
    DUMP_SIZE=$(wc -l < "$CLEANED_DUMP_FILE")
    CLEANED_SIZE=$(ls -lh "$CLEANED_DUMP_FILE" | awk '{print $5}')
    log "Cleaned dump has $DUMP_SIZE lines (${CLEANED_SIZE})"

    # Test MySQL connection first
    log "Testing MySQL connection to ${MYSQL_HOST}:${MYSQL_PORT}..."
    if ! mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" -e "SELECT 1;" >/dev/null 2>&1; then
        log_error "Cannot connect to MySQL database"
        log_error "Host: ${MYSQL_HOST}:${MYSQL_PORT}"
        log_error "Database: ${MYSQL_DATABASE}"
        exit 1
    fi
    log "MySQL connection successful"

    log "Cleaning existing database..."
    # Get list of all tables and drop them
    # Suppress password warning by redirecting stderr to /dev/null for this operation
    TABLES=$(mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" -N -e "SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE();" 2>/dev/null)

    if [ -n "$TABLES" ]; then
        TABLE_COUNT=$(echo "$TABLES" | wc -l | tr -d ' ')
        log "Dropping ${TABLE_COUNT} existing tables..."
        mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" <<EOSQL
SET FOREIGN_KEY_CHECKS = 0;
$(echo "$TABLES" | while read -r table; do echo "DROP TABLE IF EXISTS \`$table\`;"; done)
SET FOREIGN_KEY_CHECKS = 1;
EOSQL
        log "Existing database cleaned (${TABLE_COUNT} tables dropped)"
    else
        log "No existing tables to drop"
    fi

    log "Loading cleaned MySQL dump into database..."
    log "Source file: $CLEANED_DUMP_FILE"
    START_TIME=$(date +%s)

    if mysql --connect-timeout=30 --max_allowed_packet=1073741824 -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" < "$CLEANED_DUMP_FILE" 2>&1; then
        END_TIME=$(date +%s)
        DURATION=$((END_TIME - START_TIME))
        log "Database restoration completed successfully in ${DURATION} seconds"

        # Count imported tables
        NEW_TABLE_COUNT=$(mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE();" 2>/dev/null)
        log "Successfully imported ${NEW_TABLE_COUNT} tables"
    else
        log_error "Database restoration failed"
        log "Attempting to diagnose the issue..."
        # Try a smaller test to see what's wrong
        head -20 "$CLEANED_DUMP_FILE" > "${TEMP_DIR}/test_dump.sql"
        log "Testing first 20 lines of dump..."
        mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p "$MYSQL_PASSWORD" "$MYSQL_DATABASE" < "${TEMP_DIR}/test_dump.sql" 2>&1 | head -10
        exit 1
    fi
else
    log_error "Invalid DATABASE_URL format"
    log_error "Expected: mysql://user:password@host:port/database"
    log_error "Received: ${DATABASE_URL:0:20}... (truncated for security)"
    exit 1
fi

log "=========================================="
log "Sync completed successfully!"
log "=========================================="
log "Temporary files cleaned up"
