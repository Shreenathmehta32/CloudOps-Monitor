#!/bin/bash
# =============================================================================
# monitor.sh — CloudOps Monitor System Metrics Collector
# =============================================================================
# Purpose  : Collect real-time server metrics and write dashboard/status.json
# Usage    : ./monitor.sh
# Schedule : Run via cron every 5 minutes (see cron_setup.sh)
# Output   : ../dashboard/status.json
#
# Author   : Shreenath Mehta
# Project  : CloudOps Monitor | AWS EC2 · Ubuntu 24.04 · Nginx
# =============================================================================

set -euo pipefail  # Exit on error, unset vars, pipe failures

# -----------------------------------------------------------------------------
# CONFIGURATION
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUTPUT_FILE="$PROJECT_ROOT/dashboard/status.json"
LOG_DIR="$PROJECT_ROOT/logs"
LOG_FILE="$LOG_DIR/monitor.log"
MAX_LOG_LINES=5000       # Rotate log if it exceeds this many lines
IMDS_TOKEN_TTL=21600     # AWS Instance Metadata Service token TTL (seconds)

# -----------------------------------------------------------------------------
# LOGGING UTILITY
# -----------------------------------------------------------------------------
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    # Ensure log directory exists before writing so tee never fails under set -eo pipefail
    [[ -d "$LOG_DIR" ]] || mkdir -p "$LOG_DIR"
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# -----------------------------------------------------------------------------
# PRE-FLIGHT: Validate environment and create missing directories
# -----------------------------------------------------------------------------
preflight_check() {
    # Ensure log directory exists
    if [[ ! -d "$LOG_DIR" ]]; then
        mkdir -p "$LOG_DIR"
        echo "Created log directory: $LOG_DIR"
    fi

    # Ensure dashboard directory exists
    local dashboard_dir
    dashboard_dir="$(dirname "$OUTPUT_FILE")"
    if [[ ! -d "$dashboard_dir" ]]; then
        mkdir -p "$dashboard_dir"
        log "INFO" "Created dashboard directory: $dashboard_dir"
    fi

    # Rotate log if too large
    if [[ -f "$LOG_FILE" ]]; then
        local line_count
        line_count="$(wc -l < "$LOG_FILE")"
        if (( line_count > MAX_LOG_LINES )); then
            tail -n "$MAX_LOG_LINES" "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
            log "INFO" "Log rotated — trimmed to $MAX_LOG_LINES lines"
        fi
    fi

    # Validate required commands exist
    local required_cmds=(hostname whoami date uptime free df awk grep curl cat)
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            log "WARN" "Command not found: $cmd — some metrics may be unavailable"
        fi
    done
}

# -----------------------------------------------------------------------------
# METRIC: Hostname
# -----------------------------------------------------------------------------
get_hostname() {
    hostname 2>/dev/null || echo "unknown"
}

# -----------------------------------------------------------------------------
# METRIC: Current logged-in user
# -----------------------------------------------------------------------------
get_user() {
    whoami 2>/dev/null || echo "unknown"
}

# -----------------------------------------------------------------------------
# METRIC: Current date/time (UTC)
# -----------------------------------------------------------------------------
get_date() {
    date -u '+%a %b %e %H:%M:%S UTC %Y' 2>/dev/null || date 2>/dev/null || echo "unknown"
}

# -----------------------------------------------------------------------------
# METRIC: System uptime (human-readable)
# -----------------------------------------------------------------------------
get_uptime() {
    # uptime -p gives "up X hours, Y minutes" on Linux
    uptime -p 2>/dev/null || uptime 2>/dev/null | awk -F'up ' '{print "up " $2}' | cut -d',' -f1-2 || echo "unknown"
}

# -----------------------------------------------------------------------------
# METRIC: Memory usage (used/total string)
# -----------------------------------------------------------------------------
get_memory() {
    # Returns string like "411Mi/911Mi"
    free -h 2>/dev/null | awk '/Mem:/ {printf "%s/%s", $3, $2}' || echo "unknown"
}

