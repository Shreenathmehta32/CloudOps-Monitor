#!/bin/bash

HOSTNAME=$(hostname)
USER=$(whoami)
DATE=$(date)
UPTIME=$(uptime -p)
MEMORY=$(free -h | awk '/Mem:/ {print $3 "/" $2}')
DISK=$(df -h / | awk 'NR==2 {print $5}')

cat <<EOF > ../dashboard/status.json
{
    "hostname": "$HOSTNAME",
    "user": "$USER",
    "date": "$DATE",
    "uptime": "$UPTIME",
    "memory": "$MEMORY",
    "disk": "$DISK"
}
EOF

echo "Status updated successfully!"
