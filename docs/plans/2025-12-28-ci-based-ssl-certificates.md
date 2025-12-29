# CI-Based SSL Certificate Management

## Problem

The current Let's Encrypt setup runs certbot at container startup using HTTP-01 validation. This creates issues with multiple machines:

1. **ACME challenge routing**: HTTP-01 validation requires serving a challenge file from the domain's IP. With multiple machines behind anycast, requests may hit different machines than the one that created the challenge file.

2. **90-day renewal cycle**: Let's Encrypt certs expire every 90 days.

**Constraint**: Scaling to 1 machine is not acceptable.

## Proposed Solution: Dedicated Certbot Machine with fly-replay

Use a separate Fly app for certificate management that receives ACME challenges via `fly-replay` header routing.

### Architecture

```
                         Let's Encrypt
                              │
                              │ GET /.well-known/acme-challenge/{token}
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                magnet-irc (multiple machines)                │
│                                                              │
│  nginx receives request:                                     │
│  - Returns: fly-replay: app=magnet-certbot                  │
│                                                              │
└─────────────────────────────────────────────────────────────┘
                              │
                              │ Fly.io replays request
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                magnet-certbot (single machine)               │
│                                                              │
│  - Auto-starts when request arrives                         │
│  - Certbot serves challenge directly                        │
│  - Auto-stops when idle                                     │
│                                                              │
└─────────────────────────────────────────────────────────────┘
                              │
                              │ After validation, store cert
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                     Fly.io Secrets                           │
│                                                              │
│  SSL_CERT_PEM = "-----BEGIN CERTIFICATE-----..."            │
│  SSL_KEY_PEM  = "-----BEGIN PRIVATE KEY-----..."            │
│                                                              │
└─────────────────────────────────────────────────────────────┘
                              │
                              │ Redeploy to pick up new certs
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                magnet-irc (multiple machines)                │
│                                                              │
│  start.sh reads SSL_CERT_PEM and SSL_KEY_PEM from env       │
│  Writes to /opt/solanum/etc/ssl.pem and ssl.key             │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### How It Works

1. **Renewal triggered**: GitHub Actions (scheduled or manual) restarts magnet-certbot
2. **Certbot runs**: Creates challenge, starts HTTP server waiting for validation
3. **Let's Encrypt validates**: Sends request to `kowloon.social/.well-known/acme-challenge/{token}`
4. **Request hits magnet-irc**: nginx returns `fly-replay: app=magnet-certbot`
5. **Fly replays to certbot machine**: magnet-certbot serves challenge
6. **Cert issued**: Certbot receives certificate
7. **Store as secrets**: `flyctl secrets set` stores cert for new machine startups
8. **Push to running machines**: SSH to each machine, write cert files
9. **Rehash Solanum**: Send SIGHUP to reload certs (zero downtime)
10. **Certbot machine stops**: Auto-stops after idle timeout

### Benefits

- **Zero downtime**: Certs pushed via SSH, Solanum reloads on SIGHUP (no dropped connections)
- **No Tigris/S3 needed**: Challenge served directly by certbot machine
- **No scaling**: magnet-irc stays at full capacity throughout
- **Cost efficient**: Certbot machine only runs during renewal (~minutes per 60 days)

## Implementation Plan

### Phase 1: Create magnet-certbot Fly app

Create a minimal Fly app for certificate management.

**Files to create:**
- `servers/magnet-certbot/fly.toml`
- `servers/magnet-certbot/Dockerfile`
- `servers/magnet-certbot/renew.sh`

```toml
# servers/magnet-certbot/fly.toml
app = "magnet-certbot"
primary_region = "ord"

[build]
  dockerfile = "Dockerfile"

[http_service]
  internal_port = 80
  auto_stop_machines = "stop"      # Stop when idle
  auto_start_machines = true       # Start on request
  min_machines_running = 0         # Allow full stop

[env]
  SSL_DOMAINS = "kowloon.social,magnet-irc.fly.dev"
  ADMIN_EMAIL = "chris@prather.org"
```

```dockerfile
# servers/magnet-certbot/Dockerfile
FROM alpine:latest

RUN apk add --no-cache certbot curl bash jq

# Install flyctl for secrets and SSH
RUN curl -L https://fly.io/install.sh | sh
ENV PATH="/root/.fly/bin:$PATH"

COPY renew.sh /renew.sh
RUN chmod +x /renew.sh

CMD ["/renew.sh"]
```

```sh
#!/bin/sh
# servers/magnet-certbot/renew.sh

set -e

# Build domain arguments
DOMAIN_ARGS=""
for domain in $(echo "${SSL_DOMAINS}" | tr ',' ' '); do
    DOMAIN_ARGS="$DOMAIN_ARGS -d $domain"
done

# Run certbot in standalone mode (serves its own HTTP)
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

# Store certs as secrets on magnet-irc (for new machines on startup)
flyctl secrets set -a magnet-irc \
    SSL_CERT_PEM="$(cat /etc/letsencrypt/live/${PRIMARY_DOMAIN}/fullchain.pem)" \
    SSL_KEY_PEM="$(cat /etc/letsencrypt/live/${PRIMARY_DOMAIN}/privkey.pem)"

