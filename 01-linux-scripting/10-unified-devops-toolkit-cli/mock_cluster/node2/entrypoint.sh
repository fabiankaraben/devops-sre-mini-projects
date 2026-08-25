#!/usr/bin/env bash
set -e

echo "[NODE-2] Generating SSH host keys..."
ssh-keygen -A

echo "[NODE-2] Setting up root credentials..."
echo "root:password123" | chpasswd
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config

echo "[NODE-2] Starting OpenSSH server on port 22..."
exec /usr/sbin/sshd -D -e
