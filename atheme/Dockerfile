# ABOUTME: Atheme IRC services container with PostgreSQL support
# ABOUTME: Builds and runs Atheme services with database connectivity

FROM alpine:latest

# Install build and runtime dependencies for Atheme
RUN apk update && apk add --no-cache \
    build-base \
    pkgconfig \
    automake \
    autoconf \
    libtool \
    git \
    ca-certificates \
    gettext \
    su-exec \
    netcat-openbsd \
    procps \
    openssl-dev \
    openssl \
    pcre2-dev

# Copy Tailscale binaries from official image
COPY --from=tailscale/tailscale:latest /usr/local/bin/tailscaled /usr/local/bin/tailscaled
COPY --from=tailscale/tailscale:latest /usr/local/bin/tailscale /usr/local/bin/tailscale

# Build Atheme from source
WORKDIR /tmp
RUN git clone https://github.com/atheme/atheme.git
WORKDIR /tmp/atheme
RUN git submodule update --init
RUN ./configure --prefix=/opt/atheme --enable-contrib --enable-large-net --with-pcre
RUN make
RUN make install

# Create directories and user first
RUN mkdir -p /var/run/tailscale /var/cache/tailscale /var/lib/tailscale
RUN mkdir -p /opt/atheme/var
RUN adduser -D -h /opt/atheme/var -u 1000 atheme
RUN chown -R atheme:atheme /opt/atheme/var

# Fix permissions for atheme installation  
RUN chmod 755 /opt/atheme/bin/*
RUN chown -R root:root /opt/atheme
RUN mkdir -p /opt/atheme/etc
RUN chown atheme:atheme /opt/atheme/etc

# Create and set permissions for volume mount directory
RUN mkdir -p /var/lib/atheme
RUN chown atheme:atheme /var/lib/atheme

# Copy configuration templates and startup script
COPY atheme/atheme.conf.template /opt/atheme/atheme.conf.template
COPY atheme/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# Container starts as root for Tailscale, drops to atheme user for services
WORKDIR /opt/atheme/var

# Atheme httpd serves XMLRPC for Convos authentication
EXPOSE 8080

CMD ["/app/entrypoint.sh"]
