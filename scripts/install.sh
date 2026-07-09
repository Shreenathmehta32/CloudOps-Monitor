#!/bin/bash
# =============================================================================
# install.sh — CloudOps Monitor Automated Installation Script
# =============================================================================
# Purpose  : Install dependencies (Nginx, git, awscli, curl), configure Nginx
#            to serve the dashboard, and set up correct permissions.
# Usage    : sudo ./install.sh
# Note     : Run once on a fresh Ubuntu 24.04 EC2 instance.
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
DASHBOARD_DIR="$PROJECT_ROOT/dashboard"
LOG_DIR="$PROJECT_ROOT/logs"
BACKUP_DIR="$PROJECT_ROOT/backups"
REPORTS_DIR="$PROJECT_ROOT/reports"
LOG_FILE="$LOG_DIR/install.log"

# Nginx configuration
NGINX_SITE_NAME="cloudops-monitor"
NGINX_CONF="/etc/nginx/sites-available/$NGINX_SITE_NAME"
NGINX_ENABLED="/etc/nginx/sites-enabled/$NGINX_SITE_NAME"
NGINX_PORT=80

# The system user that will own the files
PROJECT_USER="${SUDO_USER:-ubuntu}"

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
    echo "  CloudOps Monitor — Installation"
    echo "  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "============================================"
}

print_step() {
    echo ""
    echo ">>> $*"
}

# -----------------------------------------------------------------------------
# PRE-FLIGHT: must run as root
# -----------------------------------------------------------------------------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "[ERROR] This script must be run as root: sudo ./install.sh"
        exit 1
    fi
}

# Check Ubuntu version
check_os() {
    if [[ ! -f /etc/os-release ]]; then
        log "WARN" "Cannot determine OS — proceeding anyway"
        return
    fi
    # shellcheck disable=SC1091
    . /etc/os-release
    log "INFO" "OS detected: ${PRETTY_NAME:-unknown}"

    if [[ "${ID:-}" != "ubuntu" ]]; then
        log "WARN" "This script is designed for Ubuntu. Current OS: ${ID:-unknown}"
    fi
}

# -----------------------------------------------------------------------------
# SETUP DIRECTORIES
# -----------------------------------------------------------------------------
setup_directories() {
    print_step "Creating project directories..."

    local dirs=("$LOG_DIR" "$BACKUP_DIR" "$REPORTS_DIR" "$DASHBOARD_DIR")
    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
            log "INFO" "Created: $dir"
        else
            log "INFO" "Exists: $dir"
        fi
    done

    # Set ownership to the project user (not root)
    chown -R "$PROJECT_USER":"$PROJECT_USER" "$PROJECT_ROOT"
    log "INFO" "Ownership set to $PROJECT_USER"
}

# -----------------------------------------------------------------------------
# INSTALL PACKAGES
# -----------------------------------------------------------------------------
install_packages() {
    print_step "Updating package lists..."
    apt-get update -qq 2>>"$LOG_FILE"
    log "INFO" "Package lists updated"

    print_step "Installing required packages..."

    local packages=(nginx git curl unzip)

    # Install AWS CLI v2 separately (not in apt)
    for pkg in "${packages[@]}"; do
        if dpkg -l "$pkg" &>/dev/null; then
            log "INFO" "Already installed: $pkg"
        else
            log "INFO" "Installing: $pkg"
            apt-get install -y -qq "$pkg" 2>>"$LOG_FILE"
            log "INFO" "Installed: $pkg"
        fi
    done

    # Install AWS CLI v2
    install_awscli
}

install_awscli() {
    if command -v aws &>/dev/null; then
        local aws_ver; aws_ver="$(aws --version 2>&1 | awk '{print $1}')"
        log "INFO" "AWS CLI already installed: $aws_ver"
        return
    fi

    print_step "Installing AWS CLI v2..."
    local tmp_dir; tmp_dir="$(mktemp -d)"

    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" \
        -o "$tmp_dir/awscliv2.zip" 2>>"$LOG_FILE"
    unzip -q "$tmp_dir/awscliv2.zip" -d "$tmp_dir"
    "$tmp_dir/aws/install" --update 2>>"$LOG_FILE"
    rm -rf "$tmp_dir"

    local aws_ver; aws_ver="$(aws --version 2>&1 | awk '{print $1}')"
    log "INFO" "AWS CLI v2 installed: $aws_ver"
}

# -----------------------------------------------------------------------------
# MAKE SCRIPTS EXECUTABLE
# -----------------------------------------------------------------------------
set_permissions() {
    print_step "Setting script permissions..."

    find "$SCRIPT_DIR" -name "*.sh" -exec chmod +x {} \;
    log "INFO" "All .sh scripts made executable"

    # Dashboard files: readable by nginx (www-data)
    chmod -R 755 "$DASHBOARD_DIR"
    chown -R "$PROJECT_USER:www-data" "$DASHBOARD_DIR"
    log "INFO" "Dashboard files: chmod 755, group www-data"
}

