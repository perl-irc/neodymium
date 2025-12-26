#!/bin/sh
# ABOUTME: Post-renewal hook for Let's Encrypt certificate updates
# ABOUTME: Reloads Solanum after certificate renewal

set -e

# Signal Solanum to reload its configuration (and certificates)
pkill -HUP solanum || true
