#!/bin/bash
# =============================================================================
# cleanup.sh — CloudOps Monitor File Cleanup Script
# =============================================================================
# Purpose  : Safely remove old backup archives and log files to prevent
#            disk exhaustion. Uses find with -mtime for safe deletion.
# Usage    : ./cleanup.sh
# Schedule : Run via cron daily at 02:00 (see cron_setup.sh)
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
LOG_FILE="$LOG_DIR/cleanup.log"

BACKUP_RETENTION_DAYS=7    # Delete backups older than N days
LOG_RETENTION_DAYS=30      # Delete log files older than N days
MIN_BACKUPS_TO_KEEP=2      # ALWAYS keep at least this many backups regardless of age
DRY_RUN=false              # Set to true to preview without deleting

# -----------------------------------------------------------------------------
# LOGGING
# -----------------------------------------------------------------------------
log() {
    local level="$1"; shift
    local timestamp; timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$timestamp] [$level] $*" | tee -a "$LOG_FILE"
}

# -----------------------------------------------------------------------------
# PRE-FLIGHT
# -----------------------------------------------------------------------------
preflight_check() {
    mkdir -p "$LOG_DIR"

    # Validate required commands
    if ! command -v find &>/dev/null; then
        log "ERROR" "find command not available"
        exit 1
    fi

    log "INFO" "Dry run: $DRY_RUN"
    log "INFO" "Backup retention: ${BACKUP_RETENTION_DAYS} days (min keep: ${MIN_BACKUPS_TO_KEEP})"
    log "INFO" "Log retention:    ${LOG_RETENTION_DAYS} days"
}

# -----------------------------------------------------------------------------
# COUNT FILES BEFORE CLEANUP (for summary)
# -----------------------------------------------------------------------------
count_files() {
    local dir="$1"
    local pattern="$2"
    find "$dir" -maxdepth 1 -name "$pattern" 2>/dev/null | wc -l
}

# -----------------------------------------------------------------------------
# CLEAN BACKUPS
# Removes .tar.gz backups older than BACKUP_RETENTION_DAYS.
# Preserves at least MIN_BACKUPS_TO_KEEP most recent backups.
# -----------------------------------------------------------------------------
clean_backups() {
    log "INFO" "=== Cleaning backups in $BACKUP_DIR ==="

    if [[ ! -d "$BACKUP_DIR" ]]; then
        log "INFO" "Backup directory does not exist — skipping"
        return
    fi

    local before_count
    before_count="$(count_files "$BACKUP_DIR" "*.tar.gz")"
    log "INFO" "Backups before cleanup: $before_count"

    if (( before_count <= MIN_BACKUPS_TO_KEEP )); then
        log "INFO" "Only $before_count backup(s) found — at or below minimum ($MIN_BACKUPS_TO_KEEP). Skipping cleanup."
        return
    fi

    # Find files older than N days, sorted oldest-first
    local old_backups
    old_backups="$(find "$BACKUP_DIR" -maxdepth 1 -name "*.tar.gz" \
        -mtime "+${BACKUP_RETENTION_DAYS}" \
        | sort 2>/dev/null)" || old_backups=""

    if [[ -z "$old_backups" ]]; then
        log "INFO" "No backups older than ${BACKUP_RETENTION_DAYS} days found"
        return
    fi

    # Safety: ensure we keep at least MIN_BACKUPS_TO_KEEP files
    local total_backups
    total_backups="$(find "$BACKUP_DIR" -maxdepth 1 -name "*.tar.gz" | wc -l)"
    local old_count
    old_count="$(echo "$old_backups" | grep -c . || true)"
    local safe_delete=$(( total_backups - MIN_BACKUPS_TO_KEEP ))

    if (( safe_delete <= 0 )); then
        log "INFO" "Skipping deletion — would drop below minimum $MIN_BACKUPS_TO_KEEP backups"
        return
    fi

    # Only delete up to safe_delete files
    local deleted=0
    while IFS= read -r backup_file; do
        if [[ -z "$backup_file" ]]; then continue; fi
        if (( deleted >= safe_delete )); then
            log "INFO" "Minimum backup count reached — stopping deletion"
            break
        fi

        if [[ "$DRY_RUN" == "true" ]]; then
            log "INFO" "[DRY RUN] Would delete: $(basename "$backup_file")"
        else
            rm -f "$backup_file"
            log "INFO" "Deleted backup: $(basename "$backup_file")"
        fi
        (( deleted++ ))
    done <<< "$old_backups"

    local after_count
    after_count="$(count_files "$BACKUP_DIR" "*.tar.gz")"
    log "INFO" "Backups after cleanup: $after_count (removed: $deleted)"
}

