#!/bin/sh
# ABOUTME: Solanum IRCd startup script with dynamic host configuration based on Fly.io region
# ABOUTME: Generates SID and server name dynamically from FLY_REGION and machine count
# Cache buster: v2024-08-30-1

set -e

# Start Tailscale daemon with in-memory state (ephemeral)
# Node is auto-removed from tailnet when container stops
/usr/local/bin/tailscaled --state=mem: &

# Wait for daemon to start
sleep 3

# Connect to Tailscale network (using same logic as atheme)
/usr/local/bin/tailscale up --auth-key=${TAILSCALE_AUTHKEY} --hostname=${SERVER_NAME} --ssh --accept-dns=false

echo "Connected to Tailscale as ${HOSTNAME}"

chown ircd:ircd -R /opt/solanum
find /opt/solanum -type d -exec chmod 755 {} \;
find /opt/solanum -type f -exec chmod 644 {} \;
find /opt/solanum/bin -type f -exec chmod 755 {} \;

# Verify directories exist (should be created by Dockerfile)
echo "Verifying directory setup..."
df -h /opt/solanum
ls -la /opt/solanum/*

# Generate dynamic SID and server name from region
echo "Generating dynamic server configuration..."

# Get region prefix (first 2 chars, uppercase)
REGION_PREFIX=$(echo "${FLY_REGION}" | cut -c1-2 | tr '[:lower:]' '[:upper:]')

# Try to get machine count via DNS SRV query
# Note: This might need adjustment based on actual Fly.io DNS structure
MACHINE_COUNT=$(nslookup -type=SRV ${FLY_APP_NAME}.internal 2>/dev/null | grep "\.${FLY_REGION}\." | wc -l || echo "0")

# If DNS query fails, try to extract from hostname or default to 1
if [ "$MACHINE_COUNT" = "0" ]; then
    # Try to extract number from hostname if it follows a pattern
    if echo "${FLY_MACHINE_ID}" | grep -q '^[0-9]'; then
        SERVER_NUMBER=$(echo "${FLY_MACHINE_ID}" | sed 's/[^0-9].*//g')
    else
        SERVER_NUMBER=1
    fi
else
    SERVER_NUMBER=$((MACHINE_COUNT + 1))
fi

# Generate SID (server number + region prefix)
export SERVER_SID="${SERVER_NUMBER}${REGION_PREFIX}"
export SERVER_NAME="magnet-${FLY_REGION}"
export SERVER_DESCRIPTION="Magnet IRC Network - ${FLY_REGION} Server"

echo "Dynamic configuration:"
echo "  Region: ${FLY_REGION}"
echo "  Region Prefix: ${REGION_PREFIX}"
echo "  Server Number: ${SERVER_NUMBER}"
echo "  Server SID: ${SERVER_SID}"
echo "  Server Name: ${SERVER_NAME}"

# Use environment variables (secrets) - REQUIRED, no fallbacks
echo "Using passwords from environment variables..."

# Check required secrets are present
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

# Process server-specific configuration and concatenate with common config
echo "Processing server-specific configuration..."
if [ -f /opt/solanum/conf/server.conf.template ]; then
    echo "Building complete ircd.conf from server.conf + common.conf + opers.conf"
    
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

# Keep container running and monitor Solanum process
while true; do
    if ! check_solanum; then
        echo "Solanum process died, initiating cleanup and exit"
        cleanup
        exit 1
    fi
    sleep 15
done