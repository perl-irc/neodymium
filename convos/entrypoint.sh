#!/bin/bash
# ABOUTME: Convos startup script with Tailscale integration
# ABOUTME: Connects to Tailscale network then starts Convos web client

set -e

# Start Tailscale daemon with in-memory state (ephemeral)
# Node is auto-removed from tailnet when container stops
/usr/sbin/tailscaled --state=mem: &

# Wait for daemon to start
sleep 3

# Connect to Tailscale network
/usr/bin/tailscale up --auth-key=${TAILSCALE_AUTHKEY} --hostname=magnet-convos --ssh --accept-dns=true

# Get Tailscale IP for logging
TAILSCALE_IP=$(/usr/bin/tailscale ip -4)
echo "Connected to Tailscale as magnet-convos (${TAILSCALE_IP})"

# Start Convos (exec to replace shell, proper signal handling)
exec /app/script/convos daemon
