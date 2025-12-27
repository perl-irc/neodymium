# ABOUTME: Convos IRC web client with Tailscale integration
# ABOUTME: Provides persistent IRC bouncer with modern web UI for MagNET

FROM ghcr.io/convos-chat/convos:stable

USER root

# Install Tailscale
RUN apt-get update && apt-get install -y \
    curl \
    ca-certificates \
    && curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null \
    && curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list \
    && apt-get update \
    && apt-get install -y tailscale \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Create directories
RUN mkdir -p /data /var/run/tailscale

# Copy entrypoint
COPY convos/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

EXPOSE 3000

ENTRYPOINT ["/app/entrypoint.sh"]
