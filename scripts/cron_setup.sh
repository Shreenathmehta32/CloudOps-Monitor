#!/bin/bash
# =============================================================================
# cron_setup.sh — CloudOps Monitor Cron Job Configuration
# =============================================================================
# Purpose  : Install cron jobs for:
#              - monitor.sh     every 1 minute  (metrics collection)
#              - healthcheck.sh every 30 mins   (system health)
#              - backup.sh      daily at 00:00  (project backup)
#              - cleanup.sh     daily at 02:00  (remove old files)
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

# Log output redirection for cron jobs (absolute paths)
CRON_LOG_MONITOR="$LOG_DIR/cron_monitor.log"
CRON_LOG_BACKUP="$LOG_DIR/cron_backup.log"
CRON_LOG_HEALTH="$LOG_DIR/cron_health.log"
CRON_LOG_CLEANUP="$LOG_DIR/cron_cleanup.log"

# Cron schedule definitions
CRON_MONITOR="* * * * *"        # Every 1 minute
CRON_HEALTH="*/30 * * * *"      # Every 30 minutes
CRON_BACKUP="0 0 * * *"         # Daily at midnight (00:00)
CRON_CLEANUP="0 2 * * *"        # Daily at 02:00

# Marker comments to identify managed cron block (for idempotent installs)
CRON_MARKER="# CloudOps Monitor — managed cron block"
CRON_END_MARKER="# END CloudOps Monitor"

# Safe environment defaults for cron execution
CRON_SHELL="SHELL=/bin/bash"
CRON_PATH="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# -----------------------------------------------------------------------------
# LOGGING
# -----------------------------------------------------------------------------
log() {
    local level="$1"
    shift
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    # Ensure log directory exists before writing
    [[ -d "$LOG_DIR" ]] || mkdir -p "$LOG_DIR"

    echo "[$timestamp] [$level] $*" | tee -a "$LOG_FILE"
}

# -----------------------------------------------------------------------------
# CRONTAB ACCESS HELPERS
# Uses -u only when running with root privileges to avoid permission errors.
# -----------------------------------------------------------------------------
get_crontab() {
    if [[ $EUID -eq 0 ]] && [[ -n "${CRON_USER:-}" ]]; then
        crontab -u "$CRON_USER" -l 2>/dev/null || true
    else
        crontab -l 2>/dev/null || true
    fi
}

set_crontab() {
    if [[ $EUID -eq 0 ]] && [[ -n "${CRON_USER:-}" ]]; then
        crontab -u "$CRON_USER" -
    else
        crontab -
    fi
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
    current_cron="$(get_crontab)"

    if echo "$current_cron" | grep -q "$CRON_MARKER"; then
        log "INFO" "Removing existing CloudOps cron block..."

        # Remove lines from our start marker to the end marker
        echo "$current_cron" |
            sed "/$CRON_MARKER/,/$CRON_END_MARKER/d" |
            set_crontab

        log "INFO" "Existing block removed"
    fi
}

# -----------------------------------------------------------------------------
# INSTALL CRON JOBS
# Appends the CloudOps managed block to the user's crontab.
# -----------------------------------------------------------------------------
install_cron_jobs() {
    log "INFO" "Installing cron jobs for user: $CRON_USER"

    # Get current crontab
    local current_cron
    current_cron="$(get_crontab)"

    # Build the new cron block
    local new_block
    new_block="$(cat << EOF

$CRON_MARKER
# Do NOT manually edit between these markers — managed by cron_setup.sh
$CRON_SHELL
$CRON_PATH
#
# Format: MIN HOUR DOM MON DOW COMMAND
#
# monitor.sh     — collect metrics every 1 min
$CRON_MONITOR /bin/bash $SCRIPT_DIR/monitor.sh >> $CRON_LOG_MONITOR 2>&1
#
# healthcheck.sh — system health check every 30 min
$CRON_HEALTH /bin/bash $SCRIPT_DIR/healthcheck.sh >> $CRON_LOG_HEALTH 2>&1
#
# backup.sh      — create daily backup at midnight
$CRON_BACKUP /bin/bash $SCRIPT_DIR/backup.sh >> $CRON_LOG_BACKUP 2>&1
#
# cleanup.sh     — remove old files at 02:00 daily
$CRON_CLEANUP /bin/bash $SCRIPT_DIR/cleanup.sh >> $CRON_LOG_CLEANUP 2>&1
$CRON_END_MARKER
EOF
)"

    # Combine existing crontab with new block
    if [[ -n "$current_cron" ]]; then
        printf '%s\n%s\n' "$current_cron" "$new_block" | set_crontab
    else
        printf '%s\n' "$new_block" | sed '/^$/d' | set_crontab
    fi

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

    get_crontab || echo "(empty)"

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

    printf "  %-14s  %s\n" "Schedule" "Script"
    printf "  %-14s  %s\n" "----------" "------"
    printf "  %-14s  %s\n" "* * * * *" "monitor.sh     (every 1 min)"
    printf "  %-14s  %s\n" "*/30 * * * *" "healthcheck.sh (every 30 min)"
    printf "  %-14s  %s\n" "0 0 * * *" "backup.sh      (daily midnight)"
    printf "  %-14s  %s\n" "0 2 * * *" "cleanup.sh     (daily 02:00)"

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
    # Ensure log directory exists before any logging occurs
    [[ -d "$LOG_DIR" ]] || mkdir -p "$LOG_DIR"

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