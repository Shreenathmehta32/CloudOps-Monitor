#!/bin/bash
# =============================================================================
# healthcheck.sh — CloudOps Monitor System Health Check
# =============================================================================
# Purpose  : Check Nginx, disk, RAM, and CPU against thresholds.
#            Logs failures with severity levels. Exits non-zero on failure.
# Usage    : ./healthcheck.sh
# Exit codes:
#   0 — All checks passed
#   1 — One or more checks failed (CRITICAL or WARNING)
#
# Author   : Shreenath Mehta
# Project  : CloudOps Monitor | AWS EC2 · Ubuntu 24.04 · Nginx
# =============================================================================

set -uo pipefail  # Note: NOT -e because we want to collect all failures

# -----------------------------------------------------------------------------
# CONFIGURATION
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LOG_DIR="$PROJECT_ROOT/logs"
LOG_FILE="$LOG_DIR/healthcheck.log"
REPORT_FILE="$LOG_DIR/health_report.txt"

# Thresholds (percentages)
DISK_WARN_PCT=75      # Warn when disk usage exceeds this
DISK_CRIT_PCT=90      # Critical when disk usage exceeds this
MEM_WARN_PCT=80       # Warn when memory usage exceeds this
MEM_CRIT_PCT=95       # Critical when memory usage exceeds this
CPU_WARN_PCT=70       # Warn when CPU usage exceeds this
CPU_CRIT_PCT=90       # Critical when CPU usage exceeds this

# Nginx service name
NGINX_SERVICE="nginx"

# Overall health state tracking
HEALTH_STATUS=0       # 0=OK, 1=WARN, 2=CRITICAL
FAILED_CHECKS=()
WARNING_CHECKS=()

# -----------------------------------------------------------------------------
# LOGGING
# -----------------------------------------------------------------------------
log() {
    local level="$1"; shift
    local timestamp; timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$timestamp] [$level] $*" | tee -a "$LOG_FILE"
}

# Colour output for terminal
RED='\033[0;31m'; YELLOW='\033[0;33m'; GREEN='\033[0;32m'; RESET='\033[0m'
ok()   { echo -e "${GREEN}[OK]${RESET}      $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET}    $*"; }
crit() { echo -e "${RED}[CRITICAL]${RESET} $*"; }

# -----------------------------------------------------------------------------
# PRE-FLIGHT
# -----------------------------------------------------------------------------
preflight_check() {
    mkdir -p "$LOG_DIR"
}

# -----------------------------------------------------------------------------
# CHECK: Nginx Service Status
# -----------------------------------------------------------------------------
check_nginx() {
    echo ""
    echo "=== Nginx Service Check ==="

    # Check if nginx is installed
    if ! command -v nginx &>/dev/null; then
        crit "Nginx is not installed"
        log "CRITICAL" "Nginx not installed"
        FAILED_CHECKS+=("nginx:not_installed")
        HEALTH_STATUS=2
        return
    fi

    # Check if systemctl is available (systemd)
    if command -v systemctl &>/dev/null; then
        if systemctl is-active --quiet "$NGINX_SERVICE"; then
            ok "Nginx service is ACTIVE"
            log "INFO" "Nginx: active"
        else
            crit "Nginx service is NOT running"
            log "CRITICAL" "Nginx: service down"
            FAILED_CHECKS+=("nginx:service_down")
            HEALTH_STATUS=2
        fi

        # Check if nginx is enabled (survives reboot)
        if systemctl is-enabled --quiet "$NGINX_SERVICE" 2>/dev/null; then
            ok "Nginx is enabled (auto-start on boot)"
        else
            warn "Nginx is NOT enabled — will not restart on reboot"
            log "WARN" "Nginx: not enabled for auto-start"
            WARNING_CHECKS+=("nginx:not_enabled")
            [[ $HEALTH_STATUS -lt 1 ]] && HEALTH_STATUS=1
        fi
    else
        # Fallback: check via process
        if pgrep -x nginx &>/dev/null; then
            ok "Nginx process is running"
            log "INFO" "Nginx: process found"
        else
            crit "Nginx process not found"
            log "CRITICAL" "Nginx: process missing"
            FAILED_CHECKS+=("nginx:process_missing")
            HEALTH_STATUS=2
        fi
    fi

    # Test nginx config syntax
    if nginx -t &>/dev/null 2>&1; then
        ok "Nginx config syntax: valid"
    else
        warn "Nginx config syntax error detected"
        log "WARN" "Nginx: config syntax error"
        WARNING_CHECKS+=("nginx:config_error")
        [[ $HEALTH_STATUS -lt 1 ]] && HEALTH_STATUS=1
    fi
}

