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

# -----------------------------------------------------------------------------
# LOGGING
# -----------------------------------------------------------------------------
log() {
    local level="$1"; shift
    local timestamp; timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    # Ensure log directory exists before writing so tee never fails under set -eo pipefail
    [[ -d "$LOG_DIR" ]] || mkdir -p "$LOG_DIR"
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
    free_kb="$(df -Pk "$BACKUP_DIR" 2>/dev/null | awk 'NR==2 {print $4}')"
    if [[ "$free_kb" =~ ^[0-9]+$ ]] && (( free_kb < 102400 )); then
        log "WARN" "Low disk space: ${free_kb}KB available in $BACKUP_DIR"
    fi
}

# -----------------------------------------------------------------------------
# CREATE BACKUP
# -----------------------------------------------------------------------------
create_backup() {
    log "INFO" "Starting backup — project: $PROJECT_ROOT"
    log "INFO" "Output: $BACKUP_PATH"

    local proj_base
    proj_base="$(basename "$PROJECT_ROOT")"

    # Build tar exclusions using relative paths so tar matches inside archive
    local exclude_patterns=(
        "--exclude=$proj_base/backups"
        "--exclude=backups"
        "--exclude=$proj_base/.git"
        "--exclude=.git"
        "--exclude=$proj_base/logs"
        "--exclude=logs"
        "--exclude=*.tmp"
        "--exclude=*.swp"
        "--exclude=.DS_Store"
    )

    local tar_err=""
    if ! tar_err="$(tar -czf "$BACKUP_PATH" \
        "${exclude_patterns[@]}" \
        -C "$(dirname "$PROJECT_ROOT")" \
        "$proj_base" 2>&1)"; then
        log "ERROR" "tar command failed: $tar_err"
        [[ -f "$BACKUP_PATH" ]] && rm -f "$BACKUP_PATH"
        exit 1
    fi

    # Verify archive exists and is non-empty
    if [[ ! -s "$BACKUP_PATH" ]]; then
        log "ERROR" "Backup file is empty: $BACKUP_PATH"
        rm -f "$BACKUP_PATH"
        exit 1
    fi

    # Verify archive integrity
    if ! tar -tzf "$BACKUP_PATH" &>/dev/null; then
        log "ERROR" "Backup archive integrity check failed: $BACKUP_PATH"
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
    backup_count="$(find "$BACKUP_DIR" -maxdepth 1 -name "${PROJECT_NAME}_*.tar.gz" 2>/dev/null | wc -l)"

    if (( backup_count > KEEP_BACKUPS )); then
        local delete_count=$(( backup_count - KEEP_BACKUPS ))
        log "INFO" "Removing $delete_count old backup(s)"

        find "$BACKUP_DIR" -maxdepth 1 -name "${PROJECT_NAME}_*.tar.gz" 2>/dev/null \
            | sort \
            | head -n "$delete_count" \
            | while IFS= read -r old_backup; do
                if [[ -f "$old_backup" ]]; then
                    rm -f "$old_backup"
                    log "INFO" "Removed: $(basename "$old_backup")"
                fi
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
    local found=0
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        found=1
        local size; size="$(du -sh "$f" 2>/dev/null | awk '{print $1}')"
        log "INFO" "  $(basename "$f") [$size]"
    done < <(find "$BACKUP_DIR" -maxdepth 1 -name "${PROJECT_NAME}_*.tar.gz" 2>/dev/null | sort -r)

    if (( found == 0 )); then
        log "INFO" "  (none)"
    fi
    log "INFO" "--------------------------------------"
}

# -----------------------------------------------------------------------------
# MAIN
# -----------------------------------------------------------------------------
main() {
    # Ensure log directory exists before any logging occurs
    [[ -d "$LOG_DIR" ]] || mkdir -p "$LOG_DIR"

    log "INFO" "=== backup.sh started ==="

    preflight_check
    create_backup
    rotate_backups
    print_report

    log "INFO" "=== backup.sh completed successfully ==="
    exit 0
}

main "$@"
