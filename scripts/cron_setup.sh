#!/bin/bash
# =============================================================================
# cron_setup.sh — CloudOps Monitor Cron Job Configuration
# =============================================================================
# Purpose  : Install cron jobs for:
#              - monitor.sh   every 5 minutes (metrics collection)
#              - backup.sh    daily at 00:00  (project backup)
#              - healthcheck.sh every 30 mins (system health)
#              - cleanup.sh   daily at 02:00  (remove old files)
# Usage    : sudo ./cron_setup.sh
#            (can also run as the target user without sudo)
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
LOG_DIR="$PROJECT_ROOT/logs"
LOG_FILE="$LOG_DIR/cron_setup.log"

# Which user's crontab to configure
CRON_USER="${SUDO_USER:-$(whoami)}"

# Log output redirection for cron jobs
CRON_LOG_MONITOR="$LOG_DIR/cron_monitor.log"
CRON_LOG_BACKUP="$LOG_DIR/cron_backup.log"
CRON_LOG_HEALTH="$LOG_DIR/cron_health.log"
CRON_LOG_CLEANUP="$LOG_DIR/cron_cleanup.log"

# Cron schedule definitions
CRON_MONITOR="*/5 * * * *"      # Every 5 minutes
CRON_BACKUP="0 0 * * *"         # Daily at midnight
CRON_HEALTH="*/30 * * * *"      # Every 30 minutes
CRON_CLEANUP="0 2 * * *"        # Daily at 02:00

# Marker comment to identify our cron block (for idempotent installs)
CRON_MARKER="# CloudOps Monitor — managed cron block"

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

    # Validate cron is available
    if ! command -v crontab &>/dev/null; then
        log "ERROR" "crontab command not found. Install: sudo apt-get install cron"
        exit 1
    fi

    # Validate all scripts exist
    local scripts=(monitor.sh backup.sh healthcheck.sh cleanup.sh)
    for script in "${scripts[@]}"; do
        if [[ ! -f "$SCRIPT_DIR/$script" ]]; then
            log "WARN" "Script not found: $SCRIPT_DIR/$script — its cron job will still be installed"
        fi
    done
}

# -----------------------------------------------------------------------------
# REMOVE EXISTING CLOUDOPS CRON BLOCK
# Idempotent: strips our managed block before re-adding it.
# -----------------------------------------------------------------------------
remove_existing_cron() {
    local current_cron
    current_cron="$(crontab -u "$CRON_USER" -l 2>/dev/null || true)"

    if echo "$current_cron" | grep -q "$CRON_MARKER"; then
        log "INFO" "Removing existing CloudOps cron block..."
        # Remove lines from our marker to the END_MARKER
        echo "$current_cron" | sed "/$CRON_MARKER/,/# END CloudOps Monitor/d" \
            | crontab -u "$CRON_USER" -
        log "INFO" "Existing block removed"
    fi
}

# -----------------------------------------------------------------------------
# INSTALL CRON JOBS
# Appends the CloudOps managed block to the user's crontab.
# -----------------------------------------------------------------------------
install_cron_jobs() {
    log "INFO" "Installing cron jobs for user: $CRON_USER"

    # Get current crontab (empty string if none)
    local current_cron
    current_cron="$(crontab -u "$CRON_USER" -l 2>/dev/null || true)"

    # Build the new cron block
    local new_block
    new_block="$(cat << EOF

$CRON_MARKER
# Do NOT manually edit between these markers — use cron_setup.sh
#
# Format: MIN HOUR DOM MON DOW COMMAND
#
# monitor.sh   — collect metrics every 5 min
$CRON_MONITOR bash $SCRIPT_DIR/monitor.sh >> $CRON_LOG_MONITOR 2>&1
#
# backup.sh    — create daily backup at midnight
$CRON_BACKUP bash $SCRIPT_DIR/backup.sh >> $CRON_LOG_BACKUP 2>&1
#
# healthcheck.sh — system health check every 30 min
$CRON_HEALTH bash $SCRIPT_DIR/healthcheck.sh >> $CRON_LOG_HEALTH 2>&1
#
# cleanup.sh   — remove old files at 02:00 daily
$CRON_CLEANUP bash $SCRIPT_DIR/cleanup.sh >> $CRON_LOG_CLEANUP 2>&1
# END CloudOps Monitor
EOF
)"

    # Append to existing crontab
    echo "${current_cron}${new_block}" | crontab -u "$CRON_USER" -

    log "INFO" "Cron jobs installed successfully"
}

# -----------------------------------------------------------------------------
# VERIFY
# Shows the installed crontab for confirmation.
# -----------------------------------------------------------------------------
verify_cron() {
    log "INFO" "Verifying installed crontab..."
    echo ""
    echo "=== Current crontab for $CRON_USER ==="
    crontab -u "$CRON_USER" -l 2>/dev/null || echo "(empty)"
    echo "======================================="
}

# -----------------------------------------------------------------------------
# PRINT SUMMARY
# -----------------------------------------------------------------------------
print_summary() {
    echo ""
    echo "============================================"
    echo "  Cron Jobs Installed Successfully"
    echo "============================================"
    echo ""
    printf "  %-12s  %s\n" "Schedule"    "Script"
    printf "  %-12s  %s\n" "----------"  "------"
    printf "  %-12s  %s\n" "*/5 * * * *" "monitor.sh   (every 5 min)"
    printf "  %-12s  %s\n" "*/30 * * * *" "healthcheck.sh (every 30 min)"
    printf "  %-12s  %s\n" "0 0 * * *"   "backup.sh    (daily midnight)"
    printf "  %-12s  %s\n" "0 2 * * *"   "cleanup.sh   (daily 02:00)"
    echo ""
    echo "  Cron logs: $LOG_DIR/cron_*.log"
    echo "  Edit jobs: crontab -e"
    echo "  View jobs: crontab -l"
    echo "============================================"
}

# -----------------------------------------------------------------------------
# MAIN
# -----------------------------------------------------------------------------
main() {
    log "INFO" "=== cron_setup.sh started ==="

    preflight_check
    remove_existing_cron
    install_cron_jobs
    verify_cron
    print_summary

    log "INFO" "=== cron_setup.sh completed successfully ==="
    exit 0
}

main "$@"
