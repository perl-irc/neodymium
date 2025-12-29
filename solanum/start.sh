#!/bin/sh
# ABOUTME: Solanum IRCd startup script with Fly.io networking and go-mmproxy integration
# ABOUTME: Handles PROXY protocol translation, password generation, and IRC server startup
# Cache buster: v2024-12-26-2

set -e

# Trap signals to ensure clean Tailscale logout
cleanup() {
    echo "Received shutdown signal, logging out of Tailscale..."
    /usr/local/bin/tailscale logout 2>/dev/null || true
    exit 0
}
trap cleanup TERM INT

# Dynamic identity from FLY_REGION for anycast leaf servers
# Hub servers set SERVER_NAME explicitly in fly.toml, leaf servers derive it
if [ -z "${SERVER_NAME}" ]; then
    # Derive from FLY_REGION for leaf servers
    REGION="${FLY_REGION:-local}"
    export SERVER_NAME="magnet-${REGION}"
    # SID must start with digit (0-9), then 2 alphanumeric chars
    # Use "0" + first 2 chars of uppercase region (e.g., ord -> 0OR, ams -> 0AM)
    REGION_UPPER=$(echo "${REGION}" | tr '[:lower:]' '[:upper:]')
    export SERVER_SID="0$(echo "${REGION_UPPER}" | head -c 2)"
    export SERVER_DESCRIPTION="MagNET IRC - ${REGION}"
    export IS_LEAF_SERVER=1
    echo "Dynamic identity: SERVER_NAME=${SERVER_NAME}, SERVER_SID=${SERVER_SID}"
fi

# Start Tailscale daemon with persistent state
# Cleanup is handled by explicit logout on shutdown signal
mkdir -p /var/lib/tailscale
/usr/local/bin/tailscaled --state=/var/lib/tailscale/tailscaled.state &

# Wait for daemon to start
sleep 3

# Connect to Tailscale network
/usr/local/bin/tailscale up --auth-key=${TAILSCALE_AUTHKEY} --hostname=${SERVER_NAME} --ssh --accept-dns=false

# Get Tailscale IP for direct client connections (bypasses go-mmproxy)
export TAILSCALE_IP=$(/usr/local/bin/tailscale ip -4)
echo "Connected to Tailscale as ${SERVER_NAME} (${TAILSCALE_IP})"

# Set up routing rules for go-mmproxy
# These rules ensure that responses from Solanum (with spoofed source IPs) get routed
# back through go-mmproxy on the loopback interface
echo "Setting up go-mmproxy routing rules..."

# IPv4 routing: route loopback-originated traffic to special table
ip rule add from 127.0.0.1/8 iif lo table 123 2>/dev/null || true
ip route add local 0.0.0.0/0 dev lo table 123 2>/dev/null || true

# IPv6 routing: same for IPv6
ip -6 rule add from ::1/128 iif lo table 123 2>/dev/null || true
ip -6 route add local ::/0 dev lo table 123 2>/dev/null || true

echo "Routing rules configured"

# Start go-mmproxy instances for client ports
# go-mmproxy unwraps PROXY protocol from Fly.io edge and spoofs client IP
# IMPORTANT: Fly.io routes to 0.0.0.0:<internal_port>, so we must bind to 0.0.0.0
# Using ports 6668/6698 to avoid conflict with Solanum's Tailscale listener on 6667/6697
echo "Starting go-mmproxy for PROXY protocol handling..."

# Plain IRC (external 6667 -> internal 6668 -> Solanum 16667)
/usr/local/bin/go-mmproxy -l 0.0.0.0:6668 -4 127.0.0.1:16667 -6 [::1]:16667 -v 1 &
MMPROXY_6668_PID=$!

# SSL IRC (external 6697 -> internal 6698 -> Solanum 16697)
/usr/local/bin/go-mmproxy -l 0.0.0.0:6698 -4 127.0.0.1:16697 -6 [::1]:16697 -v 1 &
MMPROXY_6698_PID=$!

sleep 1

# Verify go-mmproxy is running
if ! kill -0 $MMPROXY_6668_PID 2>/dev/null; then
    echo "ERROR: go-mmproxy for port 6668 failed to start"
    exit 1
fi
if ! kill -0 $MMPROXY_6698_PID 2>/dev/null; then
    echo "ERROR: go-mmproxy for port 6698 failed to start"
    exit 1
fi

echo "go-mmproxy started (PIDs: $MMPROXY_6668_PID, $MMPROXY_6698_PID)"

# Start nginx for fly-replay routing
# Routes ACME challenges to magnet-certbot, everything else to magnet-convos
echo "Starting nginx for fly-replay routing..."
nginx
echo "nginx started"

chown ircd:ircd -R /opt/solanum
find /opt/solanum -type d -exec chmod 755 {} \;
find /opt/solanum -type f -exec chmod 644 {} \;
find /opt/solanum/bin -type f -exec chmod 755 {} \;

