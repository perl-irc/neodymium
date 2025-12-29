# ABOUTME: Convos IRC web client built from perl-irc/convos fork for MagNET
# ABOUTME: Builds from source with Tailscale SSH access, connects via Fly.io internal network

FROM alpine:latest

# Install runtime dependencies
RUN apk add --no-cache \
    curl \
    git \
    openssl \
    perl \
    perl-io-socket-ssl \
    perl-net-ssleay \
    wget

# Install build dependencies (will remove after build)
RUN apk add --no-cache --virtual builddeps \
    build-base \
    perl-dev

# Clone perl-irc/convos fork (magnet-main branch)
RUN git clone --depth 1 --branch magnet-main \
    https://github.com/perl-irc/convos.git /app

WORKDIR /app

# Install Convos and all Perl dependencies
ENV CONVOS_DEPENDENCIES=all
RUN /app/script/convos install --all

# Clean up build dependencies
RUN apk del builddeps && \
    rm -rf /root/.cpanm /var/cache/apk/*

# Copy Tailscale binaries from official image
COPY --from=tailscale/tailscale:latest /usr/local/bin/tailscaled /usr/local/bin/tailscaled
COPY --from=tailscale/tailscale:latest /usr/local/bin/tailscale /usr/local/bin/tailscale

# Create directories
RUN mkdir -p /data /var/run/tailscale /var/lib/tailscale

# Copy entrypoint
COPY convos/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# Production environment
ENV CONVOS_HOME=/data
ENV CONVOS_NO_ROOT_WARNING=1
ENV MOJO_MODE=production

VOLUME ["/data"]
EXPOSE 3000

ENTRYPOINT ["/app/entrypoint.sh"]