# -----------------------------------------------------------------------------
# CLEAN LOGS
# Removes .log files older than LOG_RETENTION_DAYS (but keeps cleanup.log).
# -----------------------------------------------------------------------------
clean_logs() {
    log "INFO" "=== Cleaning logs in $LOG_DIR ==="

    if [[ ! -d "$LOG_DIR" ]]; then
        log "INFO" "Log directory does not exist — skipping"
        return
    fi

    local before_count
    before_count="$(count_files "$LOG_DIR" "*.log")"
    log "INFO" "Log files before cleanup: $before_count"

    local deleted=0

    # Find .log files older than retention period
    while IFS= read -r log_file; do
        if [[ -z "$log_file" ]]; then continue; fi

        # Never delete the current cleanup.log itself
        if [[ "$(basename "$log_file")" == "cleanup.log" ]]; then
            continue
        fi

        if [[ "$DRY_RUN" == "true" ]]; then
            log "INFO" "[DRY RUN] Would delete log: $(basename "$log_file")"
        else
            rm -f "$log_file"
            log "INFO" "Deleted log: $(basename "$log_file")"
        fi
        (( deleted++ ))
    done < <(find "$LOG_DIR" -maxdepth 1 -name "*.log" \
        -mtime "+${LOG_RETENTION_DAYS}" 2>/dev/null | sort)

    if (( deleted == 0 )); then
        log "INFO" "No log files older than ${LOG_RETENTION_DAYS} days found"
    else
        log "INFO" "Removed $deleted old log file(s)"
    fi
}

# -----------------------------------------------------------------------------
# CLEAN TEMP FILES
# Remove any .tmp files left by interrupted monitor.sh runs.
# -----------------------------------------------------------------------------
clean_temp_files() {
    log "INFO" "=== Cleaning temporary files ==="

    local tmp_count=0

    while IFS= read -r tmp_file; do
        if [[ -z "$tmp_file" ]]; then continue; fi

        if [[ "$DRY_RUN" == "true" ]]; then
            log "INFO" "[DRY RUN] Would delete temp: $tmp_file"
        else
            rm -f "$tmp_file"
            log "INFO" "Deleted temp file: $tmp_file"
        fi
        (( tmp_count++ ))
    done < <(find "$PROJECT_ROOT" -maxdepth 3 -name "*.tmp" 2>/dev/null)

    if (( tmp_count == 0 )); then
        log "INFO" "No temp files found"
    fi
}

# -----------------------------------------------------------------------------
# DISK USAGE REPORT (after cleanup)
# -----------------------------------------------------------------------------
disk_report() {
    log "INFO" "=== Post-cleanup disk usage ==="

    local dirs=("$BACKUP_DIR" "$LOG_DIR")
    for dir in "${dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            local size; size="$(du -sh "$dir" 2>/dev/null | awk '{print $1}')"
            log "INFO" "  $dir : $size"
        fi
    done

    local root_usage; root_usage="$(df -h / | awk 'NR==2 {printf "%s used of %s (%s)", $3, $2, $5}')"
    log "INFO" "  Root filesystem: $root_usage"
}

# -----------------------------------------------------------------------------
# MAIN
# -----------------------------------------------------------------------------
main() {
    # Allow --dry-run flag
    if [[ "${1:-}" == "--dry-run" ]]; then
        DRY_RUN=true
        log "INFO" "*** DRY RUN MODE — no files will be deleted ***"
    fi

    log "INFO" "=== cleanup.sh started ==="

    preflight_check
    clean_backups
    clean_logs
    clean_temp_files
    disk_report

    log "INFO" "=== cleanup.sh completed successfully ==="
    exit 0
}

main "$@"
