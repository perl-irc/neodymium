# ABOUTME: Convos IRC web client for MagNET with Tailscale SSH access
# ABOUTME: Persistent IRC bouncer with modern web UI, connects via Fly.io internal network

FROM ghcr.io/convos-chat/convos:v8.07

USER root

# Copy Tailscale binaries from official image
COPY --from=tailscale/tailscale:latest /usr/local/bin/tailscaled /usr/local/bin/tailscaled
COPY --from=tailscale/tailscale:latest /usr/local/bin/tailscale /usr/local/bin/tailscale

# Create directories
RUN mkdir -p /data /var/run/tailscale

# Copy entrypoint
COPY convos/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

ENV CONVOS_HOME=/data

EXPOSE 3000

ENTRYPOINT ["/app/entrypoint.sh"]
