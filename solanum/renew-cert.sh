#!/bin/sh
# ABOUTME: Certificate renewal script for Let's Encrypt certs
# ABOUTME: Called by cron to periodically renew SSL certificates

set -e

# Renew certificates using certbot
certbot renew --quiet --deploy-hook /opt/solanum/bin/renew-hook.sh