# -----------------------------------------------------------------------------
# CHECK: Disk Usage
# -----------------------------------------------------------------------------
check_disk() {
    echo ""
    echo "=== Disk Usage Check ==="

    # Get disk usage for root filesystem
    local disk_pct
    disk_pct="$(df / | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"

    if ! [[ "$disk_pct" =~ ^[0-9]+$ ]]; then
        warn "Could not read disk usage"
        log "WARN" "Disk: unable to read usage"
        return
    fi

    local disk_info
    disk_info="$(df -h / | awk 'NR==2 {printf "%s used of %s (%s%%)", $3, $2, $5}')"

    if (( disk_pct >= DISK_CRIT_PCT )); then
        crit "Disk usage CRITICAL: $disk_info"
        log "CRITICAL" "Disk: ${disk_pct}% — threshold ${DISK_CRIT_PCT}%"
        FAILED_CHECKS+=("disk:${disk_pct}%")
        HEALTH_STATUS=2
    elif (( disk_pct >= DISK_WARN_PCT )); then
        warn "Disk usage WARNING: $disk_info"
        log "WARN" "Disk: ${disk_pct}% — threshold ${DISK_WARN_PCT}%"
        WARNING_CHECKS+=("disk:${disk_pct}%")
        [[ $HEALTH_STATUS -lt 1 ]] && HEALTH_STATUS=1
    else
        ok "Disk usage OK: $disk_info"
        log "INFO" "Disk: ${disk_pct}%"
    fi
}

# -----------------------------------------------------------------------------
# CHECK: Memory Usage
# -----------------------------------------------------------------------------
check_memory() {
    echo ""
    echo "=== Memory Usage Check ==="

    local mem_pct mem_info
    mem_pct="$(free | awk '/Mem:/ {printf "%d", int($3/$2*100)}')"
    mem_info="$(free -h | awk '/Mem:/ {printf "%s used of %s", $3, $2}')"

    if ! [[ "$mem_pct" =~ ^[0-9]+$ ]]; then
        warn "Could not read memory usage"
        log "WARN" "Memory: unable to read usage"
        return
    fi

    if (( mem_pct >= MEM_CRIT_PCT )); then
        crit "Memory usage CRITICAL: $mem_info (${mem_pct}%)"
        log "CRITICAL" "Memory: ${mem_pct}% — threshold ${MEM_CRIT_PCT}%"
        FAILED_CHECKS+=("memory:${mem_pct}%")
        HEALTH_STATUS=2
    elif (( mem_pct >= MEM_WARN_PCT )); then
        warn "Memory usage WARNING: $mem_info (${mem_pct}%)"
        log "WARN" "Memory: ${mem_pct}% — threshold ${MEM_WARN_PCT}%"
        WARNING_CHECKS+=("memory:${mem_pct}%")
        [[ $HEALTH_STATUS -lt 1 ]] && HEALTH_STATUS=1
    else
        ok "Memory usage OK: $mem_info (${mem_pct}%)"
        log "INFO" "Memory: ${mem_pct}%"
    fi
}

# -----------------------------------------------------------------------------
# CHECK: CPU Usage (1-minute load average vs CPU cores)
# -----------------------------------------------------------------------------
check_cpu() {
    echo ""
    echo "=== CPU / Load Average Check ==="

    local load_1m cpu_cores load_pct
    load_1m="$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "0")"
    cpu_cores="$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo "1")"

    # Calculate load percentage vs total cores
    load_pct="$(awk "BEGIN {printf \"%d\", int(($load_1m / $cpu_cores) * 100)}")"

    echo "    Load average (1m): $load_1m | CPU cores: $cpu_cores | Load%: ${load_pct}%"

    if (( load_pct >= CPU_CRIT_PCT )); then
        crit "CPU load CRITICAL: ${load_pct}% (load: $load_1m, cores: $cpu_cores)"
        log "CRITICAL" "CPU: load ${load_1m} across ${cpu_cores} cores (${load_pct}%)"
        FAILED_CHECKS+=("cpu:${load_pct}%")
        HEALTH_STATUS=2
    elif (( load_pct >= CPU_WARN_PCT )); then
        warn "CPU load WARNING: ${load_pct}% (load: $load_1m, cores: $cpu_cores)"
        log "WARN" "CPU: load ${load_1m} across ${cpu_cores} cores (${load_pct}%)"
        WARNING_CHECKS+=("cpu:${load_pct}%")
        [[ $HEALTH_STATUS -lt 1 ]] && HEALTH_STATUS=1
    else
        ok "CPU load OK: ${load_pct}% (load: $load_1m, cores: $cpu_cores)"
        log "INFO" "CPU: load ${load_1m} / ${cpu_cores} cores (${load_pct}%)"
    fi
}