# -----------------------------------------------------------------------------
# METRIC: Memory percentage (integer 0-100)
# -----------------------------------------------------------------------------
get_memory_percent() {
    # Uses awk for integer arithmetic — no bc needed
    free 2>/dev/null | awk '/Mem:/ {
        used=$3; total=$2;
        if (total > 0) printf "%d", int(used/total * 100);
        else print "0"
    }' || echo "0"
}

# -----------------------------------------------------------------------------
# METRIC: Disk usage percentage (root filesystem)
# -----------------------------------------------------------------------------
get_disk_percent() {
    # Returns "34%" string using POSIX-compliant df -Ph (prevents multi-line wrapping)
    df -Ph / 2>/dev/null | awk 'NR==2 {print $5}' || echo "0%"
}

# -----------------------------------------------------------------------------
# METRIC: Disk used (human-readable)
# -----------------------------------------------------------------------------
get_disk_used() {
    df -Ph / 2>/dev/null | awk 'NR==2 {print $3}' || echo "unknown"
}

# -----------------------------------------------------------------------------
# METRIC: Disk total (human-readable)
# -----------------------------------------------------------------------------
get_disk_total() {
    df -Ph / 2>/dev/null | awk 'NR==2 {print $2}' || echo "unknown"
}

# -----------------------------------------------------------------------------
# METRIC: CPU usage percentage (sampled over 1 second)
# -----------------------------------------------------------------------------
get_cpu_percent() {
    # Use /proc/stat for accurate 1-second CPU sample — no mpstat needed
    if [[ -r /proc/stat ]]; then
        local user1 nice1 sys1 idle1 iowait1 irq1 softirq1 steal1
        local user2 nice2 sys2 idle2 iowait2 irq2 softirq2 steal2
        local total1 total2 total_delta idle_delta cpu_stat1 cpu_stat2

        # First sample: read aggregate 'cpu' line
        cpu_stat1="$(grep -m1 '^cpu ' /proc/stat 2>/dev/null || true)"
        if [[ -z "$cpu_stat1" ]]; then
            echo "0"
            return
        fi

        # Fields: cpu user nice system idle iowait irq softirq steal guest guest_nice
        read -r _ user1 nice1 sys1 idle1 iowait1 irq1 softirq1 steal1 _ <<< "$cpu_stat1"
        user1=${user1:-0}; nice1=${nice1:-0}; sys1=${sys1:-0}; idle1=${idle1:-0}
        iowait1=${iowait1:-0}; irq1=${irq1:-0}; softirq1=${softirq1:-0}; steal1=${steal1:-0}
        # guest and guest_nice are already included in user/nice, do not double-count
        total1=$(( user1 + nice1 + sys1 + idle1 + iowait1 + irq1 + softirq1 + steal1 ))

        sleep 1

        # Second sample
        cpu_stat2="$(grep -m1 '^cpu ' /proc/stat 2>/dev/null || true)"
        if [[ -z "$cpu_stat2" ]]; then
            echo "0"
            return
        fi

        read -r _ user2 nice2 sys2 idle2 iowait2 irq2 softirq2 steal2 _ <<< "$cpu_stat2"
        user2=${user2:-0}; nice2=${nice2:-0}; sys2=${sys2:-0}; idle2=${idle2:-0}
        iowait2=${iowait2:-0}; irq2=${irq2:-0}; softirq2=${softirq2:-0}; steal2=${steal2:-0}
        total2=$(( user2 + nice2 + sys2 + idle2 + iowait2 + irq2 + softirq2 + steal2 ))

        total_delta=$(( total2 - total1 ))
        idle_delta=$(( idle2 - idle1 ))

        if (( total_delta > 0 )); then
            local usage=$(( (total_delta - idle_delta) * 100 / total_delta ))
            if (( usage < 0 )); then
                usage=0
            elif (( usage > 100 )); then
                usage=100
            fi
            echo "$usage"
        else
            echo "0"
        fi
    else
        # Fallback: use top in batch mode (non-interactive)
        top -bn1 2>/dev/null | awk '/%Cpu\(s\):/ {print int($2)}' || echo "0"
    fi
}

