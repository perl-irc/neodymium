#!/bin/sh
# ABOUTME: Post-renewal hook for Let's Encrypt certificate updates
# ABOUTME: Reloads Solanum after certificate renewal

set -e

# Fix permissions so ircd user can read renewed certificates
# Let's Encrypt creates new files with 700 permissions by default
chmod 755 /etc/letsencrypt/archive /etc/letsencrypt/live
for domain_dir in /etc/letsencrypt/archive/*/; do
    chmod 755 "$domain_dir"
done
for domain_dir in /etc/letsencrypt/live/*/; do
    chmod 755 "$domain_dir"
done

# Signal Solanum to reload its configuration (and certificates)
pkill -HUP solanum || true
