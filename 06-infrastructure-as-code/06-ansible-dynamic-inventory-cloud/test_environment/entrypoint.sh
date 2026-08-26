#!/bin/sh
set -e

mkdir -p /app

if [ ! -f /app/version.txt ]; then
    echo "${FLEET_VERSION:-1.0.0}" > /app/version.txt
fi

if [ ! -f /app/config.json ]; then
    cat <<EOF > /app/config.json
{
  "app": "${FLEET_APP:-frontend}",
  "environment": "${FLEET_ENVIRONMENT:-production}",
  "role": "${FLEET_ROLE:-web}",
  "port": ${APP_PORT:-8080},
  "max_connections": 100,
  "keepalive_timeout": 65
}
EOF
fi

# Execute application server
exec python3 /app/app.py
