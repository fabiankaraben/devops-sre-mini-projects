#!/bin/bash
set -eu

echo "[GATEWAY] Generating SSH Host Keys..."
ssh-keygen -A

echo "[GATEWAY] Applying firewall rules..."
# Apply iptables packet drop rule on port 9999 to simulate a silent firewall DROP (FILTERED port)
iptables -F || true
iptables -A INPUT -p tcp --dport 9999 -j DROP || true

# Start background dummy listener on port 8443
python3 -c "
import socket, threading

def srv():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(('0.0.0.0', 8443))
    s.listen(5)
    while True:
        try:
            conn, addr = s.accept()
            conn.sendall(b'Secure Gateway Management Console v2.1\n')
            conn.close()
        except Exception:
            pass

threading.Thread(target=srv, daemon=True).start()
import time
while True:
    time.sleep(3600)
" &

echo "[GATEWAY] Starting OpenSSH server on port 22..."
exec /usr/sbin/sshd -D -e
