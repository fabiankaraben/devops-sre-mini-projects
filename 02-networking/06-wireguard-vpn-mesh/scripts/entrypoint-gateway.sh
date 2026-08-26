#!/usr/bin/env bash
# ==============================================================================
# WireGuard Gateway Node Entrypoint Script
# ==============================================================================
set -euo pipefail

NODE_NAME="${NODE_NAME:-gateway}"
NODE_ID="${NODE_ID:-node-a}"
WG_CONF="/etc/wireguard/wg0.conf"

echo "=========================================================="
echo " Starting WireGuard Gateway: ${NODE_NAME} (ID: ${NODE_ID})"
echo "=========================================================="

mkdir -p /etc/wireguard

if [ -f "/config/${NODE_ID}/wg0.conf" ]; then
  cp "/config/${NODE_ID}/wg0.conf" "${WG_CONF}"
elif [ -f "/config/wg0.conf" ]; then
  cp "/config/wg0.conf" "${WG_CONF}"
fi

if [ -f "${WG_CONF}" ]; then
  chmod 600 "${WG_CONF}" 2>/dev/null || true
fi

if [ ! -f "${WG_CONF}" ]; then
  echo "[-] ERROR: WireGuard configuration file not found at ${WG_CONF}" >&2
  exit 1
fi

# Ensure /dev/net/tun exists if needed
if [ ! -c /dev/net/tun ]; then
  mkdir -p /dev/net
  mknod /dev/net/tun c 10 200 || true
  chmod 600 /dev/net/tun || true
fi

# Enable IP forwarding inside the container
echo "[+] Enabling IPv4 packet forwarding..."
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

# Bring up WireGuard interface
echo "[+] Bringing up WireGuard interface (wg0)..."
wg-quick up wg0

# Configure iptables forwarding & NAT
echo "[+] Configuring iptables packet forwarding & NAT rules..."
iptables -A FORWARD -i wg0 -j ACCEPT || true
iptables -A FORWARD -o wg0 -j ACCEPT || true
iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE || true
iptables -t nat -A POSTROUTING -s 10.0.0.0/8 -j MASQUERADE || true

echo "[+] WireGuard Interface Status:"
wg show wg0

echo "[+] IP Routing Table:"
ip route

echo "=========================================================="
echo " WireGuard Gateway [${NODE_NAME}] is READY and ROUTING"
echo "=========================================================="

# Graceful shutdown handler
cleanup() {
  echo "[+] Shutting down WireGuard interface..."
  wg-quick down wg0 || true
  echo "[+] Gateway stopped cleanly."
  exit 0
}

trap cleanup SIGTERM SIGINT

# Keep container running and periodically log handshake status
while true; do
  sleep 3600 &
  wait $!
done
