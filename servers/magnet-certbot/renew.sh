#!/bin/sh
# ABOUTME: SSL certificate renewal script for magnet-certbot
# ABOUTME: Gets Let's Encrypt cert and pushes to all magnet-irc machines via SSH

set -e

echo "Starting SSL certificate renewal..."

# Build domain arguments
DOMAIN_ARGS=""
for domain in $(echo "${SSL_DOMAINS}" | tr ',' ' '); do
    DOMAIN_ARGS="$DOMAIN_ARGS -d $domain"
done

echo "Requesting certificate for domains: ${SSL_DOMAINS}"

# Run certbot in standalone mode (serves its own HTTP on port 80)
certbot certonly \
    --standalone \
    --non-interactive \
    --agree-tos \
    --email "${ADMIN_EMAIL}" \
    --key-type rsa \
    --rsa-key-size 4096 \
    $DOMAIN_ARGS

# Get the primary domain for cert path
PRIMARY_DOMAIN=$(echo "${SSL_DOMAINS}" | cut -d',' -f1)

echo "Certificate obtained for ${PRIMARY_DOMAIN}"

# Push certs to all running magnet-irc machines (zero downtime)
echo "Pushing certificates to running ${TARGET_APP} machines..."
CERT_FILE="/etc/letsencrypt/live/${PRIMARY_DOMAIN}/fullchain.pem"
KEY_FILE="/etc/letsencrypt/live/${PRIMARY_DOMAIN}/privkey.pem"

# Get list of running machines
MACHINES=$(flyctl machines list -a "${TARGET_APP}" --json | jq -r '.[] | select(.state == "started") | .id')

if [ -z "$MACHINES" ]; then
    echo "WARNING: No running machines found for ${TARGET_APP}"
    echo "Certificates obtained but not pushed. Run renewal again when machines are running."
    exit 0
fi

for machine in $MACHINES; do
    echo "Updating machine ${machine}..."

    # Write cert files directly via SSH
    cat "$CERT_FILE" | flyctl ssh console -a "${TARGET_APP}" -s "${machine}" \
        -C "cat > /opt/solanum/etc/ssl.pem"
    cat "$KEY_FILE" | flyctl ssh console -a "${TARGET_APP}" -s "${machine}" \
        -C "cat > /opt/solanum/etc/ssl.key"

    # Fix permissions
    flyctl ssh console -a "${TARGET_APP}" -s "${machine}" \
        -C "chmod 600 /opt/solanum/etc/ssl.pem /opt/solanum/etc/ssl.key && chown ircd:ircd /opt/solanum/etc/ssl.pem /opt/solanum/etc/ssl.key"

    # Rehash Solanum to reload certs (zero downtime)
    flyctl ssh console -a "${TARGET_APP}" -s "${machine}" \
        -C "pkill -HUP solanum"

    echo "Machine ${machine} updated"
done

echo "Certificate renewal complete - zero downtime"
