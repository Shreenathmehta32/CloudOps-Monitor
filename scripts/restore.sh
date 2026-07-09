#!/bin/bash
# =============================================================================
# restore.sh — CloudOps Monitor Backup Restore Script
# =============================================================================
# Purpose  : Safely restore the latest (or specified) backup archive.
#            Creates a rollback copy of current state before restoring.
# Usage    : ./restore.sh [backup_filename.tar.gz]
#            Without argument: restores the most recent backup.
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
LOG_FILE="$LOG_DIR/restore.log"
PROJECT_NAME="cloudops-monitor"

# Where to extract: the parent of PROJECT_ROOT
EXTRACT_TARGET="$(dirname "$PROJECT_ROOT")"
# Rollback snapshot path (created before restore)
ROLLBACK_DIR="$BACKUP_DIR/rollback"

# -----------------------------------------------------------------------------
# LOGGING
# -----------------------------------------------------------------------------
log() {
    local level="$1"; shift
    local timestamp; timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$timestamp] [$level] $*" | tee -a "$LOG_FILE"
}

print_header() {
    echo "============================================"
    echo "  CloudOps Monitor — Restore"
    echo "  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "============================================"
}

# -----------------------------------------------------------------------------
# PRE-FLIGHT
# -----------------------------------------------------------------------------
preflight_check() {
    mkdir -p "$LOG_DIR" "$ROLLBACK_DIR"

    if ! command -v tar &>/dev/null; then
        log "ERROR" "tar not found — cannot restore"
        exit 1
    fi

    if [[ ! -d "$BACKUP_DIR" ]]; then
        log "ERROR" "Backup directory not found: $BACKUP_DIR"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# LIST AVAILABLE BACKUPS
# -----------------------------------------------------------------------------
list_backups() {
    echo ""
    echo "Available backups (newest first):"
    echo "-----------------------------------"

    local count=0
    while IFS= read -r f; do
        count=$(( count + 1 ))
        local size; size="$(du -sh "$f" 2>/dev/null | awk '{print $1}')"
        local date_str; date_str="$(stat -c '%y' "$f" 2>/dev/null | cut -d'.' -f1)"
        printf "  [%d] %-50s %s  %s\n" "$count" "$(basename "$f")" "$size" "$date_str"
    done < <(find "$BACKUP_DIR" -maxdepth 1 -name "${PROJECT_NAME}_*.tar.gz" | sort -r)

    if (( count == 0 )); then
        echo "  (no backups found)"
    fi

    echo "-----------------------------------"
    echo ""
}

# -----------------------------------------------------------------------------
# FIND BACKUP TO RESTORE
# If argument provided: use that file. Otherwise: use the latest.
# -----------------------------------------------------------------------------
find_backup() {
    local requested="${1:-}"

    if [[ -n "$requested" ]]; then
        # User specified a filename
        local specified="$BACKUP_DIR/$requested"
        if [[ ! -f "$specified" ]]; then
            # Try as absolute path
            if [[ -f "$requested" ]]; then
                echo "$requested"
                return
            fi
            log "ERROR" "Specified backup not found: $specified"
            list_backups
            exit 1
        fi
        echo "$specified"
    else
        # Auto-select latest
        local latest
        latest="$(find "$BACKUP_DIR" -maxdepth 1 -name "${PROJECT_NAME}_*.tar.gz" \
            | sort -r \
            | head -n 1)"

        if [[ -z "$latest" ]]; then
            log "ERROR" "No backups found in $BACKUP_DIR"
            exit 1
        fi

        echo "$latest"
    fi
}

# -----------------------------------------------------------------------------
# CONFIRM WITH USER
# Interactive prompt before destructive restore.
# -----------------------------------------------------------------------------
confirm_restore() {
    local backup_file="$1"

    echo ""
    echo "  Backup to restore: $(basename "$backup_file")"
    echo "  Restore target:    $EXTRACT_TARGET"
    echo "  Rollback save:     $ROLLBACK_DIR"
    echo ""
    echo "  WARNING: This will OVERWRITE the current project files."
    echo "  A rollback snapshot will be saved first."
    echo ""
    read -r -p "  Are you sure? Type 'yes' to continue: " confirm

    if [[ "$confirm" != "yes" ]]; then
        echo ""
        echo "  Restore cancelled."
        log "INFO" "Restore cancelled by user"
        exit 0
    fi
}

# -----------------------------------------------------------------------------
# CREATE ROLLBACK SNAPSHOT
# Saves the current project state before overwriting.
# -----------------------------------------------------------------------------
create_rollback() {
    local rollback_ts; rollback_ts="$(date '+%Y%m%d_%H%M%S')"
    local rollback_file="$ROLLBACK_DIR/rollback_${rollback_ts}.tar.gz"

    log "INFO" "Creating rollback snapshot: $rollback_file"

    tar -czf "$rollback_file" \
        --exclude="$BACKUP_DIR" \
        --exclude="$PROJECT_ROOT/.git" \
        -C "$EXTRACT_TARGET" \
        "$(basename "$PROJECT_ROOT")" \
        2>/dev/null || true  # Don't fail if some files are missing

    if [[ -f "$rollback_file" ]]; then
        log "INFO" "Rollback saved: $(basename "$rollback_file")"
    else
        log "WARN" "Rollback creation may have failed — check $ROLLBACK_DIR"
    fi
}

# -----------------------------------------------------------------------------
# PERFORM RESTORE
# Extracts the backup archive into the parent directory.
# -----------------------------------------------------------------------------
perform_restore() {
    local backup_file="$1"

    log "INFO" "Extracting: $(basename "$backup_file") → $EXTRACT_TARGET"

    # Verify archive integrity before extracting
    if ! tar -tzf "$backup_file" &>/dev/null; then
        log "ERROR" "Archive integrity check failed: $backup_file"
        exit 1
    fi

    log "INFO" "Archive integrity: OK"

    # Extract (overwrites existing files)
    tar -xzf "$backup_file" \
        -C "$EXTRACT_TARGET" \
        2>/dev/null

    log "INFO" "Extraction complete"
}

# -----------------------------------------------------------------------------
# POST-RESTORE: Restore permissions and restart services
# -----------------------------------------------------------------------------
post_restore() {
    log "INFO" "Running post-restore setup..."

    # Re-set executable permissions on scripts
    if [[ -d "$SCRIPT_DIR" ]]; then
        find "$SCRIPT_DIR" -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
        log "INFO" "Script permissions restored"
    fi

    # Restart Nginx if running as root
    if [[ $EUID -eq 0 ]] && command -v systemctl &>/dev/null; then
        if systemctl is-active --quiet nginx 2>/dev/null; then
            systemctl reload nginx 2>/dev/null || true
            log "INFO" "Nginx reloaded"
        fi
    else
        log "INFO" "Note: run 'sudo systemctl reload nginx' if needed"
    fi
}

# -----------------------------------------------------------------------------
# CLEANUP OLD ROLLBACKS (keep last 3)
# -----------------------------------------------------------------------------
cleanup_rollbacks() {
    local rollback_count
    rollback_count="$(find "$ROLLBACK_DIR" -maxdepth 1 -name "rollback_*.tar.gz" 2>/dev/null | wc -l)"

    if (( rollback_count > 3 )); then
        find "$ROLLBACK_DIR" -maxdepth 1 -name "rollback_*.tar.gz" \
            | sort \
            | head -n $(( rollback_count - 3 )) \
            | xargs rm -f
        log "INFO" "Old rollback snapshots pruned (kept last 3)"
    fi
}

# -----------------------------------------------------------------------------
# MAIN
# -----------------------------------------------------------------------------
main() {
    print_header
    log "INFO" "=== restore.sh started ==="

    preflight_check

    # Find backup to restore
    local backup_file
    backup_file="$(find_backup "${1:-}")"

    list_backups

    confirm_restore "$backup_file"

    create_rollback

    echo ""
    echo "Restoring..."
    perform_restore "$backup_file"
    post_restore
    cleanup_rollbacks

    echo ""
    echo "============================================"
    echo "  Restore completed successfully!"
    echo "  Restored: $(basename "$backup_file")"
    echo "  Rollback: $ROLLBACK_DIR"
    echo "  Log: $LOG_FILE"
    echo "============================================"

    log "INFO" "=== restore.sh completed successfully ==="
    exit 0
}

main "$@"