echo "Certificates stored as secrets on magnet-irc"

# Update running machines without restart (zero downtime)
echo "Updating certificates on running machines..."
CERT_FILE="/etc/letsencrypt/live/${PRIMARY_DOMAIN}/fullchain.pem"
KEY_FILE="/etc/letsencrypt/live/${PRIMARY_DOMAIN}/privkey.pem"

for machine in $(flyctl machines list -a magnet-irc --json | jq -r '.[].id'); do
    echo "Updating machine ${machine}..."

    # Write cert files directly
    cat "$CERT_FILE" | flyctl ssh console -a magnet-irc -s "${machine}" \
        -C "cat > /opt/solanum/etc/ssl.pem"
    cat "$KEY_FILE" | flyctl ssh console -a magnet-irc -s "${machine}" \
        -C "cat > /opt/solanum/etc/ssl.key"

    # Fix permissions
    flyctl ssh console -a magnet-irc -s "${machine}" \
        -C "chmod 600 /opt/solanum/etc/ssl.pem /opt/solanum/etc/ssl.key && chown ircd:ircd /opt/solanum/etc/ssl.pem /opt/solanum/etc/ssl.key"

    # Rehash Solanum to reload certs
    flyctl ssh console -a magnet-irc -s "${machine}" \
        -C "pkill -HUP solanum"

    echo "Machine ${machine} updated"
done

echo "Certificate renewal complete - zero downtime"
```

### Phase 2: Update magnet-irc nginx for fly-replay

Modify `solanum/nginx.conf` to route ACME challenges to magnet-certbot:

```nginx
# ACME challenges routed to certbot machine
location /.well-known/acme-challenge/ {
    add_header fly-replay "app=magnet-certbot" always;
    return 200;
}

# Everything else gets fly-replay header to route to Convos
location / {
    add_header fly-replay "app=magnet-convos" always;
    return 200;
}
```

**Files to modify:**
- `solanum/nginx.conf`

### Phase 3: Update magnet-irc start.sh for secrets-based certs

Modify `solanum/start.sh` to read certs from secrets:

```sh
# SSL certificate configuration
SSL_CERT="/opt/solanum/etc/ssl.pem"
SSL_KEY="/opt/solanum/etc/ssl.key"
SSL_DH="/opt/solanum/etc/dh.pem"

# Check if certs are provided via secrets (preferred)
if [ -n "${SSL_CERT_PEM}" ] && [ -n "${SSL_KEY_PEM}" ]; then
    echo "Using SSL certificates from Fly secrets..."
    echo "${SSL_CERT_PEM}" > "$SSL_CERT"
    echo "${SSL_KEY_PEM}" > "$SSL_KEY"
else
    echo "No SSL secrets found, falling back to self-signed certificate..."
    # Generate self-signed cert (existing logic)
    ...
fi
```

**Files to modify:**
- `solanum/start.sh` - Add secrets-based cert loading, remove certbot logic

### Phase 4: Create renewal workflow

GitHub Actions workflow to trigger renewal:

```yaml
# .github/workflows/cert-renewal.yml
name: SSL Certificate Renewal

on:
  schedule:
    - cron: '0 0 1 */2 *'  # 1st of every 2nd month
  workflow_dispatch:        # Manual trigger

env:
  FLY_API_TOKEN: ${{ secrets.FLY_API_TOKEN }}

jobs:
  renew:
    name: Renew SSL Certificates
    runs-on: ubuntu-latest
    steps:
      - uses: superfly/flyctl-actions/setup-flyctl@master

      - name: Trigger cert renewal
        run: flyctl apps restart magnet-certbot

      - name: Wait for renewal to complete
        run: sleep 120

      - name: Verify secrets updated
        run: flyctl secrets list -a magnet-irc | grep SSL_CERT_PEM
```

No checkout or deploy needed - just restart the existing machine. The renewal logic is baked into the container.

**Files to create:**
- `.github/workflows/cert-renewal.yml`

### Phase 5: Initial setup and first cert

One-time manual steps:

```sh
# 1. Create the certbot app
flyctl apps create magnet-certbot

# 2. Set FLY_API_TOKEN secret on certbot app (for flyctl secrets set)
flyctl secrets set -a magnet-certbot FLY_API_TOKEN="..."

# 3. Deploy certbot (first run)
flyctl deploy --config servers/magnet-certbot/fly.toml -a magnet-certbot

# 4. Verify magnet-irc has the secrets
flyctl secrets list -a magnet-irc

# 5. Redeploy magnet-irc to use new certs
flyctl deploy --config servers/magnet-irc/fly.toml -a magnet-irc
```

## Rollback Plan

1. **Certbot fails**: Check logs with `flyctl logs -a magnet-certbot`
2. **Secrets not set**: Manually run certbot and set secrets
3. **Complete failure**: magnet-irc falls back to self-signed certs

## Costs

- **magnet-certbot**: Only runs during renewal (~2 min every 60 days)
- **Shared CPU, 256MB**: ~$0.00 when stopped
- **Effectively free**

## Future: DNS-01 Validation

When a permanent domain with DNS API access is available:

1. Switch certbot to DNS-01 validation
2. No fly-replay routing needed
3. Even simpler architecture