# -----------------------------------------------------------------------------
# METRIC: Load average (1m 5m 15m)
# -----------------------------------------------------------------------------
get_load_avg() {
    # /proc/loadavg is always available on Linux
    if [[ -r /proc/loadavg ]]; then
        awk '{printf "%s %s %s", $1, $2, $3}' /proc/loadavg
    else
        uptime 2>/dev/null | awk -F'load average:' '{print $2}' | tr -d ' ' | tr ',' ' ' | xargs || echo "0 0 0"
    fi
}

# -----------------------------------------------------------------------------
# METRIC: OS name and version
# -----------------------------------------------------------------------------
get_os() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        echo "${PRETTY_NAME:-unknown}"
    elif command -v lsb_release &>/dev/null; then
        lsb_release -d 2>/dev/null | awk -F'Description:' '{print $2}' | xargs
    else
        uname -o 2>/dev/null || echo "unknown"
    fi
}

# -----------------------------------------------------------------------------
# METRIC: Kernel version
# -----------------------------------------------------------------------------
get_kernel() {
    uname -r 2>/dev/null || echo "unknown"
}

# -----------------------------------------------------------------------------
# METRIC: Public IP address
# Uses AWS Instance Metadata Service v2 (IMDSv2) first, then fallback APIs.
# -----------------------------------------------------------------------------
get_public_ip() {
    local public_ip=""

    # IMDSv2 — recommended on AWS EC2
    if command -v curl &>/dev/null; then
        local token
        token="$(curl -sf --max-time 2 \
            -X PUT "http://169.254.169.254/latest/api/token" \
            -H "X-aws-ec2-metadata-token-ttl-seconds: $IMDS_TOKEN_TTL" 2>/dev/null)" || true

        if [[ -n "$token" ]]; then
            public_ip="$(curl -sf --max-time 2 \
                -H "X-aws-ec2-metadata-token: $token" \
                "http://169.254.169.254/latest/meta-data/public-ipv4" 2>/dev/null)" || true
        fi

        # Fallback 1: Public IP API (for non-AWS or IMDSv1)
        if [[ -z "$public_ip" ]]; then
            public_ip="$(curl -sf --max-time 5 "https://api.ipify.org" 2>/dev/null)" || true
        fi

        # Fallback 2: alternative API
        if [[ -z "$public_ip" ]]; then
            public_ip="$(curl -sf --max-time 5 "https://checkip.amazonaws.com" 2>/dev/null | tr -d '[:space:]')" || true
        fi
    fi

    echo "${public_ip:-unavailable}"
}

# -----------------------------------------------------------------------------
# METRIC: Private IP address
# -----------------------------------------------------------------------------
get_private_ip() {
    local private_ip=""

    # IMDSv2 on EC2
    if command -v curl &>/dev/null; then
        local token
        token="$(curl -sf --max-time 2 \
            -X PUT "http://169.254.169.254/latest/api/token" \
            -H "X-aws-ec2-metadata-token-ttl-seconds: $IMDS_TOKEN_TTL" 2>/dev/null)" || true

        if [[ -n "$token" ]]; then
            private_ip="$(curl -sf --max-time 2 \
                -H "X-aws-ec2-metadata-token: $token" \
                "http://169.254.169.254/latest/meta-data/local-ipv4" 2>/dev/null)" || true
        fi
    fi

    # Fallback: hostname -I (gets first IP)
    if [[ -z "$private_ip" ]]; then
        private_ip="$(hostname -I 2>/dev/null | awk '{print $1}')" || true
    fi

    echo "${private_ip:-unavailable}"
}

