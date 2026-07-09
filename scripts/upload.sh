#!/bin/bash
# =============================================================================
# upload.sh — CloudOps Monitor S3 Upload Script
# =============================================================================
# Purpose  : Upload the latest local backup to an S3 bucket using AWS CLI.
#            Verifies upload success and retries on transient failures.
# Usage    : ./upload.sh
# Prereqs  : AWS CLI installed, IAM role or ~/.aws/credentials configured
#
# Author   : Shreenath Mehta
# Project  : CloudOps Monitor | AWS EC2 · Ubuntu 24.04 · Nginx
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# CONFIGURATION — update S3_BUCKET before first use
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="$PROJECT_ROOT/backups"
LOG_DIR="$PROJECT_ROOT/logs"
LOG_FILE="$LOG_DIR/upload.log"
PROJECT_NAME="cloudops-monitor"

# S3 destination — override with your actual bucket name
S3_BUCKET="${CLOUDOPS_S3_BUCKET:-your-s3-bucket-name}"
S3_PREFIX="cloudops-monitor/backups"   # Key prefix (folder) inside bucket
S3_STORAGE_CLASS="STANDARD_IA"        # Cost-optimised for infrequent access

MAX_RETRIES=3           # Number of upload retry attempts
RETRY_DELAY=10          # Seconds between retry attempts

# -----------------------------------------------------------------------------
# LOGGING
# -----------------------------------------------------------------------------
log() {
    local level="$1"; shift
    local timestamp; timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$timestamp] [$level] $*" | tee -a "$LOG_FILE"
}

# -----------------------------------------------------------------------------
# PRE-FLIGHT CHECKS
# -----------------------------------------------------------------------------
preflight_check() {
    mkdir -p "$LOG_DIR"

    # Validate AWS CLI is installed
    if ! command -v aws &>/dev/null; then
        log "ERROR" "AWS CLI not found. Install: sudo apt-get install awscli"
        exit 1
    fi

    # Validate S3 bucket is configured
    if [[ "$S3_BUCKET" == "your-s3-bucket-name" ]]; then
        log "ERROR" "S3_BUCKET not configured. Set CLOUDOPS_S3_BUCKET env var or edit upload.sh"
        exit 1
    fi

    # Validate AWS credentials are available
    if ! aws sts get-caller-identity &>/dev/null; then
        log "ERROR" "AWS credentials not configured or invalid. Check IAM role/~/.aws/credentials"
        exit 1
    fi

    log "INFO" "AWS CLI ready. Bucket: s3://$S3_BUCKET/$S3_PREFIX/"
}

# -----------------------------------------------------------------------------
# FIND LATEST BACKUP
# -----------------------------------------------------------------------------
find_latest_backup() {
    local latest
    latest="$(find "$BACKUP_DIR" -maxdepth 1 -name "${PROJECT_NAME}_*.tar.gz" \
        | sort -r \
        | head -n 1)"

    if [[ -z "$latest" ]]; then
        log "ERROR" "No backup files found in $BACKUP_DIR. Run backup.sh first."
        exit 1
    fi

    echo "$latest"
}

# -----------------------------------------------------------------------------
# UPLOAD WITH RETRY
# -----------------------------------------------------------------------------
upload_to_s3() {
    local local_file="$1"
    local filename; filename="$(basename "$local_file")"
    local s3_key="s3://$S3_BUCKET/$S3_PREFIX/$filename"
    local attempt=0
    local success=false

    local file_size
    file_size="$(du -sh "$local_file" | awk '{print $1}')"

    log "INFO" "Uploading: $filename ($file_size) → $s3_key"

    while (( attempt < MAX_RETRIES )); do
        attempt=$(( attempt + 1 ))
        log "INFO" "Upload attempt $attempt of $MAX_RETRIES..."

        if aws s3 cp "$local_file" "$s3_key" \
            --storage-class "$S3_STORAGE_CLASS" \
            --no-progress \
            2>>"$LOG_FILE"; then
            success=true
            break
        else
            log "WARN" "Upload attempt $attempt failed"
            if (( attempt < MAX_RETRIES )); then
                log "INFO" "Retrying in ${RETRY_DELAY}s..."
                sleep "$RETRY_DELAY"
            fi
        fi
    done

    if [[ "$success" != "true" ]]; then
        log "ERROR" "All $MAX_RETRIES upload attempts failed for: $filename"
        exit 1
    fi

    log "INFO" "Upload succeeded on attempt $attempt"
    echo "$s3_key"
}

# -----------------------------------------------------------------------------
# VERIFY UPLOAD
# Confirms the file exists in S3 and sizes match.
# -----------------------------------------------------------------------------
verify_upload() {
    local local_file="$1"
    local s3_key="$2"

    log "INFO" "Verifying upload..."

    # Check file exists in S3
    if ! aws s3 ls "$s3_key" &>/dev/null; then
        log "ERROR" "Verification failed — file not found in S3: $s3_key"
        exit 1
    fi

    # Compare sizes
    local local_size; local_size="$(stat -c%s "$local_file" 2>/dev/null || stat -f%z "$local_file" 2>/dev/null)"
    local s3_size;    s3_size="$(aws s3api head-object --bucket "$S3_BUCKET" --key "${s3_key#s3://$S3_BUCKET/}" --query ContentLength --output text 2>/dev/null)"

    if [[ "$local_size" == "$s3_size" ]]; then
        log "INFO" "Verification passed — sizes match (${local_size} bytes)"
    else
        log "WARN" "Size mismatch: local=${local_size}B, s3=${s3_size}B — manual check recommended"
    fi
}

# -----------------------------------------------------------------------------
# LIST S3 BACKUPS
# Shows what's currently stored in the bucket.
# -----------------------------------------------------------------------------
list_s3_backups() {
    log "INFO" "--- S3 backups at s3://$S3_BUCKET/$S3_PREFIX/ ---"
    aws s3 ls "s3://$S3_BUCKET/$S3_PREFIX/" 2>/dev/null | tail -10 | while read -r line; do
        log "INFO" "  $line"
    done
    log "INFO" "------------------------------------------------"
}

# -----------------------------------------------------------------------------
# MAIN
# -----------------------------------------------------------------------------
main() {
    log "INFO" "=== upload.sh started ==="

    preflight_check

    local latest_backup
    latest_backup="$(find_latest_backup)"
    log "INFO" "Latest backup: $(basename "$latest_backup")"

    local s3_key
    s3_key="$(upload_to_s3 "$latest_backup")"

    verify_upload "$latest_backup" "$s3_key"
    list_s3_backups

    log "INFO" "=== upload.sh completed successfully ==="
    exit 0
}

main "$@"
