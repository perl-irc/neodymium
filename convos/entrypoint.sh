#!/bin/sh
# ABOUTME: Convos startup script with Tailscale SSH access
# ABOUTME: Starts Tailscale for admin SSH, then runs Convos

# Start Tailscale daemon with in-memory state (ephemeral)
/usr/local/bin/tailscaled --state=mem: &
sleep 2

# Connect to Tailscale if auth key is provided
if [ -n "${TAILSCALE_AUTHKEY}" ]; then
    /usr/local/bin/tailscale up --auth-key=${TAILSCALE_AUTHKEY} --hostname=magnet-convos --ssh --accept-dns=false
    echo "Connected to Tailscale as magnet-convos"
else
    echo "TAILSCALE_AUTHKEY not set, skipping Tailscale"
fi

# Start Convos (exec replaces shell for proper signal handling)
exec /app/script/convos daemon