# Verify directories exist (should be created by Dockerfile)
echo "Verifying directory setup..."
df -h /opt/solanum
ls -la /opt/solanum/*


# Use environment variables (secrets) - REQUIRED, no fallbacks
echo "Using passwords from environment variables..."

# Check required secrets based on server type
if [ -n "${IS_LEAF_SERVER}" ]; then
    # Leaf servers (magnet-irc) need hub connection passwords
    echo "Checking leaf server secrets..."
    if [ -z "${HUB_PASSWORD}" ]; then
        echo "ERROR: HUB_PASSWORD secret not set!"
        exit 1
    fi
    if [ -z "${LEAF_PASSWORD}" ]; then
        echo "ERROR: LEAF_PASSWORD secret not set!"
        exit 1
    fi
else
    # Hub and legacy servers need full password set
    echo "Checking hub/legacy server secrets..."
    if [ -z "${PASSWORD_9RL}" ]; then
        echo "ERROR: PASSWORD_9RL secret not set!"
        exit 1
    fi

    if [ -z "${PASSWORD_1EU}" ]; then
        echo "ERROR: PASSWORD_1EU secret not set!"
        exit 1
    fi

    if [ -z "${OPERATOR_PASSWORD}" ]; then
        echo "ERROR: OPERATOR_PASSWORD secret not set!"
        exit 1
    fi

    if [ -z "${SERVICES_PASSWORD}" ]; then
        echo "ERROR: SERVICES_PASSWORD secret not set!"
        exit 1
    fi
fi

# Extract SID from server name if not explicitly set (e.g., magnet-9rl -> 9RL)
if [ -z "${SERVER_SID}" ]; then
    SERVER_SID=$(echo "${SERVER_NAME}" | sed 's/magnet-//' | tr '[:lower:]' '[:upper:]')
fi

# SSL certificate configuration
# Real Let's Encrypt certs are pushed by magnet-certbot via SSH
# Self-signed certs are generated on startup as fallback
SSL_CERT="/opt/solanum/etc/ssl.pem"
SSL_KEY="/opt/solanum/etc/ssl.key"
SSL_DH="/opt/solanum/etc/dh.pem"

# Generate self-signed certificate if none exists
# magnet-certbot will push real certs and SIGHUP to reload
if [ ! -f "$SSL_CERT" ] || [ ! -f "$SSL_KEY" ]; then
    SSL_CN="${FLY_APP_NAME:-$SERVER_NAME}.fly.dev"
    echo "Generating self-signed SSL certificate for ${SSL_CN}..."
    openssl req -x509 -nodes -newkey rsa:4096 \
        -keyout "$SSL_KEY" \
        -out "$SSL_CERT" \
        -days 365 \
        -subj "/C=US/ST=State/L=City/O=MagNET IRC Network/CN=${SSL_CN}"
fi

# Generate DH parameters if they don't exist
if [ ! -f "$SSL_DH" ]; then
    echo "Generating DH parameters (this may take a while)..."
    openssl dhparam -out "$SSL_DH" 2048
fi

# Set proper permissions
chmod 600 "$SSL_KEY" "$SSL_CERT" "$SSL_DH" 2>/dev/null
chown ircd:ircd "$SSL_KEY" "$SSL_CERT" "$SSL_DH" 2>/dev/null

echo "SSL configuration complete"

# Process server-specific configuration and concatenate with common config
echo "Processing server-specific configuration..."
if [ -f /opt/solanum/conf/server.conf.template ]; then
    echo "Building complete ircd.conf from server.conf + common.conf + opers.conf"

    # Hash oper password from secret (Tailscale provides real auth, this is protocol compliance)
    export OPER_PASSWORD_HASH=$(mkpasswd "${OPERATOR_PASSWORD}")

    # Process all templates
    envsubst < /opt/solanum/conf/server.conf.template > /tmp/server.conf
    envsubst < /opt/solanum/conf/common.conf.template > /tmp/common.conf
    envsubst < /opt/solanum/conf/opers.conf.template > /tmp/opers.conf

    # Concatenate into final ircd.conf
    cat /tmp/server.conf /tmp/common.conf /tmp/opers.conf > /opt/solanum/etc/ircd.conf

    # Cleanup temp files
    rm /tmp/server.conf /tmp/common.conf /tmp/opers.conf
else
    echo "ERROR: No server-specific configuration found at /opt/solanum/conf/server.conf.template"
    echo "Each server must have its own server.conf file in the build context"
    exit 1
fi

chown ircd:ircd /opt/solanum/etc/ircd.conf
chmod 600 /opt/solanum/etc/ircd.conf

# Test Solanum configuration
su-exec ircd /opt/solanum/bin/solanum -configfile /opt/solanum/etc/ircd.conf -conftest

# Cleanup function - only called when health check fails
cleanup() {
    echo "Solanum unhealthy, cleaning up..."
    echo "Logging out of Tailscale..."
    /usr/local/bin/tailscale logout 2>/dev/null || true
    echo "Cleanup complete"
}

# Remove stale PID file from previous instance (volume persists across restarts)
if [ -f /opt/solanum/etc/ircd.pid ]; then
    echo "Removing stale PID file from previous instance..."
    rm -f /opt/solanum/etc/ircd.pid
fi

# Start Solanum as ircd user (foreground mode for debugging)
echo "Starting Solanum in foreground mode for debugging..."

su-exec ircd /opt/solanum/bin/solanum -foreground -configfile /opt/solanum/etc/ircd.conf

# Wait a moment for daemon to start
sleep 2

# Function to check if Solanum is still running
check_solanum() {
    if ! pgrep -f "/opt/solanum/bin/solanum" > /dev/null; then
        echo "Solanum process died, exiting health endpoint"
        return 1
    fi
}

# Function to check if go-mmproxy instances are still running
check_mmproxy() {
    if ! pgrep -f "go-mmproxy.*:6668" > /dev/null; then
        echo "go-mmproxy (6668) process died"
        return 1
    fi
    if ! pgrep -f "go-mmproxy.*:6698" > /dev/null; then
        echo "go-mmproxy (6698) process died"
        return 1
    fi
}

# Keep container running and monitor processes
while true; do
    if ! check_solanum; then
        echo "Solanum process died, initiating cleanup and exit"
        cleanup
        exit 1
    fi
    if ! check_mmproxy; then
        echo "go-mmproxy process died, initiating cleanup and exit"
        cleanup
        exit 1
    fi
    sleep 15
done
