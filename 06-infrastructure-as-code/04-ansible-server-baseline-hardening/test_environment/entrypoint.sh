#!/usr/bin/env bash
set -e

# Ensure privilege separation directory exists
mkdir -p /var/run/sshd /var/log

# Start sshd service in background
/usr/sbin/service ssh start || /usr/sbin/sshd

# Keep container running
exec tail -f /dev/null
