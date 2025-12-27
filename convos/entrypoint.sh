#!/bin/sh
# ABOUTME: Convos startup script with Tailscale SSH access
# ABOUTME: Starts Tailscale for admin SSH, then runs Convos

set -e

# Start Tailscale daemon in background
mkdir -p /var/lib/tailscale
/usr/local/bin/tailscaled --state=/var/lib/tailscale/tailscaled.state &
TAILSCALED_PID=$!
sleep 2

# Connect to Tailscale if auth key is provided (non-blocking)
if [ -n "${TAILSCALE_AUTHKEY}" ]; then
    /usr/local/bin/tailscale up --auth-key=${TAILSCALE_AUTHKEY} --hostname=magnet-convos --ssh --accept-dns=false &
    echo "Tailscale connection initiated"
else
    echo "TAILSCALE_AUTHKEY not set, skipping Tailscale"
fi

# Run Convos in foreground (exec replaces shell process)
exec /app/script/convos daemon
