#!/bin/sh
# ABOUTME: Atheme IRC services startup script with Tailscale integration
# ABOUTME: Handles ephemeral Tailscale auth, password generation, and opensex flat file backend

set -e

# Trap signals to ensure clean Tailscale logout
cleanup() {
    echo "Received shutdown signal, logging out of Tailscale..."
    /usr/local/bin/tailscale logout 2>/dev/null || true
    exit 0
}
trap cleanup TERM INT

# Start Tailscale daemon with persistent state
# Cleanup is handled by explicit logout on shutdown signal
mkdir -p /var/lib/tailscale
/usr/local/bin/tailscaled --state=/var/lib/tailscale/tailscaled.state &

# Wait for daemon to start
sleep 5

# Connect to Tailscale network
/usr/local/bin/tailscale up --auth-key=${TAILSCALE_AUTHKEY} --hostname=${SERVER_NAME:-atheme} --ssh --accept-dns=true

echo "Connected to Tailscale as ${SERVER_NAME:-atheme}"

# Fix permissions for volume mount (happens after volume is attached)
echo "Setting up volume mount permissions..."
chown -R atheme:atheme /opt/atheme/
find /opt/atheme -type d -exec chmod 755 {} \;
find /opt/atheme -type f -exec chmod 644 {} \;
find /opt/atheme/bin -type f -exec chmod 755 {} \;


# Use Fly.io secrets directly - no password generation needed
echo "Using passwords from Fly.io secrets..."

# Verify required secrets are present
if [ -z "${SERVICES_PASSWORD}" ]; then
    echo "ERROR: SERVICES_PASSWORD secret not set!"
    exit 1
fi

if [ -z "${PASSWORD_9RL}" ]; then
    echo "ERROR: PASSWORD_9RL secret not set!"
    exit 1
fi

# Process atheme.conf template with generated passwords
echo "Instantiating atheme.conf from template..."

# Atheme uses opensex flat file backend - no database configuration needed

envsubst < /opt/atheme/atheme.conf.template > /opt/atheme/etc/atheme.conf
chown atheme:atheme /opt/atheme/etc/atheme.conf
chmod 644 /opt/atheme/etc/atheme.conf

echo "Atheme configuration instantiated successfully"
echo "Tailscale hostname: ${HOSTNAME}"
echo "Services password: ${SERVICES_PASSWORD}"

# Simple HTTP health endpoint
(while true; do
    echo -e "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nAtheme Services Health OK" | nc -l -p 8080
done) &

# Cleanup function - only called when health check fails
cleanup() {
    echo "Atheme unhealthy, cleaning up..."
    echo "Logging out of Tailscale..."
    /usr/local/bin/tailscale logout 2>/dev/null || true
    echo "Cleanup complete"
}

# Function to check if atheme is running
check_atheme() {
    pgrep -f "atheme-services" > /dev/null
}

# Find and start Atheme binary - Atheme is installed with --prefix=/opt/atheme
ATHEME_BIN="/opt/atheme/bin/atheme-services"

if [ ! -f "$ATHEME_BIN" ]; then
    echo "ERROR: Could not find atheme-services at $ATHEME_BIN"
    echo "Available executables in /opt/atheme/bin:"
    ls -la /opt/atheme/bin/ 2>/dev/null || echo "Directory /opt/atheme/bin does not exist"
    exit 1
fi

echo "Using atheme binary: $ATHEME_BIN"

# Start Atheme as atheme user in daemon mode
echo "Starting atheme with: $ATHEME_BIN"

# Check if database exists, if not create it with -b flag then start normally
# Database is stored on the persistent volume at /var/lib/atheme
export DB_PATH="/opt/atheme/etc/services.db"
if [ ! -f "$DB_PATH" ]; then
    echo "Database does not exist, creating it on first run..."
    su-exec atheme "$ATHEME_BIN" -n -b
    echo "Database created, now starting normally..."
fi

echo "Starting Atheme services normally..."
su-exec atheme "$ATHEME_BIN" -n

# Keep container running and monitor Atheme process
while true; do
    sleep 5
    if ! check_atheme; then
        echo "Atheme process died, initiating cleanup and exit"
        cleanup
        exit 1
    fi
    sleep 10
done