# -----------------------------------------------------------------------------
# CONFIGURE NGINX
# Creates a virtual host that serves the dashboard directory.
# -----------------------------------------------------------------------------
configure_nginx() {
    print_step "Configuring Nginx virtual host..."

    # Remove default site if present
    if [[ -L "/etc/nginx/sites-enabled/default" ]]; then
        rm -f "/etc/nginx/sites-enabled/default"
        log "INFO" "Removed default Nginx site"
    fi

    # Write the site configuration
    cat > "$NGINX_CONF" << EOF
# CloudOps Monitor — Nginx Site Configuration
# Auto-generated by install.sh

server {
    listen ${NGINX_PORT};
    listen [::]:${NGINX_PORT};

    server_name _;   # Accept any hostname / public IP

    # Document root: the dashboard directory
    root ${DASHBOARD_DIR};
    index index.html;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;

    # Serve static files; 404 on anything not found
    location / {
        try_files \$uri \$uri/ =404;
    }

    # Force no-cache on status.json so the browser always gets fresh data
    location = /status.json {
        add_header Cache-Control "no-store, no-cache, must-revalidate, max-age=0";
        add_header Pragma "no-cache";
        try_files \$uri =404;
    }

    # Hide Nginx version from error pages
    server_tokens off;

    # Deny access to hidden files (e.g., .git, .env)
    location ~ /\. {
        deny all;
        return 404;
    }

    # Logs
    access_log /var/log/nginx/${NGINX_SITE_NAME}_access.log;
    error_log  /var/log/nginx/${NGINX_SITE_NAME}_error.log;
}
EOF

    # Enable the site
    ln -sf "$NGINX_CONF" "$NGINX_ENABLED"
    log "INFO" "Nginx site enabled: $NGINX_SITE_NAME"

    # Test configuration syntax
    if nginx -t 2>>"$LOG_FILE"; then
        log "INFO" "Nginx config syntax: valid"
    else
        log "ERROR" "Nginx config syntax error — check: $NGINX_CONF"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# START / RESTART NGINX
# -----------------------------------------------------------------------------
start_nginx() {
    print_step "Starting Nginx..."

    systemctl enable nginx 2>>"$LOG_FILE"
    systemctl restart nginx 2>>"$LOG_FILE"

    if systemctl is-active --quiet nginx; then
        log "INFO" "Nginx is running"
    else
        log "ERROR" "Nginx failed to start — check: journalctl -u nginx"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# RUN MONITOR.SH ONCE TO POPULATE status.json
# -----------------------------------------------------------------------------
initial_monitor_run() {
    print_step "Running monitor.sh to populate initial status.json..."

    local monitor_script="$SCRIPT_DIR/monitor.sh"
    if [[ -x "$monitor_script" ]]; then
        # Run as project user (not root) for correct ownership
        sudo -u "$PROJECT_USER" bash "$monitor_script" 2>>"$LOG_FILE" || true
        log "INFO" "Initial status.json generated"
    else
        log "WARN" "monitor.sh not found or not executable — skipping initial run"
    fi
}

# -----------------------------------------------------------------------------
# PRINT INSTALLATION SUMMARY
# -----------------------------------------------------------------------------
print_summary() {
    local public_ip
    public_ip="$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || echo 'YOUR_EC2_PUBLIC_IP')"

    echo ""
    echo "============================================"
    echo "  Installation Complete!"
    echo "============================================"
    echo ""
    echo "  Dashboard URL: http://${public_ip}"
    echo "  Dashboard dir: $DASHBOARD_DIR"
    echo "  Nginx config:  $NGINX_CONF"
    echo "  Logs:          $LOG_DIR"
    echo ""
    echo "  Next steps:"
    echo "  1. Open Security Group port 80 in AWS Console"
    echo "  2. Run: sudo bash scripts/cron_setup.sh"
    echo "  3. Visit: http://${public_ip}"
    echo "============================================"

    log "INFO" "Installation completed. URL: http://$public_ip"
}

# -----------------------------------------------------------------------------
# MAIN
# -----------------------------------------------------------------------------
main() {
    print_header
    check_root
    check_os

    # Bootstrap log directory early
    mkdir -p "$LOG_DIR"
    log "INFO" "=== install.sh started ==="

    setup_directories
    install_packages
    set_permissions
    configure_nginx
    start_nginx
    initial_monitor_run
    print_summary

    log "INFO" "=== install.sh completed successfully ==="
    exit 0
}

main "$@"
