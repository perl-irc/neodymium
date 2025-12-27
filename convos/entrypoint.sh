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

# Start Tailscale daemon with in-memory state (ephemeral)
/usr/local/bin/tailscaled --state=mem: &
sleep 2

# Connect to Tailscale if auth key is provided
if [ -n "${TAILSCALE_AUTHKEY}" ]; then
    # Use machine ID suffix to avoid hostname clashes on restart
    MACHINE_SUFFIX=$(echo "${FLY_MACHINE_ID:-local}" | cut -c1-6)
    TS_HOSTNAME="magnet-convos-${MACHINE_SUFFIX}"
    /usr/local/bin/tailscale up --auth-key=${TAILSCALE_AUTHKEY} --hostname=${TS_HOSTNAME} --ssh --accept-dns=false
    echo "Connected to Tailscale as ${TS_HOSTNAME}"
else
    echo "TAILSCALE_AUTHKEY not set, skipping Tailscale"
fi

# Start Convos in background and wait (so trap can catch signals)
/app/script/convos daemon &
CONVOS_PID=$!
wait $CONVOS_PID