# -----------------------------------------------------------------------------
# CHECK: Status JSON — verify monitor.sh is running and data is fresh
# -----------------------------------------------------------------------------
check_status_json() {
    echo ""
    echo "=== Status JSON Freshness Check ==="

    local status_file="$PROJECT_ROOT/dashboard/status.json"

    if [[ ! -f "$status_file" ]]; then
        warn "status.json not found — monitor.sh may not have run yet"
        log "WARN" "status.json: file missing"
        WARNING_CHECKS+=("status_json:missing")
        [[ $HEALTH_STATUS -lt 1 ]] && HEALTH_STATUS=1
        return
    fi

    # Check file age — warn if older than 10 minutes
    local file_age_seconds
    file_age_seconds="$(( $(date +%s) - $(stat -c %Y "$status_file" 2>/dev/null || echo 0) ))"

    if (( file_age_seconds > 600 )); then
        local age_min=$(( file_age_seconds / 60 ))
        warn "status.json is stale — last updated ${age_min}m ago (cron may be broken)"
        log "WARN" "status.json: ${age_min}m old — cron may not be running"
        WARNING_CHECKS+=("status_json:stale_${age_min}m")
        [[ $HEALTH_STATUS -lt 1 ]] && HEALTH_STATUS=1
    else
        ok "status.json is fresh (updated ${file_age_seconds}s ago)"
        log "INFO" "status.json: fresh"
    fi
}

# -----------------------------------------------------------------------------
# SUMMARY REPORT
# -----------------------------------------------------------------------------
print_summary() {
    echo ""
    echo "============================================"
    echo "  HEALTH CHECK SUMMARY"
    echo "  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "============================================"

    if [[ ${#FAILED_CHECKS[@]} -gt 0 ]]; then
        echo -e "${RED}CRITICAL FAILURES:${RESET}"
        for check in "${FAILED_CHECKS[@]}"; do
            echo -e "  ${RED}✗${RESET} $check"
        done
    fi

    if [[ ${#WARNING_CHECKS[@]} -gt 0 ]]; then
        echo -e "${YELLOW}WARNINGS:${RESET}"
        for check in "${WARNING_CHECKS[@]}"; do
            echo -e "  ${YELLOW}⚠${RESET} $check"
        done
    fi

    case $HEALTH_STATUS in
        0) echo -e "\n${GREEN}Overall: HEALTHY — all checks passed${RESET}" ;;
        1) echo -e "\n${YELLOW}Overall: DEGRADED — warnings detected${RESET}" ;;
        2) echo -e "\n${RED}Overall: CRITICAL — immediate action required${RESET}" ;;
    esac

    echo "============================================"

    # Write report to file
    {
        echo "CloudOps Monitor Health Report"
        echo "Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "Status: $HEALTH_STATUS"
        echo "Critical: ${FAILED_CHECKS[*]:-none}"
        echo "Warnings: ${WARNING_CHECKS[*]:-none}"
    } > "$REPORT_FILE"

    log "INFO" "Health check complete — status=$HEALTH_STATUS"
}

# -----------------------------------------------------------------------------
# MAIN
# -----------------------------------------------------------------------------
main() {
    echo "============================================"
    echo "  CloudOps Monitor — Health Check"
    echo "  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "============================================"

    log "INFO" "=== healthcheck.sh started ==="

    preflight_check
    check_nginx
    check_disk
    check_memory
    check_cpu
    check_status_json
    print_summary

    log "INFO" "=== healthcheck.sh completed — status=$HEALTH_STATUS ==="
    exit $HEALTH_STATUS
}

main "$@"
