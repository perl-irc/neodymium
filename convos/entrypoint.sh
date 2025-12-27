#!/bin/sh
# ABOUTME: Convos startup script with Tailscale SSH access
# ABOUTME: Starts Tailscale for admin SSH, then runs Convos

# Trap signals to ensure clean Tailscale logout
cleanup() {
    echo "Received shutdown signal, logging out of Tailscale..."
    /usr/local/bin/tailscale logout 2>/dev/null || true
    kill $CONVOS_PID 2>/dev/null || true
    exit 0
}
trap cleanup TERM INT

# Start Tailscale daemon with persistent state
# Cleanup is handled by explicit logout on shutdown signal
mkdir -p /var/lib/tailscale
/usr/local/bin/tailscaled --state=/var/lib/tailscale/tailscaled.state &
sleep 2

# Connect to Tailscale if auth key is provided (non-blocking)
# Run in background so Convos starts even if Tailscale auth fails
if [ -n "${TAILSCALE_AUTHKEY}" ]; then
    (
        /usr/local/bin/tailscale up --auth-key=${TAILSCALE_AUTHKEY} --hostname=magnet-convos --ssh --accept-dns=false && \
        echo "Connected to Tailscale as magnet-convos" || \
        echo "Tailscale connection failed (non-fatal)"
    ) &
else
    echo "TAILSCALE_AUTHKEY not set, skipping Tailscale"
fi

# Start Convos in background and wait (so trap can catch signals)
/app/script/convos daemon &
CONVOS_PID=$!
wait $CONVOS_PID
