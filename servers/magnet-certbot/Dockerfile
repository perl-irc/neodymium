# ABOUTME: Dockerfile for magnet-certbot SSL certificate management
# ABOUTME: Runs certbot standalone, pushes certs to magnet-irc via SSH

FROM alpine:latest

RUN apk add --no-cache certbot curl bash jq openssh-client

# Install flyctl for SSH and machine management
RUN curl -L https://fly.io/install.sh | sh
ENV PATH="/root/.fly/bin:$PATH"

COPY renew.sh /renew.sh
RUN chmod +x /renew.sh

CMD ["/renew.sh"]
