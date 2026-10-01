# ☁️ CloudOps Monitor

> A **production-quality Linux + AWS monitoring dashboard** — real-time server metrics collected by Bash scripts and displayed in a dark-theme, responsive web interface. Built to showcase DevOps fundamentals: EC2, Nginx, Bash, Cron, S3, and IAM.

[![Ubuntu](https://img.shields.io/badge/Ubuntu-24.04-E95420?style=flat&logo=ubuntu&logoColor=white)](https://ubuntu.com/)
[![AWS EC2](https://img.shields.io/badge/AWS-EC2-FF9900?style=flat&logo=amazonaws&logoColor=white)](https://aws.amazon.com/ec2/)
[![Nginx](https://img.shields.io/badge/Nginx-1.x-009900?style=flat&logo=nginx&logoColor=white)](https://nginx.org/)
[![Bash](https://img.shields.io/badge/Bash-5.x-4EAA25?style=flat&logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg?style=flat)](LICENSE)

---

## 📸 Screenshots

> *(Open `dashboard/index.html` in a browser after running `monitor.sh` to see the live dashboard)*

| Dark Dashboard | Mobile View |
|---|---|
| *Screenshot placeholder* | *Screenshot placeholder* |

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      AWS Cloud                              │
│                                                             │
│  ┌────────────────────────────────────┐                     │
│  │          EC2 Instance              │                     │
│  │          Ubuntu 24.04              │                     │
│  │                                    │                     │
│  │  ┌────────────┐   ┌─────────────┐  │      ┌──────────┐  │
│  │  │ monitor.sh │──▶│ status.json │  │      │    S3    │  │
│  │  │  (cron)    │   │  (metrics)  │  │      │  Bucket  │  │
│  │  └────────────┘   └──────┬──────┘  │      └────▲─────┘  │
│  │                          │         │           │         │
│  │  ┌────────────────────── │ ──────┐ │  ┌───────┴──────┐  │
│  │  │      Nginx (port 80)  │       │ │  │  backup.sh   │  │
│  │  │   serves /dashboard   │       │ │  │  upload.sh   │  │
│  │  └───────────────────────┼───────┘ │  └──────────────┘  │
│  │                          │         │                     │
│  └──────────────────────────┼─────────┘                     │
│                             │                               │
└─────────────────────────────┼───────────────────────────────┘
                              │ HTTP
                              ▼
                    ┌──────────────────┐
                    │    Browser       │
                    │                  │
                    │  index.html      │
                    │  style.css       │
                    │  script.js       │
                    │  (fetch every    │
                    │   30 seconds)    │
                    └──────────────────┘

Data Flow:
monitor.sh ──▶ dashboard/status.json ──▶ script.js (fetch) ──▶ index.html ──▶ Browser
```

---

## ✨ Features

### Dashboard
- 🌑 **Dark theme** — deep space palette inspired by Grafana & Datadog
- 📊 **15 live metrics** — hostname, user, uptime, OS, kernel, CPU, memory, disk, public/private IP, load average (1m/5m/15m)
- ⚡ **Animated progress bars** — CPU, memory, and disk with shimmer animation; turn red at 85%+
- 🔄 **Auto-refresh** — fetches `status.json` every 30 seconds
- 🟢 **Online/offline badge** — animated pulse dot, switches on fetch failure
- 🔔 **Toast notifications** — slide-in alerts for connection events
- 🕐 **Live clock** — real-time seconds display in header
- 📱 **Fully responsive** — CSS Grid adapts from 5 columns to 1 column on mobile
- ♿ **Accessible** — ARIA labels, semantic HTML5, focus styles

### Backend (Bash)
- 📦 **8 production scripts** — all with functions, error handling, logging, exit codes
- ⚛️ **Atomic writes** — `monitor.sh` uses `.tmp` + `mv` to prevent partial JSON reads
- 🔒 **IMDSv2** — AWS Instance Metadata Service v2 for IP retrieval (most secure method)
- 🔁 **Retry logic** — `upload.sh` retries S3 uploads 3 times
- 🛡️ **Safety guards** — `cleanup.sh` preserves minimum backup count; `restore.sh` creates rollback before overwriting

---

## 🛠️ Tech Stack

| Layer | Technology |
|---|---|
| **Platform** | AWS EC2, Ubuntu 24.04 LTS |
| **Web Server** | Nginx 1.x |
| **Frontend** | HTML5, CSS3 (custom properties), Vanilla JavaScript |
| **Backend** | Bash 5.x |
| **Data Format** | JSON (`status.json`) |
| **Scheduling** | Linux cron |
| **Storage** | AWS S3 (backups) |
| **Fonts** | Google Fonts — Inter, JetBrains Mono |

---

## 📁 Folder Structure

```
CloudOps-Monitor/
├── dashboard/              # Frontend files (served by Nginx)
│   ├── index.html          # Main dashboard UI
│   ├── style.css           # Dark theme, CSS variables, animations
│   ├── script.js           # Data fetching, DOM rendering, toasts
│   └── status.json         # Live metrics (written by monitor.sh)
│
├── scripts/                # Bash backend
│   ├── monitor.sh          # Collect metrics → status.json (runs every 5 min)
│   ├── backup.sh           # Compress project → backups/ (daily)
│   ├── upload.sh           # Upload latest backup → S3 (after backup.sh)
│   ├── healthcheck.sh      # Check nginx/disk/RAM/CPU (every 30 min)
│   ├── install.sh          # First-time setup: install deps, configure nginx
│   ├── cron_setup.sh       # Configure all cron jobs
│   ├── cleanup.sh          # Remove old backups/logs (daily at 02:00)
│   └── restore.sh          # Restore latest/specified backup safely
│
├── backups/                # Local .tar.gz backup archives
├── logs/                   # All script logs (monitor, backup, health, etc.)
├── reports/                # Health report output files
├── screenshots/            # Dashboard screenshots for README
├── .gitignore              # Excludes backups/, logs/, *.tmp
├── LICENSE                 # MIT License
└── README.md               # This file
```

---

## 🚀 Installation

### Prerequisites
- AWS EC2 instance running **Ubuntu 24.04 LTS**
- Security Group: port **22** (SSH) and **80** (HTTP) open
- IAM Role with **S3 write permissions** (for `upload.sh`)

### Step 1 — SSH into your EC2 instance
```bash
ssh -i your-key.pem ubuntu@YOUR_EC2_PUBLIC_IP
```

### Step 2 — Clone the repository
```bash
git clone https://github.com/Shreenathmehta32/CloudOps-Monitor.git
cd CloudOps-Monitor
```

### Step 3 — Run the installer
```bash
sudo bash scripts/install.sh
```
This will:
- Install Nginx, git, curl, AWS CLI v2
- Configure Nginx to serve `/dashboard` on port 80
- Add security headers (`X-Frame-Options`, `X-Content-Type-Options`, etc.)
- Run `monitor.sh` once to generate the initial `status.json`

### Step 4 — Set up cron jobs
```bash
bash scripts/cron_setup.sh
```

### Step 5 — View your dashboard
Open in browser: `http://YOUR_EC2_PUBLIC_IP`

---

## 📖 Usage

### Manual metric refresh
```bash
bash scripts/monitor.sh
```

### Create a manual backup
```bash
bash scripts/backup.sh
```

### Upload latest backup to S3
```bash
# Set your bucket name first:
export CLOUDOPS_S3_BUCKET="your-bucket-name"
bash scripts/upload.sh
```

### Run a health check
```bash
bash scripts/healthcheck.sh
# Exit code 0 = healthy, 1 = warnings, 2 = critical
```

### Restore from backup
```bash
# Restore latest:
bash scripts/restore.sh

# Restore specific backup:
bash scripts/restore.sh cloudops-monitor_20260709_120000.tar.gz
```

### Clean old files (dry run first)
```bash
bash scripts/cleanup.sh --dry-run   # preview
bash scripts/cleanup.sh             # execute
```

### Check cron jobs
```bash
crontab -l
```

---

## 📊 status.json Schema

All dashboard metrics are stored in `dashboard/status.json`. This file is written atomically by `monitor.sh` every 5 minutes via cron.

```json
{
    "hostname":       "ip-172-31-3-28",
    "user":           "ubuntu",
    "date":           "Wed Jul  9 14:45:00 UTC 2026",
    "uptime":         "up 1 hour, 2 minutes",
    "memory":         "411Mi/911Mi",
    "memory_percent": "45",
    "disk":           "34%",
    "disk_used":      "6.8G",
    "disk_total":     "20G",
    "cpu_percent":    "12",
    "load_avg":       "0.15 0.10 0.08",
    "os":             "Ubuntu 24.04.2 LTS",
    "kernel":         "6.8.0-1024-aws",
    "public_ip":      "54.123.45.67",
    "private_ip":     "172.31.3.28"
}
```

---

## 🔮 Future Improvements

| Feature | Priority |
|---|---|
| HTTPS with Let's Encrypt (Certbot) | High |
| Nginx access log analytics card | Medium |
| Multi-instance dashboard (multiple EC2s) | Medium |
| SNS/email alert when health check fails | Medium |
| Historical charts using Chart.js | Low |
| Docker containerisation | Low |
| Terraform IaC for EC2 + S3 provisioning | Low |

---

## 🔐 Security Notes

- **Nginx serves on port 80** — restrict Security Group to your IP in production
- **Never commit** `~/.aws/credentials` to git — use IAM Roles for EC2 instead
- **IMDSv2** is used for IP retrieval (more secure than IMDSv1)
- **status.json** contains hostname and IP — consider restricting Nginx access with `allow/deny` directives

---

## 🎤 Interview Talking Points

This project demonstrates:

1. **Linux fundamentals** — `free`, `df`, `uptime`, `/proc/stat`, `/proc/loadavg`, `systemctl`
2. **Bash scripting** — functions, `set -euo pipefail`, exit codes, logging, heredocs, atomic writes
3. **AWS services** — EC2, S3, IAM Roles, IMDSv2, Security Groups
4. **Nginx** — static file serving, virtual hosts, security headers, cache-control headers
5. **Cron** — scheduled automation, idempotent job installation
6. **DevOps practices** — monitoring, automated backups, health checks, log rotation
7. **Web fundamentals** — `fetch()` API, CSS custom properties, CSS Grid, responsive design

---

## 👤 Author

**Shreenath Mehta**

- Built as a DevOps portfolio project
- Platform: AWS EC2 · Ubuntu 24.04 · Nginx · Bash · Vanilla JS
- Inspired by: Grafana, Datadog, AWS Console, GitHub

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).
