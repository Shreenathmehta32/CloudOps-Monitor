#!/bin/bash
# =============================================================================
# backup.sh — CloudOps Monitor Project Backup Script
# =============================================================================
# Purpose  : Compress the project directory with a timestamp, store in backups/
# Usage    : ./backup.sh
# Schedule : Run via cron daily (see cron_setup.sh)
#
# Author   : Shreenath Mehta
# Project  : CloudOps Monitor | AWS EC2 · Ubuntu 24.04 · Nginx
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# CONFIGURATION
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="$PROJECT_ROOT/backups"
LOG_DIR="$PROJECT_ROOT/logs"
LOG_FILE="$LOG_DIR/backup.log"
PROJECT_NAME="cloudops-monitor"
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
BACKUP_FILENAME="${PROJECT_NAME}_${TIMESTAMP}.tar.gz"
BACKUP_PATH="$BACKUP_DIR/$BACKUP_FILENAME"
KEEP_BACKUPS=7   # Number of recent backups to retain

# Directories/files to EXCLUDE from backup
EXCLUDE_PATTERNS=(
    "--exclude=$BACKUP_DIR"
    "--exclude=$PROJECT_ROOT/.git"
    "--exclude=$LOG_DIR"
    "--exclude=*.tmp"
    "--exclude=*.swp"
)

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
    # Ensure backup and log directories exist
    mkdir -p "$BACKUP_DIR" "$LOG_DIR"

    # Validate required commands
    if ! command -v tar &>/dev/null; then
        log "ERROR" "tar is not installed — cannot create backup"
        exit 1
    fi

    if ! command -v gzip &>/dev/null; then
        log "ERROR" "gzip is not installed — cannot compress backup"
        exit 1
    fi

    # Verify project root exists
    if [[ ! -d "$PROJECT_ROOT" ]]; then
        log "ERROR" "Project root not found: $PROJECT_ROOT"
        exit 1
    fi

    # Check available disk space (require at least 100MB free)
    local free_kb
    free_kb="$(df -k "$BACKUP_DIR" | awk 'NR==2 {print $4}')"
    if (( free_kb < 102400 )); then
        log "WARN" "Low disk space: ${free_kb}KB available in $BACKUP_DIR"
    fi
}

# -----------------------------------------------------------------------------
# CREATE BACKUP
# -----------------------------------------------------------------------------
create_backup() {
    log "INFO" "Starting backup — project: $PROJECT_ROOT"
    log "INFO" "Output: $BACKUP_PATH"

    # Build tar command with all exclusions
    tar -czf "$BACKUP_PATH" \
        "${EXCLUDE_PATTERNS[@]}" \
        -C "$(dirname "$PROJECT_ROOT")" \
        "$(basename "$PROJECT_ROOT")" \
        2>/dev/null

    if [[ $? -ne 0 ]]; then
        log "ERROR" "tar command failed — backup may be incomplete"
        [[ -f "$BACKUP_PATH" ]] && rm -f "$BACKUP_PATH"
        exit 1
    fi

    # Verify archive is readable and non-empty
    if [[ ! -s "$BACKUP_PATH" ]]; then
        log "ERROR" "Backup file is empty: $BACKUP_PATH"
        rm -f "$BACKUP_PATH"
        exit 1
    fi

    local size_kb
    size_kb="$(du -k "$BACKUP_PATH" | awk '{print $1}')"
    log "INFO" "Backup created successfully: $BACKUP_FILENAME (${size_kb}KB)"
}

# -----------------------------------------------------------------------------
# ROTATE OLD BACKUPS
# Keeps only the N most recent backup files.
# -----------------------------------------------------------------------------
rotate_backups() {
    log "INFO" "Rotating old backups — keeping last $KEEP_BACKUPS"

    # List backups sorted by modification time (oldest first)
    local backup_count
    backup_count="$(find "$BACKUP_DIR" -maxdepth 1 -name "${PROJECT_NAME}_*.tar.gz" | wc -l)"

    if (( backup_count > KEEP_BACKUPS )); then
        local delete_count=$(( backup_count - KEEP_BACKUPS ))
        log "INFO" "Removing $delete_count old backup(s)"

        find "$BACKUP_DIR" -maxdepth 1 -name "${PROJECT_NAME}_*.tar.gz" \
            | sort \
            | head -n "$delete_count" \
            | while read -r old_backup; do
                rm -f "$old_backup"
                log "INFO" "Removed: $(basename "$old_backup")"
            done
    else
        log "INFO" "No rotation needed ($backup_count/$KEEP_BACKUPS slots used)"
    fi
}

# -----------------------------------------------------------------------------
# REPORT
# Print a summary of all current backups
# -----------------------------------------------------------------------------
print_report() {
    log "INFO" "--- Current backups in $BACKUP_DIR ---"
    find "$BACKUP_DIR" -maxdepth 1 -name "${PROJECT_NAME}_*.tar.gz" \
        | sort -r \
        | while read -r f; do
            local size; size="$(du -sh "$f" | awk '{print $1}')"
            log "INFO" "  $(basename "$f") [$size]"
        done
    log "INFO" "--------------------------------------"
}

# -----------------------------------------------------------------------------
# MAIN
# -----------------------------------------------------------------------------
main() {
    log "INFO" "=== backup.sh started ==="

    preflight_check
    create_backup
    rotate_backups
    print_report

    log "INFO" "=== backup.sh completed successfully ==="
    exit 0
}

main "$@"
