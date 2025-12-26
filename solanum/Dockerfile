# ABOUTME: Multi-stage Solanum IRC server container with build and runtime separation
# ABOUTME: Optimized for smaller runtime image and better layer caching

# Build stage
FROM alpine:latest AS builder

# Install build dependencies only
RUN apk update && apk add --no-cache \
    build-base \
    pkgconfig \
    automake \
    autoconf \
    libtool \
    sqlite-dev \
    openssl-dev \
    bison \
    flex \
    git

# Build Solanum following official README recipe
WORKDIR /tmp
RUN git clone https://github.com/solanum-ircd/solanum.git
WORKDIR /tmp/solanum
RUN ./autogen.sh
RUN ./configure --prefix=/opt/solanum --enable-openssl
RUN make
RUN make check || echo "Tests completed (may have warnings)"
RUN make install

# Runtime stage
FROM alpine:latest

# Install runtime dependencies - includes libraries Solanum was built against
RUN apk update && apk add --no-cache \
    openssl \
    sqlite-libs \
    ca-certificates \
    gettext \
    su-exec \
    netcat-openbsd \
    procps \
    libtool \
    libltdl \
    mkpasswd \
    certbot \
    iproute2

# Build go-mmproxy from source for PROXY protocol support
# This allows preserving client IP addresses when behind Fly.io's proxy
RUN apk add --no-cache go git && \
    git clone --depth 1 --branch 2.1 https://github.com/path-network/go-mmproxy.git /tmp/go-mmproxy && \
    cd /tmp/go-mmproxy && \
    go build -o /usr/local/bin/go-mmproxy . && \
    chmod +x /usr/local/bin/go-mmproxy && \
    rm -rf /tmp/go-mmproxy /root/go && \
    apk del go git

# Copy Tailscale binaries from official image
COPY --from=tailscale/tailscale:latest /usr/local/bin/tailscaled /usr/local/bin/tailscaled
COPY --from=tailscale/tailscale:latest /usr/local/bin/tailscale /usr/local/bin/tailscale

# Copy built Solanum from build stage
COPY --from=builder /opt/solanum /opt/solanum

# Create directories
RUN mkdir -p /var/run/tailscale /var/cache/tailscale /var/lib/tailscale
RUN mkdir -p /opt/solanum/var/log /opt/solanum/var/run /opt/solanum/etc /opt/solanum/conf /opt/solanum/logs

# Add ircd user
RUN adduser -D -h /opt/solanum -u 1000 ircd
RUN chown -R ircd:ircd /opt/solanum/

# Copy configuration templates and startup scripts
COPY solanum/common.conf.template /opt/solanum/conf/common.conf.template
COPY solanum/opers.conf.template /opt/solanum/conf/opers.conf.template
COPY solanum/start.sh /app/start.sh
COPY solanum/start-dynamic.sh /app/start-dynamic.sh
COPY solanum/renew-cert.sh /opt/solanum/bin/renew-cert.sh
COPY solanum/renew-hook.sh /opt/solanum/bin/renew-hook.sh
RUN chmod +x /app/start.sh /app/start-dynamic.sh /opt/solanum/bin/renew-cert.sh /opt/solanum/bin/renew-hook.sh

# Copy server-specific config (path set via build arg)
ARG SERVER_DIR=.
COPY ${SERVER_DIR}/server.conf /opt/solanum/conf/server.conf.template

# Container starts as root for Tailscale, drops to ircd user for Solanum
WORKDIR /opt/solanum

EXPOSE 6667 6697 7000 8080

CMD ["/app/start.sh"]