# -----------------------------------------------------------------------------
# JSON ESCAPE
# Escapes double quotes and backslashes in strings for safe JSON output.
# -----------------------------------------------------------------------------
json_escape() {
    local s="$1"
    # Escape backslashes first, then quotes, tabs, carriage returns, and newlines
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\n'/\\n}"
    printf '%s' "$s"
}

# -----------------------------------------------------------------------------
# WRITE STATUS JSON
# Assembles all metrics and writes the status.json file atomically.
# -----------------------------------------------------------------------------
write_status_json() {
    local hostname user date_str uptime_str memory memory_pct
    local disk_pct disk_used disk_total cpu_pct load_avg os_ver kernel
    local public_ip private_ip

    log "INFO" "Collecting system metrics..."

    # Collect all metrics
    hostname="$(get_hostname)"
    user="$(get_user)"
    date_str="$(get_date)"
    uptime_str="$(get_uptime)"
    memory="$(get_memory)"
    memory_pct="$(get_memory_percent)"
    disk_pct="$(get_disk_percent)"
    disk_used="$(get_disk_used)"
    disk_total="$(get_disk_total)"
    cpu_pct="$(get_cpu_percent)"
    load_avg="$(get_load_avg)"
    os_ver="$(get_os)"
    kernel="$(get_kernel)"
    public_ip="$(get_public_ip)"
    private_ip="$(get_private_ip)"

    log "INFO" "Metrics collected. CPU=${cpu_pct}%, MEM=${memory_pct}%, DISK=${disk_pct}"

    # Escape all string values for JSON safety
    hostname="$(json_escape "$hostname")"
    user="$(json_escape "$user")"
    date_str="$(json_escape "$date_str")"
    uptime_str="$(json_escape "$uptime_str")"
    memory="$(json_escape "$memory")"
    memory_pct="$(json_escape "$memory_pct")"
    disk_pct="$(json_escape "$disk_pct")"
    disk_used="$(json_escape "$disk_used")"
    disk_total="$(json_escape "$disk_total")"
    cpu_pct="$(json_escape "$cpu_pct")"
    load_avg="$(json_escape "$load_avg")"
    os_ver="$(json_escape "$os_ver")"
    kernel="$(json_escape "$kernel")"
    public_ip="$(json_escape "$public_ip")"
    private_ip="$(json_escape "$private_ip")"

    # Write atomically: write to .tmp then rename (prevents partial reads by Nginx/browser)
    local dashboard_dir tmp_file
    dashboard_dir="$(dirname "$OUTPUT_FILE")"
    [[ -d "$dashboard_dir" ]] || mkdir -p "$dashboard_dir"

    tmp_file="${OUTPUT_FILE}.tmp"

    cat > "$tmp_file" << EOF
{
    "hostname":       "$hostname",
    "user":           "$user",
    "date":           "$date_str",
    "uptime":         "$uptime_str",
    "memory":         "$memory",
    "memory_percent": "$memory_pct",
    "disk":           "$disk_pct",
    "disk_used":      "$disk_used",
    "disk_total":     "$disk_total",
    "cpu_percent":    "$cpu_pct",
    "load_avg":       "$load_avg",
    "os":             "$os_ver",
    "kernel":         "$kernel",
    "public_ip":      "$public_ip",
    "private_ip":     "$private_ip"
}
EOF

    # Atomic rename — replaces destination file safely
    mv -f "$tmp_file" "$OUTPUT_FILE"

    log "INFO" "status.json updated successfully: $OUTPUT_FILE"
}

# -----------------------------------------------------------------------------
# MAIN
# -----------------------------------------------------------------------------
main() {
    # Ensure log directory exists before any logging occurs
    [[ -d "$LOG_DIR" ]] || mkdir -p "$LOG_DIR"

    log "INFO" "=== monitor.sh started ==="

    preflight_check
    write_status_json

    log "INFO" "=== monitor.sh completed successfully ==="
    exit 0
}

main "$@"
